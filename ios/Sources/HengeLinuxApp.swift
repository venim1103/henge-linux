// SPDX-License-Identifier: GPL-3.0-or-later
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
    @StateObject private var lifecycle = MetalLifecycleGuard()
    @StateObject private var jitClient = SelfDebugJITClient()
    @State private var selectedProfile: MachineProfile = MachineProfile.presets[0]
    @State private var isRunning: Bool = false
    @State private var bootWarning: String?
    @State private var bootErrorAlert: String?
    @State private var posture: DevicePosture = .singleScreen
    @State private var safariURL: IdentifiableURL?
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
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                guard isRunning else { return }
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
                    LabeledContent("TXM JIT Pool", value: "\(SelfDebugJITClient.defaultJitPoolMiB) MiB (< 0x7000000000)")
                    LabeledContent("Pairing File", value: jitClient.hasPairingFile ? "Documents/pairing.plist" : "Missing (Optional)")
                    LabeledContent("JIT Status", value: jitStatusLabel)
                }

                Section("Guest Image (`Documents/Machines/ArchLinux`)") {
                    LabeledContent("Disk Container", value: "archlinux.hvsparse")
                    LabeledContent("UEFI Firmware", value: "code.fd / vars.fd")
                    LabeledContent("Aligned Guest Bytes", value: "\(alignedBytes) B")
                    LabeledContent("Host Bridge", value: "http://10.0.2.4/.henge/")
                    LabeledContent("VM Engine", value: HengeVMBridge.shared.isEngineLinked ? "Linked (HengeVM)" : "Host Substrate Only")
                }

                Section {
                    Button {
                        Task {
                            await jitClient.prepareSession()
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
                        Label("Boot Arch Linux (\(effectiveRamMiB) MiB)", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(jitClient.state == .requestingExtension)
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
