// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct VMConfig: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var distroTag: String
    var ramMiB: Int
    var cpuCount: Int
    var gpuBackend: Int
    var enableVirtioInput: Bool
    var enableXhci: Bool
    var enableAcpiSpcr: Bool
    var primaryDiskFileName: String
    var secondaryMediaFileName: String?

    static let distroOptions: [(tag: String, label: String)] = [
        ("arch", "Arch Linux"),
        ("debian", "Debian 13 (Cloud / ISO)"),
        ("ubuntu", "Ubuntu 24.04 / 26.04 LTS"),
        ("fedora", "Fedora Cloud Base"),
        ("alpine", "Alpine Linux (nocloud)"),
        ("opensuse", "openSUSE (Tumbleweed / Leap)"),
        ("void", "Void Linux"),
        ("linux", "Blank Disk + ARM64 Live ISO")
    ]

    static func quickHint(for distroTag: String) -> String {
        switch distroTag {
        case "debian":
            return "Import debian-13-generic-arm64.qcow2 (includes virtio drivers + cloud-init)."
        case "ubuntu":
            return "Import ubuntu-24.04-server-cloudimg-arm64.img (auto-detected as QCOW2)."
        case "fedora":
            return "Import Fedora-Cloud-Base-Generic.aarch64.qcow2 (expanded to >= 8 GiB sparse)."
        case "alpine":
            return "Import nocloud_alpine-*-aarch64-uefi-cloudinit-r0.qcow2 (tiny-cloud)."
        case "opensuse":
            return "Import openSUSE Tumbleweed/Leap Minimal-VM Cloud QCOW2."
        case "linux":
            return "Creates a blank APFS sparse disk0.img; import any ARM64 Live/Netinstall .iso onto disk1."
        default:
            return "Import a .hvsparse, .qcow2, .img/.raw disk, or an ARM64 .iso installer."
        }
    }

    static func legacyArchDefault(ramMiB: Int = 1664) -> VMConfig {
        VMConfig(
            id: "ArchLinux",
            name: "Arch Linux",
            distroTag: "arch",
            ramMiB: ramMiB,
            cpuCount: 4,
            gpuBackend: 0,
            enableVirtioInput: true,
            enableXhci: false,
            enableAcpiSpcr: true,
            primaryDiskFileName: "archlinux.hvsparse",
            secondaryMediaFileName: nil
        )
    }

    var distroDisplayName: String {
        Self.distroOptions.first(where: { $0.tag == distroTag })?.label ?? "ARM64 Linux"
    }
}

/// Manages multi-VM configuration manifests (`Documents/Machines/<ID>/vm.json`),
/// shared UEFI firmware (`Documents/Firmware/`), and automatic zero-loss migration
/// from the `v0.1.0` `Documents/Machines/ArchLinux/` layout.
@MainActor
final class VMStore: ObservableObject {
    @Published private(set) var machines: [VMConfig] = []
    @Published var selectedMachineID: String = "" {
        didSet {
            if !selectedMachineID.isEmpty {
                UserDefaults.standard.set(selectedMachineID, forKey: Self.selectedVMDefaultsKey)
            }
        }
    }

    static let selectedVMDefaultsKey = "selectedMachineID"

    var documentsDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    var firmwareDirectoryURL: URL {
        documentsDirectoryURL.appendingPathComponent("Firmware", isDirectory: true)
    }

    var machinesRootURL: URL {
        documentsDirectoryURL.appendingPathComponent("Machines", isDirectory: true)
    }

    var sharedDirectoryURL: URL {
        documentsDirectoryURL.appendingPathComponent("Shared", isDirectory: true)
    }

    var selectedMachine: VMConfig {
        if let found = machines.first(where: { $0.id == selectedMachineID }) {
            return found
        }
        if let first = machines.first {
            return first
        }
        return VMConfig.legacyArchDefault()
    }

    init() {
        bootstrapAndMigrate()
        reloadMachines()
    }

    func machineDirectoryURL(for id: String) -> URL {
        machinesRootURL.appendingPathComponent(id, isDirectory: true)
    }

    func manifestURL(for id: String) -> URL {
        machineDirectoryURL(for: id).appendingPathComponent("vm.json")
    }

    func resolvedCodeFirmwareURL(for vm: VMConfig) -> URL {
        let fm = FileManager.default
        let perVm = machineDirectoryURL(for: vm.id).appendingPathComponent("code.fd")
        if fm.fileExists(atPath: perVm.path) {
            return perVm
        }
        let sharedStandard = firmwareDirectoryURL.appendingPathComponent("edk2-aarch64-code.fd")
        if fm.fileExists(atPath: sharedStandard.path) {
            return sharedStandard
        }
        let sharedShort = firmwareDirectoryURL.appendingPathComponent("code.fd")
        if fm.fileExists(atPath: sharedShort.path) {
            return sharedShort
        }
        return perVm
    }

