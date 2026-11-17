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
            subtitle: "iPhone 16 Pro · 2.5 GiB guest RAM · Safe Jetsam headroom",
            ramMiB: 2560,
            cpuCount: 4
        ),
        MachineProfile(
            id: "iphone-duo",
            name: "iPhone Duo / 12 GB Pro",
            subtitle: "4.5 GiB guest RAM · Full desktop & multi-process workloads",
            ramMiB: 4608,
            cpuCount: 4
        ),
        MachineProfile(
            id: "ipad-pro",
            name: "M-Series iPad Pro (16 GB)",
            subtitle: "6.0 GiB guest RAM · External USB-C display mode",
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
    @State private var isRunning: Bool = false
    @State private var isPreparingDisk: Bool = false
    @State private var isImportingFile: Bool = false
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
                guard let hostClip = pb.string, !hostClip.isEmpty, hostClip != lastPushedClipboard else {
                    return
                }
                lastPushedClipboard = hostClip
                HengeVMBridge.shared.pushHostClipboard(hostClip)
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
                                if preset == selectedProfile {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
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
                                    bootWarning = "Untethered Jetsam guard clamped RAM from \(effectiveRamMiB) MiB to \(actualMiB) MiB."
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

    private var deviceCapMiB: UInt32 {
        let physicalMiB = UInt64(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
        let sixtyPercent = UInt32((physicalMiB * 60) / 100)
        return min(max(sixtyPercent, 2048), 8192)
    }

    private var alignedBytes: UInt64 {
        henge_align_guest_ram_bytes(UInt32(selectedProfile.ramMiB), deviceCapMiB)
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
