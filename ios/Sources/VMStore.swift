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
        ("debian", "Debian"),
        ("ubuntu", "Ubuntu"),
        ("fedora", "Fedora"),
        ("alpine", "Alpine Linux"),
        ("opensuse", "openSUSE"),
        ("void", "Void Linux"),
        ("linux", "Generic ARM64 Linux")
    ]

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
        return "Missing (Import .hvsparse / .img / .raw)"
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

    /// Imports guest disk, ISO, or firmware files into the specified VM (and shared Firmware/).
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
            let targetURL: URL

            if lowerName.hasSuffix(".hvsparse") {
                let destName = (vm.id == "ArchLinux") ? "archlinux.hvsparse" : "disk0.hvsparse"
                targetURL = vmDir.appendingPathComponent(destName)
                let staleRawName = (vm.id == "ArchLinux") ? "archlinux.img" : "disk0.img"
                let staleRawURL = vmDir.appendingPathComponent(staleRawName)
                if fm.fileExists(atPath: staleRawURL.path) {
                    try? fm.removeItem(at: staleRawURL)
                }
                updated.primaryDiskFileName = destName
            } else if lowerName.hasSuffix(".img") || lowerName.hasSuffix(".raw") {
                let destName = (vm.id == "ArchLinux") ? "archlinux.img" : "disk0.img"
                targetURL = vmDir.appendingPathComponent(destName)
                updated.primaryDiskFileName = destName
            } else if lowerName.hasSuffix(".iso") {
                targetURL = vmDir.appendingPathComponent(rawName)
                updated.secondaryMediaFileName = rawName
            } else if lowerName.hasSuffix(".fd") {
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
            } else {
                targetURL = vmDir.appendingPathComponent(rawName)
            }

            if fm.fileExists(atPath: targetURL.path) {
                try fm.removeItem(at: targetURL)
            }
            try fm.copyItem(at: url, to: targetURL)
            importedNames.append(targetURL.lastPathComponent)
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
