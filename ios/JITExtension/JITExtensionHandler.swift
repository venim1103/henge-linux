// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

#if canImport(StikJIT)
import StikJIT
#endif

#if canImport(Idevice)
import Idevice
#endif

private struct PairingRecordSummary {
    let udid: String
    let systemBUID: String
    let hasCertificates: Bool
    let rawData: Data
}

private enum BlessingOutcome {
    case blessed(rxBase: UInt64, pagesBlessed: Int, transport: String)
    case awaitingStikJitFramework(udid: String, reason: String)
    case failed(reason: String)
}

/// Helper NSExtension (`com.apple.ar.viewer` extension point) modeled after
/// PlayportJIT.appex. Loads the device pairing record from the shared App Group
/// container (`group.io.hengelinux.shared/pairing.plist`) or fallback XPC payload
/// and drives `brk #0xf00d` + byte-0 `0x69` page blessing over `10.7.0.1`
/// (`LocalDevVPN`) within the extension memory ceiling.
final class JITExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let defaultAppGroupID = "group.io.hengelinux.shared"
    private static let hostPageSize: UInt64 = 16 * 1024
    private static let txmMinVA: UInt64 = 0x01_0000_0000
    private static let txmMaxVA: UInt64 = 0x10_0000_0000
    private static let txmHardCeiling: UInt64 = 0x70_0000_0000

    func beginRequest(with context: NSExtensionContext) {
        DispatchQueue.global(qos: .userInitiated).async {
            let responseInfo = self.processRequest(context: context)
            let outputItem = NSExtensionItem()
            outputItem.userInfo = responseInfo
            context.completeRequest(returningItems: [outputItem], completionHandler: nil)
        }
    }

    private func processRequest(context: NSExtensionContext) -> [String: Any] {
        var responseInfo: [String: Any] = [
            "status": "ready",
            "protocol": "brk-0xf00d-0x69",
            "vpnLoopback": "10.7.0.1",
            "appGroup": Self.defaultAppGroupID
        ]

        guard let inputItem = context.inputItems.first as? NSExtensionItem,
              let userInfo = inputItem.userInfo else {
            responseInfo["status"] = "invalid_request"
            responseInfo["message"] = "Missing NSExtensionItem userInfo payload."
            return responseInfo
        }

        let targetPID = (userInfo["targetPID"] as? NSNumber)?.int32Value ?? 0
        let poolBytes = (userInfo["poolBytes"] as? NSNumber)?.uint64Value ?? (384 * 1024 * 1024)
        let vpnLoopback = (userInfo["vpnLoopback"] as? String) ?? "10.7.0.1"
        let debugserverPort = (userInfo["debugserverPort"] as? NSNumber)?.uint16Value ?? 0
        let appGroupID = (userInfo["appGroupID"] as? String) ?? Self.defaultAppGroupID

        responseInfo["targetPID"] = targetPID
        responseInfo["poolBytes"] = poolBytes
        responseInfo["vpnLoopback"] = vpnLoopback

        guard targetPID > 0 else {
            responseInfo["status"] = "invalid_pid"
            responseInfo["message"] = "Invalid host targetPID (\(targetPID))."
            return responseInfo
        }

        guard poolBytes >= (16 * 1024 * 1024),
              poolBytes <= (1024 * 1024 * 1024),
              (poolBytes % Self.hostPageSize) == 0 else {
            responseInfo["status"] = "invalid_pool_size"
            responseInfo["message"] = "Requested JIT pool (\(poolBytes) B) must be 16 KiB-aligned within [16 MiB, 1 GiB]."
            return responseInfo
        }

        guard let pairingData = loadPairingData(appGroupID: appGroupID, fallbackUserInfo: userInfo),
              !pairingData.isEmpty else {
            responseInfo["pairingPresent"] = false
            responseInfo["status"] = "awaiting_pairing"
            responseInfo["message"] = "Place pairing.plist in Files -> HengeLinux -> Documents/pairing.plist."
            return responseInfo
        }

        responseInfo["pairingPresent"] = true

        guard let pairing = parsePairingRecord(pairingData) else {
            responseInfo["pairingValid"] = false
            responseInfo["status"] = "invalid_pairing"
            responseInfo["message"] = "pairing.plist is not a valid lockdown property list."
            return responseInfo
        }

        responseInfo["pairingValid"] = true
        responseInfo["udid"] = pairing.udid
        responseInfo["hasCertificates"] = pairing.hasCertificates

        guard pairing.hasCertificates else {
            responseInfo["status"] = "incomplete_pairing"
            responseInfo["message"] = "pairing.plist is missing DeviceCertificate / HostPrivateKey / RootCertificate."
            return responseInfo
        }

        let outcome = executeBlessingSession(
            targetPID: targetPID,
            poolBytes: poolBytes,
            vpnLoopback: vpnLoopback,
            debugserverPort: debugserverPort,
            pairing: pairing
        )

        switch outcome {
        case .blessed(let rxBase, let pagesBlessed, let transport):
            responseInfo["status"] = "blessed"
            responseInfo["rxBaseHex"] = String(format: "0x%llx", rxBase)
            responseInfo["pagesBlessed"] = pagesBlessed
            responseInfo["transport"] = transport
            responseInfo["message"] = "Blessed \(pagesBlessed) x 16 KiB pages via \(transport)."
        case .awaitingStikJitFramework(let udid, let reason):
            responseInfo["status"] = "pairing_verified_awaiting_stikjit_sdk"
            responseInfo["udid"] = udid
            responseInfo["message"] = reason
        case .failed(let reason):
            responseInfo["status"] = "blessing_failed"
            responseInfo["message"] = reason
        }

        return responseInfo
    }

    private func loadPairingData(appGroupID: String, fallbackUserInfo: [AnyHashable: Any]) -> Data? {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let sharedPairing = containerURL.appendingPathComponent("pairing.plist")
            if let data = try? Data(contentsOf: sharedPairing), !data.isEmpty {
                return data
            }
        }
        if let inlineData = fallbackUserInfo["pairingData"] as? Data, !inlineData.isEmpty {
            return inlineData
        }
        return nil
    }

    private func parsePairingRecord(_ data: Data) -> PairingRecordSummary? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return nil
        }

        let udid = (dict["UDID"] as? String)
            ?? (dict["UniqueDeviceID"] as? String)
            ?? "unknown-udid"
        let buid = (dict["SystemBUID"] as? String) ?? ""
        let hasDeviceCert = (dict["DeviceCertificate"] as? Data)?.isEmpty == false
        let hasHostCert = (dict["HostCertificate"] as? Data)?.isEmpty == false
        let hasHostKey = (dict["HostPrivateKey"] as? Data)?.isEmpty == false
        let hasRootCert = (dict["RootCertificate"] as? Data)?.isEmpty == false

        return PairingRecordSummary(
            udid: udid,
            systemBUID: buid,
            hasCertificates: hasDeviceCert && hasHostCert && hasHostKey && hasRootCert,
            rawData: data
        )
    }

    private func executeBlessingSession(
        targetPID: Int32,
        poolBytes: UInt64,
        vpnLoopback: String,
        debugserverPort: UInt16,
        pairing: PairingRecordSummary
    ) -> BlessingOutcome {
        #if canImport(StikJIT) && canImport(Idevice)
        _ = (targetPID, poolBytes, vpnLoopback, debugserverPort, pairing)
        return .failed(reason: "StikJIT/Idevice module linked; configure RSD debugproxy session entrypoint.")
        #else
        if debugserverPort > 0 {
            let blesser = GdbRspTxmBlesser(
                host: vpnLoopback,
                port: debugserverPort,
                targetPID: targetPID,
                poolBytes: poolBytes
            )
            return blesser.run()
        }
        return .awaitingStikJitFramework(
            udid: pairing.udid,
            reason: "pairing.plist validated (\(pairing.udid)); link StikJIT.xcframework + idevice (or expose debugserverPort on \(vpnLoopback)) to stream RSD debugserver blessing."
        )
        #endif
    }
}

