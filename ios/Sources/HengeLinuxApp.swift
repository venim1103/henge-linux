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
    @State private var newVMName: String = ""
    @State private var newVMDistroTag: String = "debian"
    @State private var newVMCreateBlankDisk: Bool = false
    @State private var newVMBlankDiskGiB: Int = 16
    @State private var newVMGenerateCidata: Bool = true
    @State private var cidataUsername: String = "linux"
    @State private var cidataPassword: String = "linux"
    @State private var cidataHostname: String = "hengelinux"
    @State private var showCidataSheet: Bool = false
    @State private var fileImportMode: FileImportMode = .pairingPlist
    @State private var bootWarning: String?
    @State private var bootErrorAlert: String?
    @State private var posture: DevicePosture = .singleScreen
    @State private var safariURL: IdentifiableURL?
    @AppStorage("autoSyncClipboard") private var autoSyncClipboard: Bool = false
    @State private var lastPushedClipboard: String = ""
    @State private var lastPasteboardChangeCount: Int = -1

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
                                    let created = try vmStore.createMachine(
                                        name: newVMName,
                                        distroTag: newVMDistroTag,
                                        ramMiB: Int(effectiveRamMiB),
                                        cpuCount: selectedProfile.cpuCount
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
            .onReceive(bridgePollTimer) { _ in
                guard isRunning else { return }
                if !HengeVMBridge.shared.isRunning {
                    isRunning = false
                    safariURL = nil
                    jitClient.prepareForReboot()
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
                            let diskReady: Result<Void, Error> = await withCheckedContinuation { continuation in
                                HengeVMBridge.shared.prepareDiskImage(
                                    atMachineDir: machineDir.path,
                                    primaryDiskName: activeVM.primaryDiskFileName,
                                    codePath: codeURL.path,
                                    varsPath: varsURL.path
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
        henge_recommended_guest_ram_mib(henge_recommended_jit_pool_bytes())
    }

    private var ramAdvisoryText: String {
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
        let availMiB = Int(henge_available_memory_bytes() / (1024 * 1024))
        let physicalMiB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let upper = availMiB > 0 ? max(availMiB, 2048) : max(physicalMiB, 4096)
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
    @Environment(\.dismiss) private var dismiss
    @State private var telemetryText: String = ""
    @State private var logText: String = ""
    @State private var lastObservedBytes: UInt64 = UInt64.max
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

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(logText.isEmpty ? "Waiting for UEFI / PL011 serial (ttyAMA0) or HengeVM engine output..." : logText)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(logText.isEmpty ? Color.secondary : Color.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .textSelection(.enabled)

                            Color.clear
                                .frame(height: 1)
                                .id("console-bottom")
                        }
                    }
                    .background(Color.black)
                    .onChange(of: logText) { _, _ in
                        if autoScroll {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo("console-bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        refreshLogs(force: true)
                        if autoScroll {
                            proxy.scrollTo("console-bottom", anchor: .bottom)
                        }
                    }
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
        logText = showRawEscapeCodes ? raw : Self.sanitizeTerminalOutput(raw)
    }

    private static let csiEscapeRegex = try? NSRegularExpression(
        pattern: "\\x1B\\[[0-9;?]*[ -/]*[@-~]",
        options: []
    )
    private static let oscEscapeRegex = try? NSRegularExpression(
        pattern: "\\x1B\\](?:9999;[^\\x07\\x1B]*|[^\\x07\\x1B]*)(?:\\x07|\\x1B\\\\)",
        options: []
    )

    static func sanitizeTerminalOutput(_ input: String) -> String {
        var text = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if let csiRegex = csiEscapeRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = csiRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        if let oscRegex = oscEscapeRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = oscRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        return text
    }
}