    func resolvedVarsFirmwareURL(for vm: VMConfig) -> URL {
        let fm = FileManager.default
        let vmDir = machineDirectoryURL(for: vm.id)
        let perVm = vmDir.appendingPathComponent("vars.fd")
        if fm.fileExists(atPath: perVm.path) {
            return perVm
        }
        let templateCandidates = [
            firmwareDirectoryURL.appendingPathComponent("edk2-aarch64-vars-template.fd"),
            firmwareDirectoryURL.appendingPathComponent("vars.fd"),
            machinesRootURL.appendingPathComponent("ArchLinux/vars.fd")
        ]
        for candidate in templateCandidates where fm.fileExists(atPath: candidate.path) {
            try? fm.createDirectory(at: vmDir, withIntermediateDirectories: true, attributes: nil)
            try? fm.copyItem(at: candidate, to: perVm)
            break
        }
        return perVm
    }

    func resolvedSecondaryMediaURL(for vm: VMConfig) -> URL? {
        guard let name = vm.secondaryMediaFileName, !name.isEmpty else {
            return nil
        }
        let url = machineDirectoryURL(for: vm.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func diskStatusText(for vm: VMConfig) -> String {
        let fm = FileManager.default
        let dir = machineDirectoryURL(for: vm.id)
        let primary = dir.appendingPathComponent(vm.primaryDiskFileName)
        if fm.fileExists(atPath: primary.path) {
            return "\(vm.primaryDiskFileName) (Ready\(Self.formattedSize(at: primary)))"
        }
        let fallbackRaw = dir.appendingPathComponent("archlinux.img")
        if vm.id == "ArchLinux", fm.fileExists(atPath: fallbackRaw.path) {
            return "archlinux.img (Ready\(Self.formattedSize(at: fallbackRaw)))"
        }
        let genericRaw = dir.appendingPathComponent("disk0.img")
        if fm.fileExists(atPath: genericRaw.path) {
            return "disk0.img (Ready\(Self.formattedSize(at: genericRaw)))"
        }
        return "Missing (Import .hvsparse / .qcow2 / .img / .raw)"
    }

    func uefiStatusText(for vm: VMConfig) -> String {
        let fm = FileManager.default
        let codeURL = resolvedCodeFirmwareURL(for: vm)
        let varsURL = resolvedVarsFirmwareURL(for: vm)
        let hasCode = fm.fileExists(atPath: codeURL.path)
        let hasVars = fm.fileExists(atPath: varsURL.path)
        switch (hasCode, hasVars) {
        case (true, true):
            let sharedTag = codeURL.deletingLastPathComponent().lastPathComponent == "Firmware" ? " · Shared" : ""
            return "code.fd + vars.fd (Ready\(sharedTag))"
        case (true, false):
            return "code.fd present (Need vars.fd)"
        case (false, true):
            return "vars.fd present (Need code.fd)"
        case (false, false):
            return "Missing (Import code.fd & vars.fd)"
        }
    }

    func bootstrapAndMigrate() {
        let fm = FileManager.default
        try? fm.createDirectory(at: firmwareDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fm.createDirectory(at: machinesRootURL, withIntermediateDirectories: true, attributes: nil)
        try? fm.createDirectory(at: sharedDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        // Seed shared Firmware/ from legacy ArchLinux firmware if present
        let legacyDir = machineDirectoryURL(for: "ArchLinux")
        let legacyCode = legacyDir.appendingPathComponent("code.fd")
        let sharedCode = firmwareDirectoryURL.appendingPathComponent("edk2-aarch64-code.fd")
        if fm.fileExists(atPath: legacyCode.path), !fm.fileExists(atPath: sharedCode.path) {
            try? fm.copyItem(at: legacyCode, to: sharedCode)
        }
        let legacyVars = legacyDir.appendingPathComponent("vars.fd")
        let sharedVars = firmwareDirectoryURL.appendingPathComponent("edk2-aarch64-vars-template.fd")
        if fm.fileExists(atPath: legacyVars.path), !fm.fileExists(atPath: sharedVars.path) {
            try? fm.copyItem(at: legacyVars, to: sharedVars)
        }

        // Auto-migrate legacy Documents/Machines/ArchLinux/ (or create default entry)
        let existingSubdirs = (try? fm.contentsOfDirectory(
            at: machinesRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []

        let hasAnyManifest = existingSubdirs.contains {
            fm.fileExists(atPath: $0.appendingPathComponent("vm.json").path)
        }

        if fm.fileExists(atPath: legacyDir.path) || !hasAnyManifest {
            try? fm.createDirectory(at: legacyDir, withIntermediateDirectories: true, attributes: nil)
            let legacyManifest = manifestURL(for: "ArchLinux")
            if !fm.fileExists(atPath: legacyManifest.path) {
                var cfg = VMConfig.legacyArchDefault()
                let savedRam = UserDefaults.standard.integer(forKey: "customGuestRamMiB")
                if savedRam >= Int(HENGE_MIN_GUEST_RAM_MIB) && savedRam <= Int(HENGE_MAX_GUEST_RAM_MIB) {
                    cfg.ramMiB = savedRam
                }
                if !fm.fileExists(atPath: legacyDir.appendingPathComponent("archlinux.hvsparse").path),
                   fm.fileExists(atPath: legacyDir.appendingPathComponent("archlinux.img").path) {
                    cfg.primaryDiskFileName = "archlinux.img"
                }
                try? saveManifest(cfg)
            }
        }
    }

    func reloadMachines() {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: machinesRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let decoder = JSONDecoder()
        var loaded: [VMConfig] = []
        for dir in subdirs {
            let manifest = dir.appendingPathComponent("vm.json")
            guard let data = try? Data(contentsOf: manifest),
                  let cfg = try? decoder.decode(VMConfig.self, from: data) else {
                continue
            }
            loaded.append(cfg)
        }
        loaded.sort { lhs, rhs in
            if lhs.id == "ArchLinux" { return true }
            if rhs.id == "ArchLinux" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        machines = loaded

        let savedID = UserDefaults.standard.string(forKey: Self.selectedVMDefaultsKey) ?? ""
        if loaded.contains(where: { $0.id == savedID }) {
            selectedMachineID = savedID
        } else if let first = loaded.first {
            selectedMachineID = first.id
        }
    }

    @discardableResult
    func createMachine(
        name: String,
        distroTag: String,
        ramMiB: Int,
        cpuCount: Int
    ) throws -> VMConfig {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Linux VM" : trimmed
        let id = UUID().uuidString
        let vmDir = machineDirectoryURL(for: id)
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true, attributes: nil)

        let cfg = VMConfig(
            id: id,
            name: finalName,
            distroTag: distroTag,
            ramMiB: min(max(ramMiB, Int(HENGE_MIN_GUEST_RAM_MIB)), Int(HENGE_MAX_GUEST_RAM_MIB)),
            cpuCount: min(max(cpuCount, 1), 8),
            gpuBackend: 0,
            enableVirtioInput: true,
            enableXhci: false,
            enableAcpiSpcr: true,
            primaryDiskFileName: "disk0.img",
            secondaryMediaFileName: nil
        )
        try saveManifest(cfg)
        _ = resolvedVarsFirmwareURL(for: cfg)
        reloadMachines()
        selectedMachineID = cfg.id
        return cfg
    }

    func updateMachine(_ vm: VMConfig) {
        try? saveManifest(vm)
        if let idx = machines.firstIndex(where: { $0.id == vm.id }) {
            machines[idx] = vm
        }
    }

    func deleteMachine(id: String) throws {
        guard machines.count > 1 else {
            return
        }
        let dir = machineDirectoryURL(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        reloadMachines()
    }

    func clearSecondaryMedia(for vm: VMConfig) {
        var updated = vm
        if let name = updated.secondaryMediaFileName {
            let url = machineDirectoryURL(for: vm.id).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
        updated.secondaryMediaFileName = nil
        updateMachine(updated)
    }

    func createBlankDisk(for vm: VMConfig, sizeGiB: Int) throws {
        let clampedGiB = min(max(sizeGiB, 2), 64)
        let vmDir = machineDirectoryURL(for: vm.id)
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true, attributes: nil)
        let diskName = "disk0.img"
        let diskURL = vmDir.appendingPathComponent(diskName)
        var errBuf = [CChar](repeating: 0, count: 256)
        let rc = henge_create_sparse_raw_disk(diskURL.path, UInt64(clampedGiB) << 30, &errBuf, errBuf.count)
        if rc != 0 {
            let msg = String(cString: errBuf)
            throw NSError(domain: "io.hengelinux.vm", code: 2010, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        var updated = vm
        updated.primaryDiskFileName = diskName
        updateMachine(updated)
    }

    @discardableResult
    func generateCidataSeed(
        for vm: VMConfig,
        hostname: String,
        username: String,
        password: String,
        sshAuthorizedKey: String? = nil
    ) throws -> URL {
        let vmDir = machineDirectoryURL(for: vm.id)
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true, attributes: nil)
        let seedName = "cidata-seed.img"
        let seedURL = vmDir.appendingPathComponent(seedName)

        let instanceID = "henge-\(vm.id.prefix(12))"
        let cleanHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPass = password.isEmpty ? "linux" : password
        let cleanSSH = sshAuthorizedKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        var errBuf = [CChar](repeating: 0, count: 256)
        let rc: Int32 = instanceID.withCString { cInst in
            (cleanHost.isEmpty ? "hengelinux" : cleanHost).withCString { cHost in
                (cleanUser.isEmpty ? "linux" : cleanUser).withCString { cUser in
                    cleanPass.withCString { cPass in
                        if let ssh = cleanSSH, !ssh.isEmpty {
                            return ssh.withCString { cSSH in
                                var cfg = HengeCidataConfig(
                                    instance_id: cInst,
                                    hostname: cHost,
                                    username: cUser,
                                    password: cPass,
                                    ssh_authorized_key: cSSH
                                )
                                return henge_cidata_write_image(seedURL.path, &cfg, &errBuf, errBuf.count)
                            }
                        } else {
                            var cfg = HengeCidataConfig(
                                instance_id: cInst,
                                hostname: cHost,
                                username: cUser,
                                password: cPass,
                                ssh_authorized_key: nil
                            )
                            return henge_cidata_write_image(seedURL.path, &cfg, &errBuf, errBuf.count)
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = String(cString: errBuf)
            throw NSError(domain: "io.hengelinux.vm", code: 2011, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        var updated = vm
        updated.secondaryMediaFileName = seedName
        updateMachine(updated)
        return seedURL
    }

    @discardableResult
    func cloneMachine(_ source: VMConfig) throws -> VMConfig {
        let fm = FileManager.default
        let newID = UUID().uuidString
        let srcDir = machineDirectoryURL(for: source.id)
        let dstDir = machineDirectoryURL(for: newID)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true, attributes: nil)

        if let items = try? fm.contentsOfDirectory(
            at: srcDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in items {
                let name = item.lastPathComponent
                if name == "vm.json" || name == "suspend.state" || name.hasSuffix(".log") {
                    continue
                }
                let dstItem = dstDir.appendingPathComponent(name)
                var errBuf = [CChar](repeating: 0, count: 256)
                if henge_clone_file_apfs(item.path, dstItem.path, &errBuf, errBuf.count) != 0 {
                    try fm.copyItem(at: item, to: dstItem)
                }
            }
        }

        var cloned = source
        cloned.id = newID
        cloned.name = "\(source.name) Copy"
        try saveManifest(cloned)
        _ = resolvedVarsFirmwareURL(for: cloned)
        reloadMachines()
        selectedMachineID = cloned.id
        return cloned
    }

    func compactPrimaryDisk(for vm: VMConfig) throws -> UInt64 {
        let fm = FileManager.default
        let dir = machineDirectoryURL(for: vm.id)
        let primary = dir.appendingPathComponent(vm.primaryDiskFileName)
        let lower = vm.primaryDiskFileName.lowercased()
        let rawCandidate: URL
        if lower.hasSuffix(".hvsparse") {
            rawCandidate = dir.appendingPathComponent(
                ((vm.primaryDiskFileName as NSString).deletingPathExtension as NSString).appendingPathExtension("img") ?? "disk0.img"
            )
        } else if lower.hasSuffix(".qcow2") {
            rawCandidate = dir.appendingPathComponent(
                "\((vm.primaryDiskFileName as NSString).deletingPathExtension).raw.img"
            )
        } else {
            rawCandidate = primary
        }
        guard fm.fileExists(atPath: rawCandidate.path) else {
            throw NSError(
                domain: "io.hengelinux.vm",
                code: 2012,
                userInfo: [NSLocalizedDescriptionKey: "No unpacked raw disk image found to compact for \(vm.name)."]
            )
        }
        var reclaimed: UInt64 = 0
        var errBuf = [CChar](repeating: 0, count: 256)
        let rc = henge_compact_sparse_file(rawCandidate.path, &reclaimed, &errBuf, errBuf.count)
        if rc != 0 {
            let msg = String(cString: errBuf)
            throw NSError(domain: "io.hengelinux.vm", code: 2013, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return reclaimed
    }

    /// Imports guest disk, QCOW2, ISO, or firmware files into the specified VM using
    /// magic-byte classification ("HVSPARSE", "QFI\xfb", "CD001", or raw).
    @discardableResult
    func importGuestFiles(from urls: [URL], into vm: VMConfig) throws -> String {
        let fm = FileManager.default
        let vmDir = machineDirectoryURL(for: vm.id)
        try fm.createDirectory(at: vmDir, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: firmwareDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        var updated = vm
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
            let magicFmt = henge_detect_image_format(url.path)
            let targetURL: URL

            if lowerName.hasSuffix(".fd") {
                if lowerName.contains("vars") {
                    targetURL = vmDir.appendingPathComponent("vars.fd")
                    let sharedVars = firmwareDirectoryURL.appendingPathComponent("edk2-aarch64-vars-template.fd")
                    if !fm.fileExists(atPath: sharedVars.path) {
                        try? fm.copyItem(at: url, to: sharedVars)
                    }
                } else if lowerName.contains("code") || lowerName.contains("efi") {
                    targetURL = firmwareDirectoryURL.appendingPathComponent("edk2-aarch64-code.fd")
                    let perVmCode = vmDir.appendingPathComponent("code.fd")
                    if fm.fileExists(atPath: perVmCode.path) {
                        try? fm.removeItem(at: perVmCode)
                    }
                    try? fm.copyItem(at: url, to: perVmCode)
                } else {
                    targetURL = vmDir.appendingPathComponent(rawName)
                }
            } else if magicFmt == HENGE_IMG_FORMAT_HVSPARSE || lowerName.hasSuffix(".hvsparse") {
                let destName = (vm.id == "ArchLinux") ? "archlinux.hvsparse" : "disk0.hvsparse"
                targetURL = vmDir.appendingPathComponent(destName)
                let staleRawName = (vm.id == "ArchLinux") ? "archlinux.img" : "disk0.img"
                let staleRawURL = vmDir.appendingPathComponent(staleRawName)
                if fm.fileExists(atPath: staleRawURL.path) {
                    try? fm.removeItem(at: staleRawURL)
                }
                updated.primaryDiskFileName = destName
            } else if magicFmt == HENGE_IMG_FORMAT_QCOW2 || lowerName.hasSuffix(".qcow2") {
                var info = HengeQcow2Info()
                var errBuf = [CChar](repeating: 0, count: 256)
                if henge_qcow2_inspect(url.path, &info, &errBuf, errBuf.count) != 0 {
                    let msg = String(cString: errBuf)
                    throw NSError(
                        domain: "io.hengelinux.import",
                        code: 3002,
                        userInfo: [NSLocalizedDescriptionKey: "Unsupported QCOW2 '\(rawName)': \(msg)"]
                    )
                }
                let destName = "disk0.qcow2"
                targetURL = vmDir.appendingPathComponent(destName)
                let staleRawURL = vmDir.appendingPathComponent("disk0.raw.img")
                if fm.fileExists(atPath: staleRawURL.path) {
                    try? fm.removeItem(at: staleRawURL)
                }
                updated.primaryDiskFileName = destName
            } else if magicFmt == HENGE_IMG_FORMAT_ISO9660 || lowerName.hasSuffix(".iso") {
                targetURL = vmDir.appendingPathComponent(rawName)
                updated.secondaryMediaFileName = rawName
            } else if lowerName.hasSuffix(".img") || lowerName.hasSuffix(".raw") {
                let destName = (vm.id == "ArchLinux") ? "archlinux.img" : "disk0.img"
                targetURL = vmDir.appendingPathComponent(destName)
                updated.primaryDiskFileName = destName
            } else {
                targetURL = vmDir.appendingPathComponent(rawName)
            }

            if fm.fileExists(atPath: targetURL.path) {
                try fm.removeItem(at: targetURL)
            }
            try fm.copyItem(at: url, to: targetURL)
            let fmtTag: String
            switch magicFmt {
            case HENGE_IMG_FORMAT_QCOW2: fmtTag = " [QCOW2]"
            case HENGE_IMG_FORMAT_HVSPARSE: fmtTag = " [HVSPARSE]"
            case HENGE_IMG_FORMAT_ISO9660: fmtTag = " [ISO9660]"
            default: fmtTag = ""
            }
            importedNames.append("\(targetURL.lastPathComponent)\(fmtTag)")
        }

        updateMachine(updated)
        guard !importedNames.isEmpty else {
            return "No files were selected for import."
        }
        return "Imported \(importedNames.joined(separator: ", ")) into \(updated.name)."
    }

    private func saveManifest(_ vm: VMConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(vm)
        try data.write(to: manifestURL(for: vm.id), options: .atomic)
    }

    private static func formattedSize(at url: URL) -> String {
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
}
