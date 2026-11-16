// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

enum JitActivationState: Equatable {
    case idle
    case requestingExtension
    case blessed(poolMiB: Int, ledgerExempt: Bool)
    case fallbackUntethered(reason: String)
}

enum GpuDisplayBackend: String, CaseIterable, Identifiable {
    case gop2D = "2D UEFI GOP (Metal)"
    case virgl3D = "3D VirtIO-GPU VirGL (ANGLE Metal)"

    var id: String { rawValue }
}

private struct PoolAcquireProbeResult: Sendable {
    let acquired: Bool
    let poolMiB: Int
    let ledgerExempt: Bool
    let status: String
}

private struct ExtensionInvocationResult: @unchecked Sendable {
    let response: [String: Any]?
    let errorMessage: String?
}

/// Manages in-app TXM JIT activation (`brk #0xf00d` + `0x69` page blessing),
/// App Group pairing record synchronization (`group.io.hengelinux.shared`),
/// and `HengeLinuxJITExtension` XPC handshake.
@MainActor
final class SelfDebugJITClient: ObservableObject {
    @Published private(set) var state: JitActivationState = .idle
    @Published var gpuBackend: GpuDisplayBackend = .gop2D
    @Published private(set) var extensionDiagnostic: String?

    static let defaultJitPoolMiB: Int = 384
    static let defaultAppGroupIdentifier: String = "group.io.hengelinux.shared"
    static let defaultExtensionIdentifier: String = "io.hengelinux.app.jit-extension"

    /// Resolves the embedded `.appex` bundle identifier dynamically so SideStore / AltStore
    /// free-account bundle ID rewrites (e.g. `io.hengelinux.app.<TEAMID>.jit-extension`) work.
    static var resolvedExtensionIdentifier: String {
        if let plugInsURL = Bundle.main.builtInPlugInsURL {
            let appexURL = plugInsURL.appendingPathComponent("HengeLinuxJITExtension.appex")
            if let appexID = Bundle(url: appexURL)?.bundleIdentifier, !appexID.isEmpty {
                return appexID
            }
        }
        if let hostID = Bundle.main.bundleIdentifier, !hostID.isEmpty {
            return "\(hostID).jit-extension"
        }
        return defaultExtensionIdentifier
    }

    static var resolvedAppGroupIdentifier: String {
        let fm = FileManager.default
        if fm.containerURL(forSecurityApplicationGroupIdentifier: defaultAppGroupIdentifier) != nil {
            return defaultAppGroupIdentifier
        }
        if let hostID = Bundle.main.bundleIdentifier, !hostID.isEmpty {
            let rewrittenGroup = "group.\(hostID)"
            if fm.containerURL(forSecurityApplicationGroupIdentifier: rewrittenGroup) != nil {
                return rewrittenGroup
            }
        }
        return defaultAppGroupIdentifier
    }

    init() {
        henge_jit_install_trap_guard()
        syncPairingRecordToAppGroup()
    }

