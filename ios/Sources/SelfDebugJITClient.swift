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

struct ContainerFileEntry: Identifiable, Hashable, Sendable {
    let id: String
    let relativePath: String
    let fileName: String
    let sizeText: String
    let isDeletable: Bool
}

/// Manages in-app TXM JIT activation (`brk #0xf00d` + `0x69` page blessing),
/// App Group pairing record synchronization (`group.io.hengelinux.shared`),
/// and `HengeLinuxJITExtension` XPC handshake.
@MainActor
final class SelfDebugJITClient: ObservableObject {
    @Published private(set) var state: JitActivationState = .idle
    @Published var gpuBackend: GpuDisplayBackend = .gop2D
    @Published private(set) var extensionDiagnostic: String?
    @Published private(set) var hasPairingFile: Bool = false
    @Published private(set) var pairingStatusText: String = "Missing (Optional)"
    @Published private(set) var diskStatusText: String = "Missing (Import archlinux.hvsparse)"
    @Published private(set) var uefiStatusText: String = "Missing (Import code.fd & vars.fd)"
    @Published private(set) var containerFiles: [ContainerFileEntry] = []

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
        bootstrapSandboxFolders()
        syncPairingRecordToAppGroup()
        refreshFileStatus()
    }

    var documentsDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    var machineDirectoryURL: URL {
        documentsDirectoryURL
            .appendingPathComponent("Machines", isDirectory: true)
            .appendingPathComponent("ArchLinux", isDirectory: true)
    }

    var sharedDirectoryURL: URL {
        documentsDirectoryURL.appendingPathComponent("Shared", isDirectory: true)
    }

    var pairingFileURL: URL {
        documentsDirectoryURL.appendingPathComponent("pairing.plist")
    }

    var appGroupPairingFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.resolvedAppGroupIdentifier)?
            .appendingPathComponent("pairing.plist")
    }

    /// Creates `Documents/Machines/ArchLinux/` and `Documents/Shared/` and seeds a non-hidden
    /// guide file in `Documents/` on first launch so iOS `Files.app` immediately displays the
    /// `On My iPhone -> HengeLinux` folder before any manual import.
    func bootstrapSandboxFolders() {
        let fm = FileManager.default
        let docs = documentsDirectoryURL
        let machineDir = machineDirectoryURL
        let sharedDir = sharedDirectoryURL

        try? fm.createDirectory(at: machineDir, withIntermediateDirectories: true, attributes: nil)
        try? fm.createDirectory(at: sharedDir, withIntermediateDirectories: true, attributes: nil)

        let rootReadme = docs.appendingPathComponent("README-HengeLinux.txt")
        if !fm.fileExists(atPath: rootReadme.path) {
            let text = """
            henge-linux iOS Sandbox Container
            =================================

            1. Optional TXM Self-Debug Pairing File:
               Place `pairing.plist` (or `.mobiledevicepairing`) here in `Documents/pairing.plist`
               or import it directly from the in-app "Import pairing.plist..." button.

            2. Arch Linux Guest Files (`Machines/ArchLinux/`):
               - `archlinux.hvsparse` (or `archlinux.img`)
               - `code.fd` (64 MiB EDK2 AArch64 UEFI code firmware)
               - `vars.fd` (64 MiB EDK2 AArch64 UEFI variable store)

            3. Host <-> Guest WebDAV Shared Folder (`Shared/`):
               Mounted inside Arch Linux via `http://10.0.2.4/`.
            """
            try? text.write(to: rootReadme, atomically: true, encoding: .utf8)
        }

        let machineReadme = machineDir.appendingPathComponent("README-ArchLinux.txt")
        if !fm.fileExists(atPath: machineReadme.path) {
            let text = """
            Place your Arch Linux AArch64 VM files in this directory:
            - archlinux.hvsparse (packed sparse NVMe image)
            - code.fd (EDK2 UEFI firmware code)
            - vars.fd (EDK2 UEFI NVRAM variables)
            """
            try? text.write(to: machineReadme, atomically: true, encoding: .utf8)
        }
    }

    /// Refreshes reactive `@Published` file status properties for the SwiftUI launcher.
    func refreshFileStatus() {
        let fm = FileManager.default
        let localExists = fm.fileExists(atPath: pairingFileURL.path)
        let groupExists = appGroupPairingFileURL.map { fm.fileExists(atPath: $0.path) } ?? false
        hasPairingFile = localExists || groupExists

        if hasPairingFile {
            let activeURL = localExists ? pairingFileURL : (appGroupPairingFileURL ?? pairingFileURL)
            if Self.isValidPropertyListDictionary(at: activeURL) {
                pairingStatusText = groupExists
                    ? "pairing.plist (Valid · App Group Synced)"
                    : "pairing.plist (Valid · Local Container)"
            } else {
                pairingStatusText = "pairing.plist (Present)"
            }
        } else {
            pairingStatusText = "Missing (Optional · Tap Import)"
        }

        let sparseURL = machineDirectoryURL.appendingPathComponent("archlinux.hvsparse")
        let rawURL = machineDirectoryURL.appendingPathComponent("archlinux.img")
        if fm.fileExists(atPath: sparseURL.path) {
            let sizeStr = Self.formattedFileSize(at: sparseURL)
            diskStatusText = "archlinux.hvsparse (Ready\(sizeStr))"
        } else if fm.fileExists(atPath: rawURL.path) {
            let sizeStr = Self.formattedFileSize(at: rawURL)
            diskStatusText = "archlinux.img (Ready\(sizeStr))"
        } else {
            diskStatusText = "Missing (Import archlinux.hvsparse)"
        }

        let codeExists = fm.fileExists(atPath: machineDirectoryURL.appendingPathComponent("code.fd").path)
        let varsExists = fm.fileExists(atPath: machineDirectoryURL.appendingPathComponent("vars.fd").path)
        switch (codeExists, varsExists) {
        case (true, true):
            uefiStatusText = "code.fd + vars.fd (Ready)"
        case (true, false):
            uefiStatusText = "code.fd present (Need vars.fd)"
        case (false, true):
            uefiStatusText = "vars.fd present (Need code.fd)"
        case (false, false):
            uefiStatusText = "Missing (Import code.fd & vars.fd)"
        }

        containerFiles = Self.scanContainerFiles(docsURL: documentsDirectoryURL)
    }

    func deleteContainerFile(_ entry: ContainerFileEntry) throws {
        guard entry.isDeletable, !entry.relativePath.isEmpty, !entry.relativePath.contains("..") else {
            return
        }
        let fm = FileManager.default
        let targetURL = documentsDirectoryURL.appendingPathComponent(entry.relativePath)
        if fm.fileExists(atPath: targetURL.path) {
            try fm.removeItem(at: targetURL)
        }
        if entry.relativePath == "pairing.plist",
           let sharedURL = appGroupPairingFileURL,
           fm.fileExists(atPath: sharedURL.path) {
            try? fm.removeItem(at: sharedURL)
        }
        refreshFileStatus()
    }

    private static func scanContainerFiles(docsURL: URL) -> [ContainerFileEntry] {
        let fm = FileManager.default
        let seededNames: Set<String> = ["README-HengeLinux.txt", "README-ArchLinux.txt"]
        let scanRoots: [(dir: URL, prefix: String)] = [
            (docsURL, ""),
            (docsURL.appendingPathComponent("Machines/ArchLinux", isDirectory: true), "Machines/ArchLinux/"),
            (docsURL.appendingPathComponent("Shared", isDirectory: true), "Shared/"),
        ]

        var results: [ContainerFileEntry] = []
        for (dirURL, prefix) in scanRoots {
            guard let items = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            let sorted = items.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
            for itemURL in sorted {
                let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else {
                    continue
                }
                let name = itemURL.lastPathComponent
                let relPath = "\(prefix)\(name)"
                let byteCount = UInt64(max(0, values?.fileSize ?? 0))
                results.append(
                    ContainerFileEntry(
                        id: relPath,
                        relativePath: relPath,
                        fileName: name,
                        sizeText: formatByteCount(byteCount),
                        isDeletable: !seededNames.contains(name)
                    )
                )
            }
        }
        return results
    }

    private static func formatByteCount(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        let kib = Double(bytes) / 1024.0
        if kib < 1024.0 {
            return String(format: "%.1f KiB", kib)
        }
        let mib = kib / 1024.0
        if mib < 1024.0 {
            return String(format: "%.1f MiB", mib)
        }
        return String(format: "%.2f GiB", mib / 1024.0)
    }

    private static func isValidPropertyListDictionary(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return false
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              !dict.isEmpty else {
            return false
        }
        return true
    }

    private static func formattedFileSize(at url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = (attrs[.size] as? NSNumber)?.uint64Value,
              bytes > 0 else {
            return ""
        }
        let mib = Double(bytes) / (1024.0 * 1024.0)
        if mib >= 1024.0 {
            return String(format: " · %.2f GiB", mib / 1024.0)
        }
        return String(format: " · %.0f MiB", max(mib, 1.0))
    }

    /// Imports one or more security-scoped URLs selected from the iOS File Browser or Share Sheet.
    @discardableResult
    func importFiles(from urls: [URL], forceAsPairingPlist: Bool = false) throws -> String {
        bootstrapSandboxFolders()
        let fm = FileManager.default
        var importedNames: [String] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let rawName = url.lastPathComponent
            let lowerName = rawName.lowercased()
            let isPairingCandidate = forceAsPairingPlist
                || lowerName.hasSuffix(".plist")
                || lowerName.hasSuffix(".mobiledevicepairing")

            if isPairingCandidate {
                let data = try Data(contentsOf: url)
                guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dict = plist as? [String: Any],
                      !dict.isEmpty else {
                    throw NSError(
                        domain: "io.hengelinux.import",
                        code: 3001,
                        userInfo: [NSLocalizedDescriptionKey: "'\(rawName)' is not a valid Apple lockdown property list (.plist / .mobiledevicepairing)."]
                    )
                }
                try data.write(to: pairingFileURL, options: .atomic)
                _ = syncPairingRecordToAppGroup()
                importedNames.append("pairing.plist")
                continue
            }

            let targetURL: URL
            if lowerName.hasSuffix(".hvsparse") {
                targetURL = machineDirectoryURL.appendingPathComponent("archlinux.hvsparse")
            } else if lowerName.hasSuffix(".img") || lowerName.hasSuffix(".raw") {
                targetURL = machineDirectoryURL.appendingPathComponent("archlinux.img")
            } else if lowerName.hasSuffix(".fd") {
                if lowerName.contains("vars") {
                    targetURL = machineDirectoryURL.appendingPathComponent("vars.fd")
                } else if lowerName.contains("code") || lowerName.contains("efi") {
                    targetURL = machineDirectoryURL.appendingPathComponent("code.fd")
                } else {
                    targetURL = machineDirectoryURL.appendingPathComponent(rawName)
                }
            } else if Self.isValidPropertyListDictionary(at: url) {
                let data = try Data(contentsOf: url)
                try data.write(to: pairingFileURL, options: .atomic)
                _ = syncPairingRecordToAppGroup()
                importedNames.append("pairing.plist")
                continue
            } else {
                targetURL = machineDirectoryURL.appendingPathComponent(rawName)
            }

            if fm.fileExists(atPath: targetURL.path) {
                try fm.removeItem(at: targetURL)
            }
            try fm.copyItem(at: url, to: targetURL)
            importedNames.append(targetURL.lastPathComponent)
        }

        refreshFileStatus()
        guard !importedNames.isEmpty else {
            return "No files were selected for import."
        }
        return "Imported \(importedNames.joined(separator: ", ")) into HengeLinux container."
    }

    /// Mirrors `Documents/pairing.plist` into the App Group container so
    /// `HengeLinuxJITExtension` can read it directly without large XPC payloads.
    @discardableResult
    func syncPairingRecordToAppGroup() -> Bool {
        let fm = FileManager.default
        defer { refreshFileStatus() }
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
