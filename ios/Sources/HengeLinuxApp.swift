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

    @StateObject private var lifecycle = MetalLifecycleGuard()
    @StateObject private var jitClient = SelfDebugJITClient()
    @State private var selectedProfile: MachineProfile = MachineProfile.presets[0]
    @AppStorage("customGuestRamMiB") private var customGuestRamMiB: Int = 1664
    @State private var ramInputText: String = ""
    @State private var isRunning: Bool = false
    @State private var isPreparingDisk: Bool = false
    @State private var isImportingFile: Bool = false
    @State private var showDebugConsole: Bool = false
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
                    launcherView
                }
            }
            .sheet(item: $safariURL) { item in
                SafariSheetView(url: item.url)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showDebugConsole) {
                DebugConsoleSheetView()
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
                if ramInputText.isEmpty {
                    ramInputText = "\(effectiveRamMiB)"
                }
            }
            .onOpenURL { url in
                do {
                    bootWarning = try jitClient.importFiles(from: [url], forceAsPairingPlist: false)
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
                        bootWarning = try jitClient.importFiles(
                            from: urls,
                            forceAsPairingPlist: fileImportMode == .pairingPlist
                        )
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
                                        customGuestRamMiB = clamped
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

                        Text(
                            effectiveRamMiB > 1792
                                ? "Above ~1,792 MiB without LEDGER_NO_FOOTPRINT may hit iOS's ~3 GiB standard-ledger Jetsam kill limit."
                                : "16 KiB page-aligned (512–10,240 MiB). Default 1,664 MiB leaves safe standard-ledger headroom."
                        )
                        .font(.caption2)
                        .foregroundStyle(effectiveRamMiB > 1792 ? .orange : .secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Graphics & TXM Self-Debugger") {
                    Picker("Display Adapter", selection: $jitClient.gpuBackend) {
                        ForEach(GpuDisplayBackend.allCases) { backend in
                            Text(backend.rawValue).tag(backend)
                        }
                    }
                    Toggle("Auto-Sync Host Clipboard on Focus", isOn: $autoSyncClipboard)
                    LabeledContent("TXM JIT Pool", value: "\(SelfDebugJITClient.defaultJitPoolMiB) MiB (< 0x7000000000)")
                    LabeledContent("Pairing File", value: jitClient.pairingStatusText)
                    LabeledContent("JIT Status", value: jitStatusLabel)
                    if let diag = jitClient.extensionDiagnostic, !diag.isEmpty {
                        Text(diag)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        fileImportMode = .pairingPlist
                        isImportingFile = true
                    } label: {
                        Label("Import pairing.plist / .mobiledevicepairing...", systemImage: "key.fill")
                    }
                }

                Section("Guest Image (`Documents/Machines/ArchLinux`)") {
                    LabeledContent("Disk Container", value: jitClient.diskStatusText)
                    LabeledContent("UEFI Firmware", value: jitClient.uefiStatusText)
                    LabeledContent("iOS Files Folder", value: "On My iPhone ▸ HengeLinux (Registered)")
                    LabeledContent("Background Snapshot", value: HengeVMBridge.shared.hasSavedBackgroundSnapshot ? "suspend.state (Disk Flushed + Metadata)" : "None")
                    LabeledContent("Aligned Guest Bytes", value: "\(alignedBytes) B")
                    LabeledContent("Host Bridge", value: "http://10.0.2.4/.henge/")
                    LabeledContent("VM Engine", value: HengeVMBridge.shared.isEngineLinked ? "Linked (HengeVM)" : "Host Substrate Only")
                    Button {
                        fileImportMode = .guestFiles
                        isImportingFile = true
                    } label: {
                        Label("Import Guest Files (hvsparse / code.fd / vars.fd)...", systemImage: "folder.badge.plus")
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
                            isPreparingDisk = true
                            let diskReady: Result<Void, Error> = await withCheckedContinuation { continuation in
                                HengeVMBridge.shared.prepareDiskImage { success, error in
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
                            let gpuMode: Int32 = (jitClient.gpuBackend == .virgl3D) ? 1 : 0
                            do {
                                try HengeVMBridge.shared.startGuest(
                                    withRamMiB: effectiveRamMiB,
                                    cpuCount: Int32(selectedProfile.cpuCount),
                                    gpuBackend: gpuMode
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
                            isPreparingDisk ? "Unpacking Disk Image..." : "Boot Arch Linux (\(effectiveRamMiB) MiB)",
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

    private var sliderMaxRamMiB: Int {
        let physicalMiB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        return min(max(physicalMiB, 4096), Int(HENGE_MAX_GUEST_RAM_MIB))
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
        pattern: "\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)",
        options: []
    )

    private static func sanitizeTerminalOutput(_ input: String) -> String {
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
