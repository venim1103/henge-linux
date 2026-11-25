// SPDX-License-Identifier: GPL-3.0-or-later
import UniformTypeIdentifiers
import SafariServices
import SwiftUI
import UIKit

struct MachineProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let ramMiB: Int
    let cpuCount: Int

    static let presets: [MachineProfile] = [
        MachineProfile(
            id: "iphone-compact",
            name: "iPhone (4–6 GB RAM)",
            subtitle: "iPhone 13–15 · 1.0 GiB guest RAM · 2 vCPU · Conservative Jetsam budget",
            ramMiB: 1024,
            cpuCount: 2
        ),
        MachineProfile(
            id: "iphone-8gb",
            name: "iPhone Pro (8 GB RAM)",
            subtitle: "iPhone 15/16 Pro · 1.5 GiB guest RAM · 4 vCPU · Safe for VirGL 3D",
            ramMiB: 1536,
            cpuCount: 4
        ),
        MachineProfile(
            id: "iphone-12gb",
            name: "iPhone 12 GB Pro / Duo (Entitled)",
            subtitle: "3.0 GiB guest RAM · 4 vCPU · Requires increased-memory-limit",
            ramMiB: 3072,
            cpuCount: 4
        ),
        MachineProfile(
            id: "ipad-pro",
            name: "M-Series iPad Pro (Entitled)",
            subtitle: "4.0 GiB guest RAM · 6 vCPU · External USB-C display & high-RAM tier",
            ramMiB: 4096,
            cpuCount: 6
        )
    ]

    /// Returns the safest default profile matching the host device's physical RAM
    /// and live iOS Jetsam entitlement ceiling (`os_proc_available_memory`).
    static func defaultForCurrentDevice() -> MachineProfile {
        let physicalGiB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let entitled = henge_is_entitled_high_memory()
        if physicalGiB < 7 {
            return presets[0] // 1.0 GiB / 2 vCPU
        }
        if entitled {
            if physicalGiB >= 14 {
                return presets[3] // 4.0 GiB / 6 vCPU
            }
            if physicalGiB >= 10 {
                return presets[2] // 3.0 GiB / 4 vCPU
            }
        }
        return presets[1] // 1.5 GiB / 4 vCPU (safe on standard SideStore ledger)
    }
}

@main
struct HengeLinuxApp: App {
    private enum FileImportMode {
        case pairingPlist
        case guestFiles
    }

    private enum StartTab: Hashable {
        case machines
        case hardware
        case storage
        case information
    }

    @StateObject private var lifecycle = MetalLifecycleGuard()
    @StateObject private var jitClient = SelfDebugJITClient()
    @StateObject private var vmStore = VMStore()
    @StateObject private var downloader = DistroDownloadManager()
    @ObservedObject private var externalDisplay = ExternalDisplayManager.shared
    @AppStorage("oledScreenSaverAutoDimSeconds") private var oledAutoDimSeconds: Int = 0
    @State private var selectedStartTab: StartTab = .machines
    @State private var copiedBuildInfo: Bool = false
    @State private var selectedProfile: MachineProfile = MachineProfile.defaultForCurrentDevice()
    @AppStorage("customGuestRamMiB") private var customGuestRamMiB: Int = 1536
    @State private var ramInputText: String = ""
    @State private var isRunning: Bool = false
    @State private var isPreparingDisk: Bool = false
    @State private var isImportingFile: Bool = false
    @State private var showDebugConsole: Bool = false
    @State private var showNewVMSheet: Bool = false
    @State private var showDownloadGallery: Bool = false
    @State private var galleryDiskGiB: Int = 16
    @State private var customDownloadURLText: String = ""
    @State private var customDownloadVMName: String = ""
    @State private var customDownloadDistroTag: String = "debian"
    @State private var customDownloadCidata: Bool = true
    @State private var newVMName: String = ""
    @State private var newVMDistroTag: String = "debian"
    @State private var newVMCreateBlankDisk: Bool = false
    @State private var newVMBlankDiskGiB: Int = 16
    @State private var newVMGenerateCidata: Bool = true
    @State private var cidataUsername: String = "linux"
    @State private var cidataPassword: String = "linux"
    @State private var cidataHostname: String = "hengelinux"
    @State private var showCidataSheet: Bool = false
    @State private var showExpandDiskSheet: Bool = false
    @State private var gpuRecoveryVMName: String? = nil
    @State private var gpuRecoveryVMID: String? = nil
    @State private var expandDiskGiB: Int = 16
    @State private var fileImportMode: FileImportMode = .pairingPlist
    @State private var bootWarning: String?
    @State private var bootErrorAlert: String?
    @State private var posture: DevicePosture = .singleScreen
    @State private var safariURL: IdentifiableURL?
    @AppStorage("autoSyncClipboard") private var autoSyncClipboard: Bool = false
    @State private var lastPushedClipboard: String = ""
    @State private var lastPasteboardChangeCount: Int = -1
    @State private var memoryRefreshTick: Int = 0