/// Minimal GDB Remote Serial Protocol (RSP) client over TCP (`10.7.0.1:<port>`)
/// implementing the `brk #0x69` probe and `brk #0xf00d` (`x16=1` `_M...,rx` +
/// byte-0 `0x69` 16 KiB page blessing + `x16=0` `D` detach) handshake.
private final class GdbRspTxmBlesser {
    private let host: String
    private let port: UInt16
    private let targetPID: Int32
    private let poolBytes: UInt64
    private var fd: Int32 = -1
    private var noAckMode: Bool = false
    private var recvBuf = [UInt8]()

    init(host: String, port: UInt16, targetPID: Int32, poolBytes: UInt64) {
        self.host = host
        self.port = port
        self.targetPID = targetPID
        self.poolBytes = poolBytes
    }

    deinit {
        closeSocket()
    }

    func run() -> BlessingOutcome {
        guard connectTCP() else {
            return .failed(reason: "Unable to connect to debugserver at \(host):\(port).")
        }
        defer {
            _ = sendPacket("D")
            closeSocket()
        }

        if sendPacket("QStartNoAckMode") == "OK" {
            noAckMode = true
        }

        let pidHex = String(UInt32(bitPattern: targetPID), radix: 16)
        guard let attachReply = sendPacket("vAttach;\(pidHex)"),
              !attachReply.isEmpty,
              !attachReply.hasPrefix("E") else {
            return .failed(reason: "debugserver vAttach;\(pidHex) failed.")
        }

        var blessedRxBase: UInt64 = 0
        var pagesBlessed = 0
        var trapIterations = 0
        var nextResumePacket = "c"

        for _ in 0..<256 {
            let resumePacket = nextResumePacket
            nextResumePacket = "c"
            guard let stopReply = sendPacket(resumePacket),
                  !stopReply.isEmpty,
                  !stopReply.hasPrefix("E"),
                  !stopReply.hasPrefix("W"),
                  !stopReply.hasPrefix("X") else {
                return .failed(reason: "Target stopped unexpectedly during JIT handshake.")
            }

            if stopReply.hasPrefix("T"), stopReply.count >= 3 {
                let sigHex = String(stopReply.dropFirst().prefix(2))
                if let sig = UInt8(sigHex, radix: 16), sig != 0x05 && sig != 0x00 {
                    if sig == 0x04 || sig == 0x06 || sig == 0x0A || sig == 0x0B {
                        return .failed(reason: "Target stopped with fatal signal 0x\(sigHex) during JIT handshake.")
                    }
                    nextResumePacket = "C\(sigHex)"
                    continue
                }
            }

            trapIterations += 1
            if trapIterations > 32 {
                return .failed(reason: "Exceeded maximum debugserver breakpoint iterations.")
            }

            guard let tid = extractHexField(in: stopReply, prefix: "thread:") else {
                return .failed(reason: "Missing thread id in debugserver stop reply.")
            }

            guard let pcHex = readRegister(stopReply: stopReply, regHex: "20", tid: tid),
                  let x16Hex = readRegister(stopReply: stopReply, regHex: "10", tid: tid),
                  let pc = parseLittleEndianU64(pcHex),
                  let x16 = parseLittleEndianU64(x16Hex) else {
                return .failed(reason: "Failed to read pc/x16 registers from debugserver.")
            }

            let pcAddrHex = String(pc, radix: 16)
            guard let insnHex = sendPacket("m\(pcAddrHex),4"),
                  insnHex.count >= 8,
                  let insn = parseLittleEndianU32(insnHex) else {
                return .failed(reason: "Failed to read ARM64 instruction at 0x\(pcAddrHex).")
            }

            // Verify ARM64 BRK #imm16 encoding: 0xD4200000 | (imm16 << 5)
            guard (insn & 0xFFE0_001F) == 0xD420_0000 else {
                continue
            }

            let imm16 = (insn >> 5) & 0xFFFF
            let nextPC = encodeLittleEndianU64(pc &+ 4)
            _ = sendPacket("P20=\(nextPC);thread:\(tid);")

            if imm16 == 0x0069 {
                _ = sendPacket("P0=690000e000000000;thread:\(tid);")
                continue
            }

            if imm16 == 0xF00D {
                if x16 == 1 {
                    let sizeHex = String(poolBytes, radix: 16)
                    guard let allocReply = sendPacket("_M\(sizeHex),rx"),
                          !allocReply.hasPrefix("E"),
                          let rxBase = UInt64(allocReply, radix: 16) else {
                        _ = sendPacket("P0=0000000000000000;thread:\(tid);")
                        return .failed(reason: "debugserver _M\(sizeHex),rx failed.")
                    }

                    let rxEnd = rxBase &+ poolBytes
                    guard rxBase >= 0x01_0000_0000,
                          rxEnd > rxBase,
                          rxEnd <= 0x10_0000_0000,
                          rxEnd < 0x70_0000_0000 else {
                        _ = sendPacket("P0=0000000000000000;thread:\(tid);")
                        return .failed(reason: "Allocated RX region 0x\(String(rxBase, radix: 16)) outside TXM [4 GiB, 64 GiB) bounds.")
                    }

                    let pageSize: UInt64 = 16 * 1024
                    let pageCount = Int(poolBytes / pageSize)
                    if let blessError = blessPages(rxBase: rxBase, pageCount: pageCount, pageSize: pageSize) {
                        _ = sendPacket("P0=0000000000000000;thread:\(tid);")
                        return .failed(reason: blessError)
                    }

                    blessedRxBase = rxBase
                    pagesBlessed = pageCount
                    let rxLE = encodeLittleEndianU64(rxBase)
                    _ = sendPacket("P0=\(rxLE);thread:\(tid);")
                } else if x16 == 0 {
                    if blessedRxBase != 0 && pagesBlessed > 0 {
                        return .blessed(
                            rxBase: blessedRxBase,
                            pagesBlessed: pagesBlessed,
                            transport: "gdb-rsp://\(host):\(port)"
                        )
                    }
                    return .failed(reason: "Received detach trap before RX JIT pool was blessed.")
                }
            }
        }

        return .failed(reason: "Exceeded maximum debugserver breakpoint iterations.")
    }