    var pairingFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("pairing.plist")
    }

    var appGroupPairingFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.resolvedAppGroupIdentifier)?
            .appendingPathComponent("pairing.plist")
    }

    var hasPairingFile: Bool {
        if FileManager.default.fileExists(atPath: pairingFileURL.path) {
            return true
        }
        if let sharedURL = appGroupPairingFileURL {
            return FileManager.default.fileExists(atPath: sharedURL.path)
        }
        return false
    }

    /// Mirrors `Documents/pairing.plist` into the App Group container so
    /// `HengeLinuxJITExtension` can read it directly without large XPC payloads.
    @discardableResult
    func syncPairingRecordToAppGroup() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pairingFileURL.path),
              let sharedURL = appGroupPairingFileURL else {
            return false
        }
        do {
            let srcData = try Data(contentsOf: pairingFileURL)
            if let existing = try? Data(contentsOf: sharedURL), existing == srcData {
                return true
            }
            try srcData.write(to: sharedURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func prepareSession() async {
        if case .blessed = state {
            return
        }

        state = .requestingExtension
        extensionDiagnostic = nil
        let syncedToGroup = syncPairingRecordToAppGroup()

        let poolBytes = Int(Self.defaultJitPoolMiB) * 1024 * 1024

        // Fast path: if an external debugger (LLDB or StikDebug) is already attached,
        // acquire and bless the 384 MiB RX/RW pool immediately without spawning the extension.
        let fastProbe = await Self.probeAcquirePool(poolBytes: poolBytes, maxAttempts: 1, intervalNs: 0)
        if fastProbe.acquired {
            state = .blessed(poolMiB: fastProbe.poolMiB, ledgerExempt: fastProbe.ledgerExempt)
            return
        }

        // In-app XPC path: invoke HengeLinuxJITExtension (com.apple.ar.viewer) concurrently
        // with a background pool-acquisition polling loop so debugserver attaches to our PID
        // and services brk #0x69 / brk #0xf00d traps on a worker thread.
        if hasPairingFile && HengeJITExtensionBridge.isExtensionRuntimeAvailable() {
            let activeAppGroupID = Self.resolvedAppGroupIdentifier
            var requestPayload: [String: Any] = [
                "targetPID": NSNumber(value: getpid()),
                "poolBytes": NSNumber(value: UInt64(poolBytes)),
                "vpnLoopback": "10.7.0.1",
                "appGroupID": activeAppGroupID
            ]
            // Fallback when free Apple ID sideloading strips App Group containers.
            if !syncedToGroup, let fallbackData = try? Data(contentsOf: pairingFileURL) {
                requestPayload["pairingData"] = fallbackData
            }

            async let xpcOutcome = Self.invokeJitExtension(userInfo: requestPayload, timeoutSeconds: 15.0)
            async let workerAcquire = Self.probeAcquirePool(
                poolBytes: poolBytes,
                maxAttempts: 110,
                intervalNs: 150_000_000
            )

            let (acquireResult, extResult) = await (workerAcquire, xpcOutcome)
            if acquireResult.acquired {
                extensionDiagnostic = extResult.response?["message"] as? String
                state = .blessed(
                    poolMiB: acquireResult.poolMiB,
                    ledgerExempt: acquireResult.ledgerExempt
                )
                return
            }

            let extMessage = (extResult.response?["message"] as? String)
                ?? extResult.errorMessage
                ?? (extResult.response?["status"] as? String)
            extensionDiagnostic = extMessage
            let detail = extMessage ?? acquireResult.status
            state = .fallbackUntethered(
                reason: "\(detail) · Or attach StikDebug (henge-jit.js) / LLDB for 384 MiB TXM JIT."
            )
            return
        }

        let status = fastProbe.status
        state = .fallbackUntethered(
            reason: "\(status) · Place pairing.plist in Documents/ for in-app XPC or attach StikDebug (henge-jit.js) / LLDB."
        )
    }

    private static func probeAcquirePool(
        poolBytes: Int,
        maxAttempts: Int,
        intervalNs: UInt64
    ) async -> PoolAcquireProbeResult {
        await Task.detached(priority: .userInitiated) {
            var pool = HengeJitPool()
            let attempts = max(1, maxAttempts)
            for idx in 0..<attempts {
                if henge_jit_acquire_pool(poolBytes, true, &pool) {
                    return PoolAcquireProbeResult(
                        acquired: true,
                        poolMiB: Int(pool.size / (1024 * 1024)),
                        ledgerExempt: henge_txm_is_cs_debugged(),
                        status: "Blessed"
                    )
                }
                if idx + 1 < attempts && intervalNs > 0 {
                    try? await Task.sleep(nanoseconds: intervalNs)
                }
            }
            return PoolAcquireProbeResult(
                acquired: false,
                poolMiB: 0,
                ledgerExempt: henge_txm_is_cs_debugged(),
                status: copyCurrentJitStatus()
            )
        }.value
    }

    private nonisolated static func copyCurrentJitStatus() -> String {
        var statusBuf = [CChar](repeating: 0, count: 256)
        henge_jit_copy_status(&statusBuf, statusBuf.count)
        let utf8Bytes = statusBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: utf8Bytes, as: UTF8.self)
    }

    private static func invokeJitExtension(
        userInfo: [String: Any],
        timeoutSeconds: TimeInterval
    ) async -> ExtensionInvocationResult {
        await withCheckedContinuation { continuation in
            HengeJITExtensionBridge.invokeExtension(
                withIdentifier: Self.resolvedExtensionIdentifier,
                userInfo: userInfo,
                timeoutSeconds: timeoutSeconds
            ) { responseInfo, error in
                continuation.resume(
                    returning: ExtensionInvocationResult(
                        response: responseInfo,
                        errorMessage: error?.localizedDescription
                    )
                )
            }
        }
    }

    /// Flush translated block cache on VM stop without releasing the process-lifetime
    /// TXM dual-mapped RX/RW pool so subsequent guest reboots require zero debugger attach.
    func prepareForReboot() {
        if case .blessed = state {
            return
        }
        state = .idle
    }

    func reset() {
        extensionDiagnostic = nil
        state = .idle
    }
}