    private let bridgePollTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some Scene {
        WindowGroup {
            Group {
                if isRunning {
                    SessionView(
                        profile: selectedProfile,
                        lifecycle: lifecycle,
                        externalDisplay: externalDisplay,
                        posture: $posture,
                        bootWarning: bootWarning,
                        onStopSession: {
                            UserDefaults.standard.set(false, forKey: "hengeGpuInitInProgress")
                            UserDefaults.standard.removeObject(forKey: "hengeGpuInitMachineID")
                            if HengeVMBridge.shared.isRunning {
                                HengeVMBridge.shared.stopGuest()
                            }
                            isRunning = false
                            bootWarning = nil
                            jitClient.prepareForReboot()
                            memoryRefreshTick &+= 1
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                memoryRefreshTick &+= 1
                            }
                        }
                    )
                } else {
                    TabView(selection: $selectedStartTab) {
                        machinesTabView
                            .tabItem {
                                Label("Machines", systemImage: "desktopcomputer")
                            }
                            .tag(StartTab.machines)

                        hardwareTabView
                            .tabItem {
                                Label("Hardware", systemImage: "cpu")
                            }
                            .tag(StartTab.hardware)

                        storageTabView
                            .tabItem {
                                Label("Images & Disks", systemImage: "externaldrive.fill")
                            }
                            .tag(StartTab.storage)

                        informationTabView
                            .tabItem {
                                Label("Information", systemImage: "info.circle")
                            }
                            .tag(StartTab.information)
                    }
                }
            }
            .sheet(item: $safariURL) { item in
                SafariSheetView(url: item.url)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showDebugConsole) {
                DebugConsoleSheetView()
            }
            .sheet(isPresented: $showNewVMSheet) {
                NavigationStack {
                    Form {
                        Section("Machine Identity") {
                            TextField("VM Name (e.g. Debian 13 ARM64)", text: $newVMName)
                            Picker("Distribution", selection: $newVMDistroTag) {
                                ForEach(VMConfig.distroOptions, id: \.tag) { opt in
                                    Text(opt.label).tag(opt.tag)
                                }
                            }
                            .onChange(of: newVMDistroTag) { _, tag in
                                newVMCreateBlankDisk = (tag == "linux")
                                newVMGenerateCidata = ["debian", "ubuntu", "fedora", "alpine", "opensuse"].contains(tag)
                            }
                            Text(VMConfig.quickHint(for: newVMDistroTag))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Section("Storage & Cloud-Init") {
                            Toggle("Create Blank Sparse Disk (for Live/Netinstall ISO)", isOn: $newVMCreateBlankDisk)
                            if newVMCreateBlankDisk {
                                Stepper("Virtual Disk Size: \(newVMBlankDiskGiB) GiB", value: $newVMBlankDiskGiB, in: 4...64, step: 4)
                            }
                            Toggle("Generate Offline CIDATA NoCloud Seed", isOn: $newVMGenerateCidata)
                            if newVMGenerateCidata {
                                TextField("Hostname", text: $cidataHostname)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                TextField("Username", text: $cidataUsername)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                TextField("Password", text: $cidataPassword)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                        Section("Defaults") {
                            LabeledContent("Guest RAM", value: "\(effectiveRamMiB) MiB")
                            LabeledContent("vCPUs", value: "\(vmStore.selectedMachine.cpuCount)")
                            LabeledContent("VirtIO Input", value: "Enabled (Keyboard + Tablet)")
                            LabeledContent("USB 3.0 xHCI", value: "Disabled (No 90s Linux stall)")
                        }
                    }
                    .navigationTitle("New Linux VM")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showNewVMSheet = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create") {
                                do {
                                    let defaultGpu = ["debian", "fedora", "opensuse"].contains(newVMDistroTag) ? 2 : 0
                                    let created = try vmStore.createMachine(
                                        name: newVMName,
                                        distroTag: newVMDistroTag,
                                        ramMiB: Int(effectiveRamMiB),
                                        cpuCount: vmStore.selectedMachine.cpuCount,
                                        gpuBackend: defaultGpu,
                                        targetDiskSizeGiB: newVMCreateBlankDisk ? newVMBlankDiskGiB : 16
                                    )
                                    if newVMCreateBlankDisk {
                                        try vmStore.createBlankDisk(for: created, sizeGiB: newVMBlankDiskGiB)
                                    }
                                    if newVMGenerateCidata {
                                        _ = try vmStore.generateCidataSeed(
                                            for: vmStore.selectedMachine,
                                            hostname: cidataHostname,
                                            username: cidataUsername,
                                            password: cidataPassword
                                        )
                                    }
                                    jitClient.refreshFileStatus()
                                    bootWarning = "Created VM '\(created.name)' in Machines/\(created.id)/."
                                    newVMName = ""
                                    showNewVMSheet = false
                                } catch {
                                    bootErrorAlert = "Create VM failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showCidataSheet) {
                NavigationStack {
                    Form {
                        Section("Cloud-Init NoCloud (FAT16 CIDATA)") {
                            TextField("Hostname", text: $cidataHostname)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Username", text: $cidataUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Password", text: $cidataPassword)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("Attaches a 2 MiB FAT16 volume labeled CIDATA (/meta-data, /user-data, /network-config) onto disk1 for Debian, Ubuntu, Fedora, Alpine, and openSUSE cloud images.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Generate CIDATA Seed")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showCidataSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Generate") {
                                do {
                                    let url = try vmStore.generateCidataSeed(
                                        for: vmStore.selectedMachine,
                                        hostname: cidataHostname,
                                        username: cidataUsername,
                                        password: cidataPassword
                                    )
                                    jitClient.refreshFileStatus()
                                    bootWarning = "Generated \(url.lastPathComponent) (CIDATA FAT16) for \(vmStore.selectedMachine.name)."
                                    showCidataSheet = false
                                } catch {
                                    bootErrorAlert = "CIDATA generation failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showDownloadGallery) {
                distroDownloadGallerySheet
            }
            .sheet(isPresented: $showExpandDiskSheet) {
                let vm = vmStore.selectedMachine
                let currentBytes = vmStore.primaryDiskVirtualSizeBytes(for: vm)
                let currentGiB = Int(currentBytes >> 30)
                let minSelectableGiB = max(8, currentGiB)
                NavigationStack {
                    Form {
                        Section("Virtual Disk Size (\(vm.name))") {
                            LabeledContent("Current Virtual Size") {
                                if currentBytes > 0 {
                                    Text(String(format: "%.2f GiB", Double(currentBytes) / Double(1 << 30)))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Archive (unpacks on boot)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Stepper(
                                "Target Size: \(max(expandDiskGiB, minSelectableGiB)) GiB",
                                value: $expandDiskGiB,
                                in: minSelectableGiB...128,
                                step: 4
                            )
                            HStack(spacing: 8) {
                                ForEach([8, 16, 32, 64], id: \.self) { preset in
                                    Button("\(preset)G") {
                                        expandDiskGiB = max(preset, minSelectableGiB)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(preset < minSelectableGiB)
                                }
                            }
                            Text("APFS sparse expansion extends the virtual disk immediately using near-zero host storage until Linux writes data. On next boot, henge-grow-root (or cloud-init) automatically grows the GPT partition and root filesystem. Shrinking is disabled for safety.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Expand Virtual Disk")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showExpandDiskSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Expand") {
                                do {
                                    let chosen = max(expandDiskGiB, minSelectableGiB)
                                    let result = try vmStore.expandPrimaryDisk(for: vm, targetGiB: chosen)
                                    jitClient.refreshFileStatus()
                                    let gib = Double(result.finalBytes) / Double(1 << 30)
                                    if result.appliedImmediately {
                                        bootWarning = String(format: "Expanded %@ virtual disk to %.1f GiB. Boot Linux to auto-grow the root filesystem.", vm.name, gib)
                                    } else {
                                        bootWarning = String(format: "Scheduled %@ virtual disk expansion to %.0f GiB on first boot.", vm.name, gib)
                                    }
                                    showExpandDiskSheet = false
                                } catch {
                                    bootErrorAlert = "Disk expansion failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
            }
            .onReceive(bridgePollTimer) { _ in
                guard isRunning else { return }
                if !HengeVMBridge.shared.isRunning {
                    UserDefaults.standard.set(false, forKey: "hengeGpuInitInProgress")
                    UserDefaults.standard.removeObject(forKey: "hengeGpuInitMachineID")
                    isRunning = false
                    safariURL = nil
                    jitClient.prepareForReboot()
                    memoryRefreshTick &+= 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        memoryRefreshTick &+= 1
                    }
                    return
                }
                if let pending = HengeVMBridge.shared.takePendingOpenURL(),
                   let url = URL(string: pending),
                   let scheme = url.scheme?.lowercased(),
                   (scheme == "http" || scheme == "https"),
                   url.host != nil {
                    safariURL = IdentifiableURL(url: url)
                }
                if HengeVMBridge.shared.takePendingOAuthDone() {
                    safariURL = nil
                }
                if let guestClip = HengeVMBridge.shared.takeGuestClipboard(), !guestClip.isEmpty {
                    lastPushedClipboard = guestClip
                    UIPasteboard.general.string = guestClip
                    lastPasteboardChangeCount = UIPasteboard.general.changeCount
                }
                if UserDefaults.standard.bool(forKey: "hengeGpuInitInProgress") {
                    var tsnap = HengeGpuTelemetrySnapshot()
                    henge_gpu_telemetry_get_snapshot(&tsnap)
                    if tsnap.virgl_3d_flushes >= 5 {
                        UserDefaults.standard.set(false, forKey: "hengeGpuInitInProgress")
                        UserDefaults.standard.removeObject(forKey: "hengeGpuInitMachineID")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                guard isRunning else { return }
                var bgTaskID: UIBackgroundTaskIdentifier = .invalid
                bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "HengeDiskFlush") {
                    if bgTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskID)
                        bgTaskID = .invalid
                    }
                }
                _ = HengeVMBridge.shared.saveBackgroundSnapshot()
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                jitClient.refreshFileStatus()
                memoryRefreshTick &+= 1
                guard isRunning, autoSyncClipboard else { return }
                let pb = UIPasteboard.general
                guard pb.changeCount != lastPasteboardChangeCount, pb.hasStrings else {
                    return
                }
                lastPasteboardChangeCount = pb.changeCount
                guard let hostClip = pb.string, !hostClip.isEmpty else {
                    return
                }
                lastPushedClipboard = hostClip
                HengeVMBridge.shared.pushHostClipboard(hostClip)
            }
            .onAppear {
                let defaults = UserDefaults.standard
                if defaults.bool(forKey: "hengeGpuInitInProgress") {
                    defaults.set(false, forKey: "hengeGpuInitInProgress")
                    let crashedID = defaults.string(forKey: "hengeGpuInitMachineID")
                    defaults.removeObject(forKey: "hengeGpuInitMachineID")
                    if let crashedID, var crashedVM = vmStore.machines.first(where: { $0.id == crashedID }) {
                        crashedVM.gpuBackend = 2 /* Auto-fallback to Enhanced 2D VirtIO-GPU KMS */
                        vmStore.updateMachine(crashedVM)
                        gpuRecoveryVMName = crashedVM.name
                        gpuRecoveryVMID = crashedVM.id
                    }
                }
                let vm = vmStore.selectedMachine
                if vm.ramMiB >= Int(HENGE_MIN_GUEST_RAM_MIB) && vm.ramMiB <= Int(HENGE_MAX_GUEST_RAM_MIB) {
                    customGuestRamMiB = vm.ramMiB
                }
                jitClient.gpuBackend = GpuDisplayBackend.from(modeCode: vm.gpuBackend)
                externalDisplay.dualScanoutEnabled = vm.dualScanoutEnabled ?? false
                HengeVMBridge.shared.setDualScanoutEnabled(vm.dualScanoutEnabled ?? false)
                HengeVMBridge.shared.setConfiguredVramCapMiB(UInt32(max(0, vm.vramCapMiB ?? 0)))
                HengeVMBridge.shared.setTargetRefreshHz(UInt32(max(30, vm.refreshRateHz ?? 60)))
                if ramInputText.isEmpty {
                    ramInputText = "\(effectiveRamMiB)"
                }
            }
            .onChange(of: vmStore.selectedMachineID) { _, _ in
                let vm = vmStore.selectedMachine
                customGuestRamMiB = min(max(vm.ramMiB, Int(HENGE_MIN_GUEST_RAM_MIB)), Int(HENGE_MAX_GUEST_RAM_MIB))
                jitClient.gpuBackend = GpuDisplayBackend.from(modeCode: vm.gpuBackend)
                externalDisplay.dualScanoutEnabled = vm.dualScanoutEnabled ?? false
                HengeVMBridge.shared.setDualScanoutEnabled(vm.dualScanoutEnabled ?? false)
                HengeVMBridge.shared.setConfiguredVramCapMiB(UInt32(max(0, vm.vramCapMiB ?? 0)))
                HengeVMBridge.shared.setTargetRefreshHz(UInt32(max(30, vm.refreshRateHz ?? 60)))
                ramInputText = "\(effectiveRamMiB)"
            }
            .onChange(of: customGuestRamMiB) { _, newRam in
                var vm = vmStore.selectedMachine
                let aligned = Int(effectiveRamMiB)
                if vm.ramMiB != aligned && newRam >= Int(HENGE_MIN_GUEST_RAM_MIB) {
                    vm.ramMiB = aligned
                    vmStore.updateMachine(vm)
                }
            }
            .onChange(of: jitClient.gpuBackend) { _, newBackend in
                var vm = vmStore.selectedMachine
                let code = Int(newBackend.modeCode)
                if vm.gpuBackend != code {
                    vm.gpuBackend = code
                    vmStore.updateMachine(vm)
                }
            }
            .onChange(of: isRunning) { _, running in
                UIApplication.shared.isIdleTimerDisabled = running
                if running {
                    AudioSessionManager.shared.activate()
                } else {
                    AudioSessionManager.shared.deactivate()
                }
                if externalDisplay.isVMRunning != running {
                    externalDisplay.setVMRunning(running)
                }
            }
            .onOpenURL { url in
                do {
                    let lower = url.lastPathComponent.lowercased()
                    if lower.hasSuffix(".plist") || lower.hasSuffix(".mobiledevicepairing") {
                        bootWarning = try jitClient.importFiles(from: [url], forceAsPairingPlist: true)
                    } else {
                        bootWarning = try vmStore.importGuestFiles(from: [url], into: vmStore.selectedMachine)
                        jitClient.refreshFileStatus()
                    }
                } catch {
                    bootErrorAlert = "Import failed: \(error.localizedDescription)"
                }
            }
            .alert("Unable to Start VM", isPresented: Binding(
                get: { bootErrorAlert != nil },
                set: { if !$0 { bootErrorAlert = nil } }
            )) {
                Button("OK", role: .cancel) {
                    bootErrorAlert = nil
                }
            } message: {
                Text(bootErrorAlert ?? "")
            }
            .fileImporter(
                isPresented: $isImportingFile,
                allowedContentTypes: fileImportMode == .pairingPlist
                    ? [.propertyList, .xml, .data, .item]
                    : [.item, .data, .propertyList],
                allowsMultipleSelection: fileImportMode == .guestFiles
            ) { result in
                switch result {
                case .success(let urls):
                    do {
                        if fileImportMode == .pairingPlist {
                            bootWarning = try jitClient.importFiles(from: urls, forceAsPairingPlist: true)
                        } else {
                            bootWarning = try vmStore.importGuestFiles(from: urls, into: vmStore.selectedMachine)
                            jitClient.refreshFileStatus()
                        }
                    } catch {
                        bootErrorAlert = "Import failed: \(error.localizedDescription)"
                    }
                case .failure(let err):
                    bootErrorAlert = "Import failed: \(err.localizedDescription)"
                }
            }
        }
    }

    private var shortGpuBackendLabel: String {
        switch jitClient.gpuBackend {
        case .virgl3D: return "VirGL 3D"
        case .virtioGpu2D: return "2D KMS"
        case .gop2D: return "2D GOP"
        }
    }

    private var jitStatusTone: HengeStatusTone {
        switch jitClient.state {
        case .blessed: return .ready
        case .requestingExtension: return .active
        case .fallbackUntethered: return .warning
        case .idle: return .neutral
        }
    }

    private var pairingStatusTone: HengeStatusTone {
        if jitClient.isPairingFileValid {
            return .ready
        }
        return jitClient.hasPairingFile ? .warning : .neutral
    }

    private func startSelectedMachine() {
        Task {
            var activeVM = vmStore.selectedMachine
            activeVM.ramMiB = Int(effectiveRamMiB)
            activeVM.gpuBackend = Int(jitClient.gpuBackend.modeCode)
            vmStore.updateMachine(activeVM)

            let machineDir = vmStore.machineDirectoryURL(for: activeVM.id)
            let codeURL = vmStore.resolvedCodeFirmwareURL(for: activeVM)
            let varsURL = vmStore.resolvedVarsFirmwareURL(for: activeVM)
            let secondaryURL = vmStore.resolvedSecondaryMediaURL(for: activeVM)

            isPreparingDisk = true
            let minDiskBytes = UInt64(activeVM.targetDiskSizeGiB ?? 0) << 30
            let diskReady: Result<Void, Error> = await withCheckedContinuation { continuation in
                HengeVMBridge.shared.prepareDiskImage(
                    atMachineDir: machineDir.path,
                    primaryDiskName: activeVM.primaryDiskFileName,
                    codePath: codeURL.path,
                    varsPath: varsURL.path,
                    minDiskBytes: minDiskBytes
                ) { success, error in
                    if success {
                        continuation.resume(returning: .success(()))
                    } else {
                        let fallback = NSError(
                            domain: "HengeVM",
                            code: 1007,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to prepare guest disk image."]
                        )
                        continuation.resume(returning: .failure(error ?? fallback))
                    }
                }
            }
            isPreparingDisk = false
            if case .failure(let err) = diskReady {
                bootWarning = err.localizedDescription
                bootErrorAlert = err.localizedDescription
                isRunning = false
                return
            }

            await jitClient.prepareSession()
            if HengeVMBridge.shared.isEngineLinked,
               case .fallbackUntethered(let reason) = jitClient.state {
                bootWarning = reason
                bootErrorAlert = reason
                isRunning = false
                return
            }
            let gpuMode: Int32 = jitClient.gpuBackend.modeCode
            externalDisplay.dualScanoutEnabled = activeVM.dualScanoutEnabled ?? false
            HengeVMBridge.shared.setDualScanoutEnabled(activeVM.dualScanoutEnabled ?? false)
            HengeVMBridge.shared.setConfiguredVramCapMiB(UInt32(max(0, activeVM.vramCapMiB ?? 0)))
            HengeVMBridge.shared.setTargetRefreshHz(UInt32(max(30, activeVM.refreshRateHz ?? 60)))
            if gpuMode == 1 && henge_virtio_gpu_has_virglrenderer() {
                UserDefaults.standard.set(true, forKey: "hengeGpuInitInProgress")
                UserDefaults.standard.set(activeVM.id, forKey: "hengeGpuInitMachineID")
            }
            AudioSessionManager.shared.activate()
            externalDisplay.setVMRunning(true)
            do {
                try HengeVMBridge.shared.startGuest(
                    atMachineDir: machineDir.path,
                    primaryDiskName: activeVM.primaryDiskFileName,
                    secondaryDiskPath: secondaryURL?.path,
                    codePath: codeURL.path,
                    varsPath: varsURL.path,
                    ramMiB: effectiveRamMiB,
                    cpuCount: Int32(activeVM.cpuCount),
                    gpuBackend: gpuMode,
                    enableVirtioInput: activeVM.enableVirtioInput,
                    enableXhci: activeVM.enableXhci,
                    enableAcpiSpcr: activeVM.enableAcpiSpcr
                )
                let actualMiB = HengeVMBridge.shared.activeRamMiB
                if actualMiB > 0 && actualMiB < effectiveRamMiB {
                    bootWarning = "Jetsam guard clamped guest RAM from \(effectiveRamMiB) MiB to \(actualMiB) MiB (standard Mach ledger)."
                } else {
                    bootWarning = nil
                }
                bootErrorAlert = nil
                isRunning = true
                externalDisplay.syncActiveDisplayLayer()
            } catch {
                UserDefaults.standard.set(false, forKey: "hengeGpuInitInProgress")
                UserDefaults.standard.removeObject(forKey: "hengeGpuInitMachineID")
                externalDisplay.setVMRunning(false)
                AudioSessionManager.shared.deactivate()
                bootWarning = error.localizedDescription
                bootErrorAlert = error.localizedDescription
                isRunning = false
            }
        }
    }

    @ViewBuilder
    private var activeNoticeBannerSection: some View {
        if let banner = bootWarning, !banner.isEmpty {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: banner.hasPrefix("Imported ") || banner.hasPrefix("Ready:") || banner.hasPrefix("Downloaded") ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(banner.hasPrefix("Imported ") || banner.hasPrefix("Ready:") || banner.hasPrefix("Downloaded") ? .green : .blue)
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button {
                        bootWarning = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss Notice")
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var activeDownloadRow: some View {
        if downloader.isDownloading {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading \(downloader.activeTitle)")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Cancel", role: .destructive) {
                        downloader.cancelDownload()
                    }
                    .font(.caption)
                }
                if downloader.bytesExpected > 0 {
                    ProgressView(value: downloader.progressFraction)
                } else {
                    ProgressView()
                }
                Text(downloader.progressLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var machinesTabView: some View {
        let activeVM = vmStore.selectedMachine
        return NavigationStack {
            List {
                if let recName = gpuRecoveryVMName {
                    Section {
                        GpuRecoveryDiagnosticBanner(
                            vmName: recName,
                            onRetry3D: {
                                if let recID = gpuRecoveryVMID,
                                   var vm = vmStore.machines.first(where: { $0.id == recID }) {
                                    vm.gpuBackend = 1
                                    vmStore.updateMachine(vm)
                                    if vmStore.selectedMachine.id == recID {
                                        jitClient.gpuBackend = .virgl3D
                                    }
                                }
                                gpuRecoveryVMName = nil
                                gpuRecoveryVMID = nil
                            },
                            onViewLogs: {
                                showDebugConsole = true
                            },
                            onDismiss: {
                                gpuRecoveryVMName = nil
                                gpuRecoveryVMID = nil
                            }
                        )
                    }
                }

                activeNoticeBannerSection

                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Image("AppIconPreview")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.blue.opacity(0.45), lineWidth: 1)
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activeVM.name)
                                    .font(.title3.bold())
                                Text(activeVM.distroDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            InfoBadgePill(
                                text: jitStatusLabel,
                                systemImage: "bolt.fill",
                                statusTone: jitStatusTone
                            )
                        }

                        let uefiReady = vmStore.isUefiReady(for: activeVM)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                InfoBadgePill(text: "\(effectiveRamMiB) MiB RAM", systemImage: "memorychip")
                                InfoBadgePill(text: "\(activeVM.cpuCount) vCPU", systemImage: "cpu")
                                InfoBadgePill(text: shortGpuBackendLabel, systemImage: "display")
                                InfoBadgePill(
                                    text: uefiReady ? "UEFI Ready" : "Firmware Needed",
                                    systemImage: uefiReady ? "checkmark.shield" : "exclamationmark.triangle",
                                    statusTone: uefiReady ? .ready : .warning
                                )
                            }
                        }

                        Button {
                            startSelectedMachine()
                        } label: {
                            Label(
                                isPreparingDisk ? "Unpacking Disk Image..." : "Boot \(activeVM.name)",
                                systemImage: isPreparingDisk ? "hourglass" : "play.fill"
                            )
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isPreparingDisk || jitClient.state == .requestingExtension)
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Active Machine")
                }

                Section {
                    InfoMetricRow(
                        title: "JIT Status",
                        value: "\(jitStatusLabel) · \(SelfDebugJITClient.activeJitModeLabel)",
                        systemImage: "bolt.circle",
                        statusTone: jitStatusTone
                    )
                    InfoMetricRow(
                        title: "Pairing File",
                        value: jitClient.pairingStatusText,
                        systemImage: "key",
                        statusTone: pairingStatusTone
                    )
                    if let diag = jitClient.extensionDiagnostic, !diag.isEmpty {
                        Text(diag)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let stikURL = SelfDebugJITClient.stikDebugEnableURL {
                        Button {
                            UIApplication.shared.open(stikURL)
                        } label: {
                            HStack(spacing: 12) {
                                ActionIconBadge(systemName: "bolt.shield.fill", color: .indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Enable JIT via StikDebug")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Recommended before booting on iOS 18–26")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        fileImportMode = .pairingPlist
                        isImportingFile = true
                    } label: {
                        HStack(spacing: 12) {
                            ActionIconBadge(systemName: "key.fill", color: .orange)
                            Text("Import Pairing File (.plist / .mobiledevicepairing)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("JIT Acceleration")
                }

                Section {
                    ForEach(vmStore.machines) { vm in
                        let isSelected = (vm.id == activeVM.id)
                        Button {
                            vmStore.selectedMachineID = vm.id
                        } label: {
                            HStack(spacing: 12) {
                                ActionIconBadge(
                                    systemName: "terminal.fill",
                                    color: isSelected ? .blue : .gray
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vm.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("\(vm.distroDisplayName) · \(vm.ramMiB) MiB · \(vm.cpuCount) vCPU")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.35))
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                do {
                                    let cloned = try vmStore.cloneMachine(vm)
                                    jitClient.refreshFileStatus()
                                    bootWarning = "Duplicated '\(vm.name)' -> '\(cloned.name)' (APFS CoW)."
                                } catch {
                                    bootErrorAlert = "Duplicate failed: \(error.localizedDescription)"
                                }
                            } label: {
                                Label("Duplicate Machine (Clone)", systemImage: "doc.on.doc")
                            }
                            if vmStore.machines.count > 1 && vm.id != "ArchLinux" {
                                Button(role: .destructive) {
                                    do {
                                        try vmStore.deleteMachine(id: vm.id)
                                        jitClient.refreshFileStatus()
                                        bootWarning = "Deleted VM '\(vm.name)'."
                                    } catch {
                                        bootErrorAlert = "Delete VM failed: \(error.localizedDescription)"
                                    }
                                } label: {
                                    Label("Delete Machine", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if vmStore.machines.count > 1 && vm.id != "ArchLinux" {
                                Button(role: .destructive) {
                                    do {
                                        try vmStore.deleteMachine(id: vm.id)
                                        jitClient.refreshFileStatus()
                                        bootWarning = "Deleted VM '\(vm.name)'."
                                    } catch {
                                        bootErrorAlert = "Delete VM failed: \(error.localizedDescription)"
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    activeDownloadRow

                    Button {
                        showNewVMSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            ActionIconBadge(systemName: "plus", color: .green)
                            Text("New ARM64 Linux VM")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showDownloadGallery = true
                    } label: {
                        HStack(spacing: 12) {
                            ActionIconBadge(systemName: "arrow.down.circle.fill", color: .blue)
                            Text("Download Distros & Firmware")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Machines")
                } footer: {
                    Text("Tap a machine to select it. Press and hold to duplicate, or swipe left on custom machines to delete.")
                }
            }
            .navigationTitle("Machines")
        }
    }

    private var hardwareTabView: some View {
        let activeVM = vmStore.selectedMachine
        let matchedPreset = MachineProfile.presets.first {
            Int(effectiveRamMiB) == $0.ramMiB && activeVM.cpuCount == $0.cpuCount
        }
        let isCustomProfile = (matchedPreset == nil)
        return NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ActionIconBadge(
                            systemName: "slider.horizontal.3",
                            color: isCustomProfile ? .blue : .gray
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(effectiveRamMiB) MiB guest RAM · \(activeVM.cpuCount) vCPU · Configured manually below")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: isCustomProfile ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isCustomProfile ? Color.blue : Color.secondary.opacity(0.35))
                    }
                    .padding(.vertical, 2)

                    ForEach(MachineProfile.presets) { preset in
                        let isSelected = (matchedPreset == preset)
                        Button {
                            selectedProfile = preset
                            customGuestRamMiB = preset.ramMiB
                            ramInputText = "\(preset.ramMiB)"
                            var copy = vmStore.selectedMachine
                            copy.ramMiB = preset.ramMiB
                            copy.cpuCount = preset.cpuCount
                            vmStore.updateMachine(copy)
                        } label: {
                            HStack(spacing: 12) {
                                ActionIconBadge(
                                    systemName: preset.id == "ipad-pro" ? "ipad" : "iphone",
                                    color: isSelected ? .blue : .gray
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(preset.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.35))
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Stepper(
                        value: Binding(
                            get: { vmStore.selectedMachine.cpuCount },
                            set: { newVal in
                                var copy = vmStore.selectedMachine
                                copy.cpuCount = newVal
                                vmStore.updateMachine(copy)
                            }
                        ),
                        in: 1...8
                    ) {
                        HStack {
                            Text("Virtual CPUs")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(activeVM.cpuCount) vCPU")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Guest RAM (MiB)")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            TextField("MiB", text: $ramInputText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 92)
                                .onChange(of: ramInputText) { _, newValue in
                                    let digits = newValue.filter(\.isNumber)
                                    if let parsed = Int(digits), parsed > 0 {
                                        let clamped = min(
                                            max(parsed, Int(HENGE_MIN_GUEST_RAM_MIB)),
                                            Int(HENGE_MAX_GUEST_RAM_MIB)
                                        )
                                        if customGuestRamMiB != clamped {
                                            customGuestRamMiB = clamped
                                        }
                                    }
                                }
                                .onSubmit {
                                    ramInputText = "\(effectiveRamMiB)"
                                }
                            Stepper(
                                "",
                                value: Binding(
                                    get: { Int(effectiveRamMiB) },
                                    set: { newVal in
                                        let clamped = min(
                                            max(newVal, Int(HENGE_MIN_GUEST_RAM_MIB)),
                                            Int(HENGE_MAX_GUEST_RAM_MIB)
                                        )
                                        customGuestRamMiB = clamped
                                        ramInputText = "\(clamped)"
                                    }
                                ),
                                in: Int(HENGE_MIN_GUEST_RAM_MIB)...Int(HENGE_MAX_GUEST_RAM_MIB),
                                step: 128
                            )
                            .labelsHidden()
                        }

                        Slider(
                            value: Binding(
                                get: { Double(min(Int(effectiveRamMiB), sliderMaxRamMiB)) },
                                set: { newVal in
                                    let stepped = Int((newVal / 128.0).rounded()) * 128
                                    let clamped = min(
                                        max(stepped, Int(HENGE_MIN_GUEST_RAM_MIB)),
                                        sliderMaxRamMiB
                                    )
                                    customGuestRamMiB = clamped
                                    ramInputText = "\(clamped)"
                                }
                            ),
                            in: Double(HENGE_MIN_GUEST_RAM_MIB)...Double(sliderMaxRamMiB),
                            step: 128
                        )

                        HStack(spacing: 6) {
                            ForEach([
                                (mib: 1024, label: "1G"),
                                (mib: 1536, label: "1.5G"),
                                (mib: 2048, label: "2G"),
                                (mib: 3072, label: "3G"),
                                (mib: 4096, label: "4G")
                            ], id: \.mib) { preset in
                                Button {
                                    customGuestRamMiB = preset.mib
                                    ramInputText = "\(preset.mib)"
                                } label: {
                                    Text(preset.label)
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .tint(Int(effectiveRamMiB) == preset.mib ? .blue : .secondary)
                            }
                            Spacer(minLength: 4)
                            Text("\(String(format: "%.2f", Double(effectiveRamMiB) / 1024.0)) GiB")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }

                        Text(ramAdvisoryText)
                            .font(.caption2)
                            .foregroundStyle(effectiveRamMiB > safeRecommendedRamMiB ? .orange : .secondary)

                        Divider()

                        JetsamMemoryBreakdownBar(
                            guestRamMiB: Int(effectiveRamMiB),
                            jitPoolMiB: SelfDebugJITClient.recommendedJitPoolMiB,
                            gpuBackendMode: Int(jitClient.gpuBackend.modeCode),
                            refreshToken: memoryRefreshTick
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Memory & CPU")
                }

                GraphicsDisplayConfigSections(
                    vmName: activeVM.name,
                    distroTag: activeVM.distroTag,
                    gpuBackend: $jitClient.gpuBackend,
                    vramCapMiB: Binding(
                        get: { vmStore.selectedMachine.vramCapMiB ?? 0 },
                        set: { newVal in
                            var copy = vmStore.selectedMachine
                            copy.vramCapMiB = (newVal > 0) ? newVal : nil
                            vmStore.updateMachine(copy)
                            HengeVMBridge.shared.setConfiguredVramCapMiB(UInt32(max(0, newVal)))
                        }
                    ),
                    refreshRateHz: Binding(
                        get: { vmStore.selectedMachine.refreshRateHz ?? 60 },
                        set: { newVal in
                            var copy = vmStore.selectedMachine
                            copy.refreshRateHz = newVal
                            vmStore.updateMachine(copy)
                            HengeVMBridge.shared.setTargetRefreshHz(UInt32(max(30, newVal)))
                        }
                    ),
                    dualScanoutEnabled: Binding(
                        get: { vmStore.selectedMachine.dualScanoutEnabled ?? false },
                        set: { newVal in
                            var copy = vmStore.selectedMachine
                            copy.dualScanoutEnabled = newVal
                            vmStore.updateMachine(copy)
                            externalDisplay.dualScanoutEnabled = newVal
                            HengeVMBridge.shared.setDualScanoutEnabled(newVal)
                        }
                    ),
                    externalDisplay: externalDisplay,
                    oledAutoDimSeconds: $oledAutoDimSeconds
                )

                Section("Virtual Devices & Engine") {
                    Toggle(
                        "VirtIO Input (Keyboard + Tablet)",
                        isOn: Binding(
                            get: { activeVM.enableVirtioInput },
                            set: { newVal in
                                var copy = activeVM
                                copy.enableVirtioInput = newVal
                                vmStore.updateMachine(copy)
                            }
                        )
                    )
                    Toggle(
                        "USB 3.0 xHCI Controller",
                        isOn: Binding(
                            get: { activeVM.enableXhci },
                            set: { newVal in
                                var copy = activeVM
                                copy.enableXhci = newVal
                                vmStore.updateMachine(copy)
                            }
                        )
                    )
                    Toggle(
                        "ACPI SPCR Serial Console",
                        isOn: Binding(
                            get: { activeVM.enableAcpiSpcr },
                            set: { newVal in
                                var copy = activeVM
                                copy.enableAcpiSpcr = newVal
                                vmStore.updateMachine(copy)
                            }
                        )
                    )
                    Toggle("Auto-Sync Host Clipboard on Focus", isOn: $autoSyncClipboard)
                    Picker("JIT Strategy", selection: $jitClient.jitStrategy) {
                        ForEach(JitStrategyOverride.allCases) { strategy in
                            Text(strategy.label).tag(strategy)
                        }
                    }
                }
            }
            .navigationTitle("Hardware")
        }
    }

    private var storageTabView: some View {
        let activeVM = vmStore.selectedMachine
        let activeDir = vmStore.machineDirectoryURL(for: activeVM.id)
        let virtualBytes = vmStore.primaryDiskVirtualSizeBytes(for: activeVM)
        let virtualSizeLabel = virtualBytes > 0
            ? String(format: "%.2f GiB", Double(virtualBytes) / Double(1 << 30))
            : "Unpacks on first boot"
        let hasSnapshot = HengeVMBridge.shared.hasSavedBackgroundSnapshot(atMachineDir: activeDir.path)

        return NavigationStack {
            List {
                activeNoticeBannerSection

                Section {
                    let diskReady = vmStore.isPrimaryDiskReady(for: activeVM)
                    let uefiReady = vmStore.isUefiReady(for: activeVM)
                    InfoMetricRow(
                        title: "Machine",
                        value: activeVM.name,
                        systemImage: "desktopcomputer"
                    )
                    InfoMetricRow(
                        title: "Primary Disk",
                        value: vmStore.diskStatusText(for: activeVM),
                        systemImage: "internaldrive",
                        statusTone: diskReady ? .ready : .warning
                    )
                    InfoMetricRow(
                        title: "Virtual Capacity",
                        value: virtualSizeLabel,
                        systemImage: "chart.pie",
                        monospaced: true
                    )
                    InfoMetricRow(
                        title: "UEFI Firmware",
                        value: vmStore.uefiStatusText(for: activeVM),
                        systemImage: "cpu",
                        statusTone: uefiReady ? .ready : .warning
                    )
                    InfoMetricRow(
                        title: "Background Snapshot",
                        value: hasSnapshot ? "Saved (suspend.state)" : "None",
                        systemImage: "clock.arrow.circlepath",
                        statusTone: hasSnapshot ? .ready : .neutral
                    )
                    if let media = activeVM.secondaryMediaFileName, !media.isEmpty {
                        HStack(spacing: 10) {
                            InfoMetricRow(
                                title: "Secondary Media",
                                value: media,
                                systemImage: "opticaldisc"
                            )
                            Button("Eject", role: .destructive) {
                                vmStore.clearSecondaryMedia(for: activeVM)
                                jitClient.refreshFileStatus()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                } header: {
                    Text("Storage Summary")
                } footer: {
                    Text("Manage raw files directly in the iOS Files app under On My iPhone › HengeLinux.")
                }

                Section("Disk & Image Actions") {
                    Button {
                        fileImportMode = .guestFiles
                        isImportingFile = true
                    } label: {
                        HStack(spacing: 12) {
                            ActionIconBadge(systemName: "folder.badge.plus", color: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import Disk, ISO, or Firmware")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(".qcow2, .hvsparse, .img, .iso, or .fd into \(activeVM.name)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        let currentGiB = Int(vmStore.primaryDiskVirtualSizeBytes(for: activeVM) >> 30)
                        expandDiskGiB = max(16, max(currentGiB + 8, activeVM.targetDiskSizeGiB ?? 16))
                        if expandDiskGiB > 128 { expandDiskGiB = 128 }
                        showExpandDiskSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            ActionIconBadge(systemName: "arrow.up.left.and.arrow.down.right", color: .indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Expand Virtual Disk")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("APFS sparse resize up to 128 GiB")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        do {
                            let reclaimed = try vmStore.compactPrimaryDisk(for: activeVM)
                            jitClient.refreshFileStatus()
                            let mib = Double(reclaimed) / (1024.0 * 1024.0)
                            bootWarning = String(format: "Compacted disk for %@ (%.1f MiB zero blocks punched).", activeVM.name, mib)
                        } catch {
                            bootErrorAlert = "Compact failed: \(error.localizedDescription)"
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ActionIconBadge(systemName: "arrow.down.right.and.arrow.up.left", color: .teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Compact Sparse Disk")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("Reclaim zero blocks via APFS F_PUNCHHOLE")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showCidataSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            ActionIconBadge(systemName: "externaldrive.badge.plus", color: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Generate Cloud-Init CIDATA Seed")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("Offline FAT16 seed volume for cloud images")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Images & Disks")
        }
    }

    private var distroDownloadGallerySheet: some View {
        NavigationStack {
            List {
                if downloader.isDownloading {
                    Section("Active Download") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(downloader.activeTitle)
                                .font(.headline)
                            if downloader.bytesExpected > 0 {
                                ProgressView(value: downloader.progressFraction)
                            } else {
                                ProgressView()
                            }
                            HStack {
                                Text(downloader.progressLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Cancel", role: .destructive) {
                                    downloader.cancelDownload()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let dlErr = downloader.lastError, !dlErr.isEmpty {
                    Section("Download Error") {
                        Text(dlErr)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Shared UEFI Firmware (Required Once)") {
                    InfoMetricRow(
                        title: "EDK2 Firmware",
                        value: vmStore.hasSharedFirmware ? "Installed (Ready · Shared)" : "Not Installed",
                        systemImage: "cpu",
                        statusTone: vmStore.hasSharedFirmware ? .ready : .warning
                    )
                    Button {
                        Task {
                            do {
                                try await downloader.downloadSharedFirmware(into: vmStore)
                                jitClient.refreshFileStatus()
                                bootWarning = "Downloaded shared UEFI firmware (code.fd + vars.fd) into Documents/Firmware/."
                            } catch is CancellationError {
                                bootWarning = "Firmware download canceled."
                            } catch {
                                bootErrorAlert = "Firmware download failed: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Label(
                            vmStore.hasSharedFirmware ? "Re-Download UEFI Firmware (~128 MiB)" : "Download UEFI Firmware (~128 MiB)",
                            systemImage: "cpu.fill"
                        )
                    }
                    .disabled(downloader.isDownloading)
                }

                Section("Auto-Provisioning Defaults (Cloud Distros)") {
                    TextField("Username", text: $cidataUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Password", text: $cidataPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper("Target Virtual Disk: \(galleryDiskGiB) GiB", value: $galleryDiskGiB, in: 8...64, step: 4)
                    Text("Cloud images automatically configure /bin/bash (or /bin/sh on Alpine), NoCloud metadata lock, root disk auto-grow, and VirtIO-GPU KMS where supported.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("Supported Public ARM64 Distros") {
                    ForEach(DistroCatalogItem.supportedDistros) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.name)
                                    .font(.headline)
                                Spacer()
                                Text(item.approxSizeLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                Task {
                                    do {
                                        let created = try await downloader.downloadAndProvision(
                                            item: item,
                                            into: vmStore,
                                            ramMiB: Int(effectiveRamMiB),
                                            cpuCount: vmStore.selectedMachine.cpuCount,
                                            diskGiB: galleryDiskGiB,
                                            username: cidataUsername,
                                            password: cidataPassword
                                        )
                                        jitClient.refreshFileStatus()
                                        if item.needsCidata {
                                            let u = cidataUsername.isEmpty ? "linux" : cidataUsername
                                            let p = cidataPassword.isEmpty ? "linux" : cidataPassword
                                            bootWarning = "Ready: \(created.name) downloaded (login: \(u) / \(p)). Tap Boot!"
                                        } else {
                                            bootWarning = "Ready: \(created.name) downloaded. Tap Boot!"
                                        }
                                        showDownloadGallery = false
                                    } catch is CancellationError {
                                        bootWarning = "Canceled downloading \(item.name)."
                                    } catch {
                                        bootErrorAlert = "Download failed: \(error.localizedDescription)"
                                    }
                                }
                            } label: {
                                Label("Download & Create VM", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(downloader.isDownloading)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Custom Image URL (.qcow2 / .hvsparse / .img / .iso)") {
                    TextField("https://example.org/image-arm64.qcow2", text: $customDownloadURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("VM Name (optional)", text: $customDownloadVMName)
                    Picker("Distro Profile", selection: $customDownloadDistroTag) {
                        ForEach(VMConfig.distroOptions, id: \.tag) { opt in
                            Text(opt.label).tag(opt.tag)
                        }
                    }
                    Toggle("Attach CIDATA Cloud-Init Seed", isOn: $customDownloadCidata)
                    Button {
                        let trimmed = customDownloadURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: trimmed) else {
                            bootErrorAlert = "Please enter a valid http:// or https:// image URL."
                            return
                        }
                        Task {
                            do {
                                let created = try await downloader.downloadCustomURL(
                                    url,
                                    vmName: customDownloadVMName,
                                    distroTag: customDownloadDistroTag,
                                    into: vmStore,
                                    ramMiB: Int(effectiveRamMiB),
                                    cpuCount: vmStore.selectedMachine.cpuCount,
                                    diskGiB: galleryDiskGiB,
                                    generateCidata: customDownloadCidata,
                                    username: cidataUsername,
                                    password: cidataPassword
                                )
                                jitClient.refreshFileStatus()
                                bootWarning = "Downloaded custom image into '\(created.name)'. Tap Boot!"
                                customDownloadURLText = ""
                                customDownloadVMName = ""
                                showDownloadGallery = false
                            } catch is CancellationError {
                                bootWarning = "Custom image download canceled."
                            } catch {
                                bootErrorAlert = "Custom download failed: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Label("Download Custom Image", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(downloader.isDownloading || customDownloadURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Distro & Firmware Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showDownloadGallery = false
                    }
                }
            }
        }
    }

    private var appVersionString: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private var appBuildNumberString: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    private var buildCommitHash: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "HengeGitCommit") as? String) ?? ""
        return raw.isEmpty ? "local" : raw
    }

    private var buildChannelLabel: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "HengeBuildChannel") as? String) ?? ""
        return raw.isEmpty ? "Local" : raw
    }

    private var buildDateLabel: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "HengeBuildDate") as? String) ?? ""
        return raw.isEmpty ? "Local" : raw
    }

    private var buildSummaryLine: String {
        "HengeLinux v\(appVersionString) (build \(appBuildNumberString)) · \(buildChannelLabel) · \(buildCommitHash) · \(buildDateLabel)"
    }

    private var informationTabView: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image("AppIconPreview")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.blue.opacity(0.45), lineWidth: 1)
                            )
                            .shadow(color: Color.blue.opacity(0.25), radius: 8, y: 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HengeLinux")
                                .font(.title2.bold())
                            Text("v\(appVersionString) (\(appBuildNumberString)) · \(buildChannelLabel)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Full-System ARM64 Linux VM for iOS")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Diagnostics & Actions") {
                    Button {
                        showDebugConsole = true
                    } label: {
                        HStack(spacing: 12) {
                            ActionIconBadge(systemName: "terminal.fill", color: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("View Boot & Serial Logs")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Live engine, VirGL, ttyAMA0, and saved boot tail")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        UIPasteboard.general.string = buildSummaryLine
                        copiedBuildInfo = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            copiedBuildInfo = false
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ActionIconBadge(
                                systemName: copiedBuildInfo ? "checkmark" : "doc.on.doc.fill",
                                color: copiedBuildInfo ? .green : .indigo
                            )
                            Text(copiedBuildInfo ? "Copied Build Info" : "Copy Version & Commit Hash")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Section("Installed Build") {
                    InfoMetricRow(title: "Version", value: "v\(appVersionString) (\(appBuildNumberString))", systemImage: "tag")
                    InfoMetricRow(title: "Channel", value: buildChannelLabel, systemImage: "shippingbox")
                    InfoMetricRow(title: "Commit", value: buildCommitHash, systemImage: "number", monospaced: true)
                    InfoMetricRow(title: "Built", value: buildDateLabel, systemImage: "calendar")
                }

                Section("Runtime & Capabilities") {
                    InfoMetricRow(
                        title: "Bundle ID",
                        value: Bundle.main.bundleIdentifier ?? "io.hengelinux.app",
                        systemImage: "app.badge",
                        monospaced: true
                    )
                    InfoMetricRow(title: "iOS Version", value: UIDevice.current.systemVersion, systemImage: "iphone")
                    InfoMetricRow(
                        title: "VM Engine",
                        value: HengeVMBridge.shared.isEngineLinked ? "HengeVM Linked" : "Host Substrate Only",
                        systemImage: "gearshape.2",
                        statusTone: HengeVMBridge.shared.isEngineLinked ? .ready : .warning
                    )
                    InfoMetricRow(title: "JIT Mode", value: SelfDebugJITClient.activeJitModeLabel, systemImage: "bolt")
                    InfoMetricRow(title: "JIT Pool", value: "\(SelfDebugJITClient.recommendedJitPoolMiB) MiB", systemImage: "memorychip", monospaced: true)
                    InfoMetricRow(title: "Aligned Guest RAM", value: "\(alignedBytes) B", systemImage: "rectangle.grid.2x2", monospaced: true)
                    InfoMetricRow(title: "Host Bridge", value: "http://10.0.2.4/.henge/", systemImage: "network", monospaced: true)
                    InfoMetricRow(
                        title: "QCOW2 Zstd",
                        value: henge_qcow2_has_zstd() ? "Enabled (libzstd)" : "zlib Only",
                        systemImage: "archivebox",
                        statusTone: henge_qcow2_has_zstd() ? .ready : .neutral
                    )
                    InfoMetricRow(title: "LiveContainer", value: SelfDebugJITClient.isRunningInLiveContainer ? "Detected (Use StikDebug)" : "No", systemImage: "cube")
                }

                Section("Project & License") {
                    InfoMetricRow(title: "License", value: "GPL-3.0-or-later", systemImage: "doc.plaintext")
                    if let repoURL = URL(string: "https://github.com/venim1103/henge-linux") {
                        Link(destination: repoURL) {
                            HStack(spacing: 12) {
                                ActionIconBadge(systemName: "safari.fill", color: .blue)
                                Text("GitHub Repository")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let releasesURL = URL(string: "https://github.com/venim1103/henge-linux/releases") {
                        Link(destination: releasesURL) {
                            HStack(spacing: 12) {
                                ActionIconBadge(systemName: "arrow.down.circle.fill", color: .teal)
                                Text("Releases & Nightly Builds")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Information")
        }
    }

    private var jitStatusLabel: String {
        switch jitClient.state {
        case .idle:
            return "Standby"
        case .requestingExtension:
            return "Blessing Pages..."
        case .blessed(let poolMiB, _):
            return "Blessed (\(poolMiB) MiB)"
        case .fallbackUntethered:
            return "Untethered"
        }
    }

    private var safeRecommendedRamMiB: UInt32 {
        _ = memoryRefreshTick
        return henge_recommended_guest_ram_mib_for_gpu(
            henge_recommended_jit_pool_bytes(),
            jitClient.gpuBackend.modeCode
        )
    }

    private var ramAdvisoryText: String {
        _ = memoryRefreshTick
        let availBytes = henge_available_memory_bytes()
        let rec = safeRecommendedRamMiB
        if availBytes > 0 {
            let availMiB = availBytes / (1024 * 1024)
            if effectiveRamMiB > rec {
                return "Above recommended \(rec) MiB (live Jetsam budget: \(availMiB) MiB) may trigger iOS memory termination."
            }
            return "16 KiB page-aligned · Live Jetsam headroom: \(availMiB) MiB (safe target ≤ \(rec) MiB)."
        }
        return effectiveRamMiB > 1792
            ? "Above ~1,792 MiB without LEDGER_NO_FOOTPRINT may hit iOS's ~3 GiB standard-ledger Jetsam kill limit."
            : "16 KiB page-aligned (512–10,240 MiB). Default 1,536 MiB leaves safe standard-ledger headroom."
    }

    private var sliderMaxRamMiB: Int {
        _ = memoryRefreshTick
        let availMiB = Int(henge_available_memory_bytes() / (1024 * 1024))
        let physicalMiB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let baseUpper = availMiB > 0 ? max(availMiB, 3072) : max(physicalMiB, 4096)
        let upper = max(baseUpper, Int(effectiveRamMiB))
        return min(upper, Int(HENGE_MAX_GUEST_RAM_MIB))
    }

    private var clampedCustomRamMiB: UInt32 {
        let clamped = min(
            max(customGuestRamMiB, Int(HENGE_MIN_GUEST_RAM_MIB)),
            Int(HENGE_MAX_GUEST_RAM_MIB)
        )
        return UInt32(clamped)
    }

    private var alignedBytes: UInt64 {
        henge_align_guest_ram_bytes(clampedCustomRamMiB, HENGE_MAX_GUEST_RAM_MIB)
    }

    private var effectiveRamMiB: UInt32 {
        UInt32(alignedBytes / (1024 * 1024))
    }
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariSheetView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// Live PL011 (`ttyAMA0`) serial & `HengeVM` engine diagnostic console sheet.
struct DebugConsoleSheetView: View {
    private enum LogFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case engine = "Engine"
        case serial = "Guest Serial"
        case saved = "Saved Log"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var telemetryText: String = ""
    @State private var logText: String = ""
    @State private var lastObservedBytes: UInt64 = UInt64.max
    @State private var filter: LogFilter = .all
    @State private var showRawEscapeCodes: Bool = false
    @State private var autoScroll: Bool = true
    @State private var copiedBanner: Bool = false

    private let refreshTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(telemetryText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Picker("Log Source", selection: $filter) {
                        ForEach(LogFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: filter) { _, _ in
                        refreshLogs(force: true)
                    }

                    HStack(spacing: 12) {
                        Toggle("Auto-Scroll", isOn: $autoScroll)
                            .font(.caption)
                            .toggleStyle(.switch)
                            .controlSize(.mini)

                        Toggle("Raw ANSI", isOn: $showRawEscapeCodes)
                            .font(.caption)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .onChange(of: showRawEscapeCodes) { _, _ in
                                refreshLogs(force: true)
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.12))

                Divider()

                MonospaceLogTextView(
                    text: logText,
                    placeholder: "Waiting for UEFI / PL011 serial (ttyAMA0) or HengeVM engine output...",
                    fontSize: 11,
                    autoScroll: autoScroll
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .onAppear {
                    refreshLogs(force: true)
                }
            }
            .navigationTitle("Serial & Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        let combined = "=== Telemetry ===\n\(telemetryText)\n\n=== Serial / Engine Log ===\n\(logText)"
                        UIPasteboard.general.string = combined
                        copiedBanner = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedBanner = false
                        }
                    } label: {
                        Label(copiedBanner ? "Copied" : "Copy All", systemImage: copiedBanner ? "checkmark" : "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        HengeVMBridge.shared.clearConsoleLog()
                        refreshLogs(force: true)
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onReceive(refreshTimer) { _ in
                refreshLogs(force: false)
            }
        }
    }

    private func refreshLogs(force: Bool) {
        let bridge = HengeVMBridge.shared
        telemetryText = bridge.diagnosticSnapshot()
        let currentBytes = bridge.consoleTotalBytes
        guard force || currentBytes != lastObservedBytes else {
            return
        }
        lastObservedBytes = currentBytes
        let raw = (filter == .saved) ? bridge.copySavedBootLogTail() : bridge.copyConsoleLog()
        let cleaned = showRawEscapeCodes ? raw : Self.sanitizeTerminalOutput(raw)
        switch filter {
        case .all, .saved:
            logText = cleaned
        case .engine:
            logText = cleaned
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    line.hasPrefix("[bridge]") ||
                    line.hasPrefix("winvm:") ||
                    line.hasPrefix("hengevm:") ||
                    line.hasPrefix("virgl-worker:") ||
                    line.contains("vrend") ||
                    line.contains("ANGLE")
                }
                .joined(separator: "\n")
        case .serial:
            logText = cleaned
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    !(line.hasPrefix("[bridge]") ||
                      line.hasPrefix("winvm:") ||
                      line.hasPrefix("hengevm:") ||
                      line.hasPrefix("virgl-worker:"))
                }
                .joined(separator: "\n")
        }
    }

    private static let csiEscapeRegex = try? NSRegularExpression(
        pattern: "\\x1B\\[[0-9;?:<>=!]*[ -/]*[@-~]",
        options: []
    )
    private static let oscEscapeRegex = try? NSRegularExpression(
        pattern: "\\x1B\\](?:9999;[^\\x07\\x1B]*|[^\\x07\\x1B]*)(?:\\x07|\\x1B\\\\)",
        options: []
    )

    static func sanitizeTerminalOutput(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "\r\n", with: "\n")
        if let csiRegex = csiEscapeRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = csiRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        if let oscRegex = oscEscapeRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = oscRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        // Collapse standalone carriage-return progress overwrites (e.g. apt/curl progress bars).
        let collapsedLines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            if let lastCR = line.lastIndex(of: "\r") {
                return line[line.index(after: lastCR)...]
            }
            return line
        }
        return collapsedLines.joined(separator: "\n")
    }
}