    private func blessPages(rxBase: UInt64, pageCount: Int, pageSize: UInt64) -> String? {
        if !noAckMode {
            for idx in 0..<pageCount {
                let pageAddr = rxBase &+ (UInt64(idx) * pageSize)
                let addrHex = String(pageAddr, radix: 16)
                guard sendPacket("M\(addrHex),1:69") == "OK" else {
                    return "Failed writing 0x69 blessing byte at 0x\(addrHex)."
                }
            }
            return nil
        }

        // Batch-pipeline M<addr>,1:69 writes in NoAckMode so 24,576 x 16 KiB pages
        // complete in < 1 s over 10.7.0.1 instead of 24,576 sequential RTTs.
        let batchSize = 128
        var idx = 0
        while idx < pageCount {
            let end = min(idx + batchSize, pageCount)
            var outBytes = [UInt8]()
            outBytes.reserveCapacity((end - idx) * 24)
            for pageIdx in idx..<end {
                let pageAddr = rxBase &+ (UInt64(pageIdx) * pageSize)
                let payload = "M\(String(pageAddr, radix: 16)),1:69"
                outBytes.append(contentsOf: framePacket(payload))
            }
            guard sendAll(outBytes) else {
                let addrHex = String(rxBase &+ (UInt64(idx) * pageSize), radix: 16)
                return "Failed sending pipelined 0x69 blessing batch at 0x\(addrHex)."
            }
            for pageIdx in idx..<end {
                guard let reply = receiveNextPacket(), reply == "OK" else {
                    let addrHex = String(rxBase &+ (UInt64(pageIdx) * pageSize), radix: 16)
                    return "Failed writing 0x69 blessing byte at 0x\(addrHex)."
                }
            }
            idx = end
        }
        return nil
    }

