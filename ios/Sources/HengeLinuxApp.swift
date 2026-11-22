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
            id: "iphone-8gb",
            name: "iPhone Pro (8 GB RAM)",
            subtitle: "iPhone 16 Pro · 2.5 GiB guest RAM · 4 vCPU · Safe Jetsam headroom",
            ramMiB: 2560,
            cpuCount: 4
        ),
        MachineProfile(
            id: "iphone-duo",
            name: "iPhone Duo / 12 GB Pro",
            subtitle: "4.5 GiB guest RAM · 4 vCPU · Full desktop & multi-process workloads",
            ramMiB: 4608,
            cpuCount: 4
        ),
        MachineProfile(
            id: "ipad-pro",
            name: "M-Series iPad Pro (16 GB)",
            subtitle: "6.0 GiB guest RAM · 6 vCPU · External USB-C display mode",
            ramMiB: 6144,
            cpuCount: 6
        )
    ]
}

@main
struct HengeLinuxApp: App {
    private enum FileImportMode {
        case pairingPlist
        case guestFiles
    }

    private enum StartTab: Hashable {
        case machines
        case about
    }

    @StateObject private var lifecycle = MetalLifecycleGuard()
    @StateObject private var jitClient = SelfDebugJITClient()
    @StateObject private var vmStore = VMStore()
    @StateObject private var downloader = DistroDownloadManager()
    @State private var selectedStartTab: StartTab = .machines
    @State private var copiedBuildInfo: Bool = false
    @State private var selectedProfile: MachineProfile = MachineProfile.presets[0]
    @AppStorage("customGuestRamMiB") private var customGuestRamMiB: Int = 1664
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
                        posture: $posture,
                        bootWarning: bootWarning,
                        onStopSession: {
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
                        launcherView
                            .tabItem {
                                Label("Machines", systemImage: "desktopcomputer")
                            }
                            .tag(StartTab.machines)

                        aboutView
                            .tabItem {
                                Label("About", systemImage: "info.circle")
                            }
                            .tag(StartTab.about)
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
                            LabeledContent("vCPUs", value: "\(selectedProfile.cpuCount)")
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
                                        cpuCount: selectedProfile.cpuCount,
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
                let vm = vmStore.selectedMachine
                if vm.ramMiB >= Int(HENGE_MIN_GUEST_RAM_MIB) && vm.ramMiB <= Int(HENGE_MAX_GUEST_RAM_MIB) {
                    customGuestRamMiB = vm.ramMiB
                }
                jitClient.gpuBackend = GpuDisplayBackend.from(modeCode: vm.gpuBackend)
                if ramInputText.isEmpty {
                    ramInputText = "\(effectiveRamMiB)"
                }
            }
            .onChange(of: vmStore.selectedMachineID) { _, _ in
                let vm = vmStore.selectedMachine
                customGuestRamMiB = min(max(vm.ramMiB, Int(HENGE_MIN_GUEST_RAM_MIB)), Int(HENGE_MAX_GUEST_RAM_MIB))
                jitClient.gpuBackend = GpuDisplayBackend.from(modeCode: vm.gpuBackend)
                ramInputText = "\(effectiveRamMiB)"
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

    private var launcherView: some View {
        NavigationStack {
            List {
                Section("Virtual Machines (`Documents/Machines/`)") {
                    ForEach(vmStore.machines) { vm in
                        Button {
                            vmStore.selectedMachineID = vm.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(vm.name)
                                        .font(.headline)
                                    Text("\(vm.distroDisplayName) · \(vm.ramMiB) MiB · \(vm.cpuCount) vCPU · \(vm.primaryDiskFileName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if vm.id == vmStore.selectedMachine.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
                    Button {
                        showDownloadGallery = true
                    } label: {
                        Label("Download Distros & Firmware...", systemImage: "arrow.down.circle.fill")
                    }
                    if downloader.isDownloading {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Downloading \(downloader.activeTitle)")
                                    .font(.caption.weight(.medium))
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
                        .padding(.vertical, 2)
                    }
                    Button {
                        showNewVMSheet = true
                    } label: {
                        Label("New ARM64 Linux VM...", systemImage: "plus.rectangle.on.folder")
                    }
                }

                Section("Hardware Profile") {
                    ForEach(MachineProfile.presets) { preset in
                        Button {
                            selectedProfile = preset
                            customGuestRamMiB = preset.ramMiB
                            ramInputText = "\(preset.ramMiB)"
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name)
                                        .font(.headline)
                                    Text(preset.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if preset == selectedProfile && Int(effectiveRamMiB) == preset.ramMiB {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
                            ForEach([1024, 1664, 2048, 2560, 4096], id: \.self) { mib in
                                Button("\(mib)") {
                                    customGuestRamMiB = mib
                                    ramInputText = "\(mib)"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .tint(Int(effectiveRamMiB) == mib ? .blue : .secondary)
                            }
                            Spacer()
                            Text("\(String(format: "%.2f", Double(effectiveRamMiB) / 1024.0)) GiB")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Text(ramAdvisoryText)
                            .font(.caption2)
                            .foregroundStyle(effectiveRamMiB > safeRecommendedRamMiB ? .orange : .secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Graphics & JIT Engine") {
                    Picker("Display Adapter", selection: $jitClient.gpuBackend) {
                        ForEach(GpuDisplayBackend.allCases) { backend in
                            Text(backend.rawValue).tag(backend)
                        }
                    }
                    if vmStore.selectedMachine.distroTag == "ubuntu" && jitClient.gpuBackend != .gop2D {
                        Text("Ubuntu Cloud omits virtio-gpu.ko by default. Run Guest Tools install.sh (or install linux-modules-extra) inside Ubuntu before using VirtIO-GPU KMS.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Picker("JIT Strategy", selection: $jitClient.jitStrategy) {
                        ForEach(JitStrategyOverride.allCases) { strategy in
                            Text(strategy.label).tag(strategy)
                        }
                    }
                    Toggle("Auto-Sync Host Clipboard on Focus", isOn: $autoSyncClipboard)
                    LabeledContent("JIT Mode", value: SelfDebugJITClient.activeJitModeLabel)
                    LabeledContent("JIT Pool", value: "\(SelfDebugJITClient.recommendedJitPoolMiB) MiB")
                    if SelfDebugJITClient.isRunningInLiveContainer {
                        LabeledContent("Container", value: "LiveContainer (Use StikDebug)")
                    }
                    LabeledContent("Pairing File", value: jitClient.pairingStatusText)
                    LabeledContent("JIT Status", value: jitStatusLabel)
                    if let diag = jitClient.extensionDiagnostic, !diag.isEmpty {
                        Text(diag)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let stikURL = SelfDebugJITClient.stikDebugEnableURL {
                        Button {
                            UIApplication.shared.open(stikURL)
                        } label: {
                            Label("Enable JIT via StikDebug", systemImage: "bolt.shield.fill")
                        }
                    }
                    Button {
                        fileImportMode = .pairingPlist
                        isImportingFile = true
                    } label: {
                        Label("Import pairing.plist / .mobiledevicepairing...", systemImage: "key.fill")
                    }
                }

                Section("Guest Image & Devices (\(vmStore.selectedMachine.name))") {
                    let activeVM = vmStore.selectedMachine
                    let activeDir = vmStore.machineDirectoryURL(for: activeVM.id)
                    LabeledContent("Disk Container", value: vmStore.diskStatusText(for: activeVM))
                    LabeledContent("UEFI Firmware", value: vmStore.uefiStatusText(for: activeVM))
                    if let media = activeVM.secondaryMediaFileName, !media.isEmpty {
                        HStack {
                            LabeledContent("Secondary Media", value: media)
                            Button("Eject", role: .destructive) {
                                vmStore.clearSecondaryMedia(for: activeVM)
                                jitClient.refreshFileStatus()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
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
                    LabeledContent("Background Snapshot", value: HengeVMBridge.shared.hasSavedBackgroundSnapshot(atMachineDir: activeDir.path) ? "suspend.state (Disk Flushed + Metadata)" : "None")
                    LabeledContent("Aligned Guest Bytes", value: "\(alignedBytes) B")
                    LabeledContent("Host Bridge", value: "http://10.0.2.4/.henge/")
                    LabeledContent("VM Engine", value: HengeVMBridge.shared.isEngineLinked ? "Linked (HengeVM)" : "Host Substrate Only")
                    Button {
                        fileImportMode = .guestFiles
                        isImportingFile = true
                    } label: {
                        Label("Import Disk / QCOW2 / ISO / Firmware...", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showCidataSheet = true
                    } label: {
                        Label("Generate Cloud-Init CIDATA Seed...", systemImage: "externaldrive.badge.plus")
                    }
                    Button {
                        do {
                            let cloned = try vmStore.cloneMachine(activeVM)
                            jitClient.refreshFileStatus()
                            bootWarning = "Cloned VM '\(activeVM.name)' -> '\(cloned.name)' (APFS CoW)."
                        } catch {
                            bootErrorAlert = "Clone failed: \(error.localizedDescription)"
                        }
                    } label: {
                        Label("Clone VM (APFS Copy-on-Write)", systemImage: "doc.on.doc")
                    }
                    Button {
                        let currentGiB = Int(vmStore.primaryDiskVirtualSizeBytes(for: activeVM) >> 30)
                        expandDiskGiB = max(16, max(currentGiB + 8, activeVM.targetDiskSizeGiB ?? 16))
                        if expandDiskGiB > 128 { expandDiskGiB = 128 }
                        showExpandDiskSheet = true
                    } label: {
                        Label("Expand Virtual Disk...", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
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
                        Label("Compact Sparse Disk (F_PUNCHHOLE)", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }

                Section("App Container Files (`Documents/`)") {
                    if jitClient.containerFiles.isEmpty {
                        Text("No files in app container yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(jitClient.containerFiles) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: iconName(for: entry.fileName))
                                    .foregroundStyle(.blue)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.fileName)
                                        .font(.subheadline.weight(.medium))
                                    Text(entry.relativePath)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(entry.sizeText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if entry.isDeletable {
                                    Button(role: .destructive) {
                                        do {
                                            try jitClient.deleteContainerFile(entry)
                                            bootWarning = "Removed \(entry.relativePath)."
                                        } catch {
                                            bootErrorAlert = "Delete failed: \(error.localizedDescription)"
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    Button {
                        jitClient.bootstrapSandboxFolders()
                        jitClient.refreshFileStatus()
                    } label: {
                        Label("Refresh Container File List", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showDebugConsole = true
                    } label: {
                        Label("View Boot & Serial Logs...", systemImage: "terminal")
                    }
                }

                if let banner = bootWarning, !banner.isEmpty {
                    Section("Status") {
                        Label(
                            banner,
                            systemImage: banner.hasPrefix("Imported ") ? "checkmark.circle.fill" : "info.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(banner.hasPrefix("Imported ") ? .green : .secondary)
                    }
                }

                Section {
                    Button {
                        Task {
                            var activeVM = vmStore.selectedMachine
                            activeVM.ramMiB = Int(effectiveRamMiB)
                            activeVM.cpuCount = selectedProfile.cpuCount
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
                            } catch {
                                bootWarning = error.localizedDescription
                                bootErrorAlert = error.localizedDescription
                                isRunning = false
                            }
                        }
                    } label: {
                        Label(
                            isPreparingDisk ? "Unpacking Disk Image..." : "Boot \(vmStore.selectedMachine.name) (\(effectiveRamMiB) MiB)",
                            systemImage: "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingDisk || jitClient.state == .requestingExtension)
                }
            }
            .navigationTitle("henge-linux")
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
                    LabeledContent("EDK2 Firmware", value: vmStore.hasSharedFirmware ? "Installed (Shared)" : "Not Installed")
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
                                            cpuCount: selectedProfile.cpuCount,
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
                                    cpuCount: selectedProfile.cpuCount,
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

    private var aboutView: some View {
        NavigationStack {
            List {
                Section("Installed Build") {
                    LabeledContent("Version", value: "v\(appVersionString) (\(appBuildNumberString))")
                    LabeledContent("Channel", value: buildChannelLabel)
                    LabeledContent("Commit") {
                        Text(buildCommitHash)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Built", value: buildDateLabel)
                    Button {
                        UIPasteboard.general.string = buildSummaryLine
                        copiedBuildInfo = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            copiedBuildInfo = false
                        }
                    } label: {
                        Label(
                            copiedBuildInfo ? "Copied Build Info" : "Copy Version & Commit Hash",
                            systemImage: copiedBuildInfo ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                    }
                }

                Section("Runtime & Capabilities") {
                    LabeledContent("Bundle ID") {
                        Text(Bundle.main.bundleIdentifier ?? "io.hengelinux.app")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("iOS Version", value: UIDevice.current.systemVersion)
                    LabeledContent("JIT Strategy", value: SelfDebugJITClient.activeJitModeLabel)
                    LabeledContent("Engine", value: HengeVMBridge.shared.isEngineLinked ? "HengeVM Linked" : "Host Substrate Only")
                    LabeledContent("QCOW2 Zstd", value: henge_qcow2_has_zstd() ? "Enabled (libzstd)" : "zlib Only")
                    LabeledContent("LiveContainer", value: SelfDebugJITClient.isRunningInLiveContainer ? "Detected" : "No")
                }

                Section("Project & License") {
                    LabeledContent("License", value: "GPL-3.0-or-later")
                    if let repoURL = URL(string: "https://github.com/venim1103/henge-linux") {
                        Link(destination: repoURL) {
                            Label("GitHub Repository", systemImage: "safari")
                        }
                    }
                    if let releasesURL = URL(string: "https://github.com/venim1103/henge-linux/releases") {
                        Link(destination: releasesURL) {
                            Label("Releases & Nightly Builds", systemImage: "arrow.down.circle")
                        }
                    }
                }
            }
            .navigationTitle("About")
        }
    }

    private var jitStatusLabel: String {
        switch jitClient.state {
        case .idle:
            return "Ready"
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
        return henge_recommended_guest_ram_mib(henge_recommended_jit_pool_bytes())
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
            : "16 KiB page-aligned (512–10,240 MiB). Default 1,664 MiB leaves safe standard-ledger headroom."
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

    private func iconName(for fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".plist") || lower.hasSuffix(".mobiledevicepairing") {
            return "key.fill"
        }
        if lower.hasSuffix(".hvsparse") || lower.hasSuffix(".img") || lower.hasSuffix(".raw") {
            return "internaldrive.fill"
        }
        if lower.hasSuffix(".fd") {
            return "cpu.fill"
        }
        if lower.hasSuffix(".state") {
            return "memorychip.fill"
        }
        if lower.hasSuffix(".txt") || lower.hasSuffix(".md") {
            return "doc.text"
        }
        return "doc.fill"
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
        let raw = bridge.copyConsoleLog()
        let cleaned = showRawEscapeCodes ? raw : Self.sanitizeTerminalOutput(raw)
        switch filter {
        case .all:
            logText = cleaned
        case .engine:
            logText = cleaned
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    line.hasPrefix("[bridge]") || line.hasPrefix("winvm:") || line.hasPrefix("hengevm:")
                }
                .joined(separator: "\n")
        case .serial:
            logText = cleaned
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    !(line.hasPrefix("[bridge]") || line.hasPrefix("winvm:") || line.hasPrefix("hengevm:"))
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