    private func connectTCP() -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }

        var noDelay: Int32 = 1
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            Darwin.close(sock)
            return false
        }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(sock)
            return false
        }
        recvBuf.removeAll(keepingCapacity: true)
        fd = sock
        return true
    }

    private func closeSocket() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        recvBuf.removeAll(keepingCapacity: false)
    }

    private func framePacket(_ payload: String) -> [UInt8] {
        let payloadBytes = Array(payload.utf8)
        let checksum = payloadBytes.reduce(UInt8(0)) { $0 &+ $1 }
        return Array(String(format: "$%@#%02x", payload, checksum).utf8)
    }

    private func sendAll(_ outBytes: [UInt8]) -> Bool {
        guard fd >= 0 else { return false }
        var sent = 0
        while sent < outBytes.count {
            let n = outBytes.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress!.advanced(by: sent), outBytes.count - sent, 0)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func receiveNextPacket() -> String? {
        guard fd >= 0 else { return nil }
        var scratch = [UInt8](repeating: 0, count: 4096)
        while recvBuf.count < 65536 {
            if let dollarIdx = recvBuf.firstIndex(of: UInt8(ascii: "$")),
               let hashIdx = recvBuf[dollarIdx...].firstIndex(of: UInt8(ascii: "#")),
               recvBuf.distance(from: hashIdx, to: recvBuf.endIndex) >= 3 {
                if !noAckMode {
                    var ack: UInt8 = UInt8(ascii: "+")
                    _ = Darwin.send(fd, &ack, 1, 0)
                }
                let bodyStart = recvBuf.index(after: dollarIdx)
                let body = String(decoding: recvBuf[bodyStart..<hashIdx], as: UTF8.self)
                let packetEnd = recvBuf.index(hashIdx, offsetBy: 3)
                recvBuf.removeSubrange(recvBuf.startIndex..<packetEnd)
                return body
            }

            let n = Darwin.recv(fd, &scratch, scratch.count, 0)
            if n <= 0 { return nil }
            recvBuf.append(contentsOf: scratch[0..<n])
        }
        return nil
    }

    private func sendPacket(_ payload: String) -> String? {
        guard sendAll(framePacket(payload)) else { return nil }
        return receiveNextPacket()
    }

    private func extractHexField(in packet: String, prefix: String) -> String? {
        guard let range = packet.range(of: prefix) else { return nil }
        let tail = packet[range.upperBound...]
        let hex = tail.prefix { $0.isHexDigit }
        return hex.isEmpty ? nil : String(hex)
    }

    private func readRegister(stopReply: String, regHex: String, tid: String) -> String? {
        for sep in [";", ":"] {
            let token = "\(sep)\(regHex):"
            if let range = stopReply.range(of: token) {
                let candidate = stopReply[range.upperBound...].prefix(16)
                if candidate.count == 16 && candidate.allSatisfy(\.isHexDigit) {
                    return String(candidate)
                }
            }
        }
        guard let reply = sendPacket("p\(regHex);thread:\(tid);"),
              reply.count == 16,
              reply.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return reply
    }

    private func parseLittleEndianU64(_ hex: String) -> UInt64? {
        guard hex.count == 16 else { return nil }
        var value: UInt64 = 0
        var idx = hex.startIndex
        for byteIndex in 0..<8 {
            let nextIdx = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<nextIdx], radix: 16) else { return nil }
            value |= UInt64(byte) << (UInt64(byteIndex) * 8)
            idx = nextIdx
        }
        return value
    }

    private func parseLittleEndianU32(_ hex: String) -> UInt32? {
        guard hex.count >= 8 else { return nil }
        var value: UInt32 = 0
        var idx = hex.startIndex
        for byteIndex in 0..<4 {
            let nextIdx = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<nextIdx], radix: 16) else { return nil }
            value |= UInt32(byte) << (UInt32(byteIndex) * 8)
            idx = nextIdx
        }
        return value
    }

    private func encodeLittleEndianU64(_ value: UInt64) -> String {
        var out = ""
        out.reserveCapacity(16)
        for byteIndex in 0..<8 {
            let byte = UInt8((value >> (UInt64(byteIndex) * 8)) & 0xFF)
            out += String(format: "%02x", byte)
        }
        return out
    }
}
