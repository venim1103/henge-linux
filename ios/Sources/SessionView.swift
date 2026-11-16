// SPDX-License-Identifier: GPL-3.0-or-later
import MetalKit
import SwiftUI
import UIKit

/// Primary Arch Linux display surface hosting the Metal-backed UEFI/Wayland
/// framebuffer and adaptive single-screen or clamshell input deck.
struct SessionView: View {
    let profile: MachineProfile
    @ObservedObject var lifecycle: MetalLifecycleGuard
    @Binding var posture: DevicePosture
    let bootWarning: String?
    let onStopSession: () -> Void

    @State private var showModifierBar: Bool = true
    @State private var ctrlActive: Bool = false
    @State private var altActive: Bool = false
    @State private var superActive: Bool = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topStatusBar

                if let bootWarning {
                    Text(bootWarning)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(white: 0.12))
                }

                MetalFramebufferRepresentable(lifecycle: lifecycle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                if case .clamshell = posture {
                    clamshellInputDeck
                        .frame(height: max(220, geo.size.height * 0.44))
                } else if showModifierBar {
                    compactModifierStrip
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
    }

    private var topStatusBar: some View {
        HStack(spacing: 12) {
            HingeSensorView(posture: $posture)

            Spacer()

            Text("\(profile.ramMiB) MiB · \(profile.cpuCount) vCPU")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                showModifierBar.toggle()
            } label: {
                Image(systemName: showModifierBar ? "keyboard.chevron.compact.down" : "keyboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button("Stop", role: .destructive) {
                HengeVMBridge.shared.stopGuest()
                onStopSession()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var compactModifierStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                hidPulseButton("Esc", usage: 0x29)
                hidPulseButton("Tab", usage: 0x2B)
                modifierToggle("Ctrl", usage: 0xE0, isOn: $ctrlActive)
                modifierToggle("Alt", usage: 0xE2, isOn: $altActive)
                modifierToggle("Super", usage: 0xE3, isOn: $superActive)
                hidPulseButton("F1", usage: 0x3A)
                hidPulseButton("F2", usage: 0x3B)
                hidPulseButton("F12", usage: 0x45)
                Button("Ctrl+Alt+Del") {
                    HengeVMBridge.shared.sendCtrlAltDel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption.monospaced())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private var clamshellInputDeck: some View {
        VStack(spacing: 10) {
            compactModifierStrip

            GeometryReader { padGeo in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.14))
                    .overlay(
                        Text("Multi-Touch Trackpad & HID Deck")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let nx = min(max(value.location.x / max(padGeo.size.width, 1), 0), 1)
                                let ny = min(max(value.location.y / max(padGeo.size.height, 1), 0), 1)
                                HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 1, wheel: 0)
                            }
                            .onEnded { value in
                                let nx = min(max(value.location.x / max(padGeo.size.width, 1), 0), 1)
                                let ny = min(max(value.location.y / max(padGeo.size.height, 1), 0), 1)
                                HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 0, wheel: 0)
                            }
                    )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(Color(white: 0.08))
    }

    private func hidPulseButton(_ label: String, usage: UInt8) -> some View {
        Button(label) {
            HengeVMBridge.shared.tapHidKeyUsage(usage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption.monospaced())
    }

    private func modifierToggle(_ label: String, usage: UInt8, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.button)
            .controlSize(.small)
            .font(.caption.monospaced())
            .onChange(of: isOn.wrappedValue) { _, pressed in
                HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: pressed)
            }
    }
}

struct MetalFramebufferRepresentable: UIViewRepresentable {
    @ObservedObject var lifecycle: MetalLifecycleGuard

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = lifecycle.isPaused
        if let metalLayer = view.layer as? CAMetalLayer {
            HengeVMBridge.shared.attachDisplayLayer(metalLayer)
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.isPaused = lifecycle.isPaused
        if let metalLayer = uiView.layer as? CAMetalLayer {
            HengeVMBridge.shared.attachDisplayLayer(metalLayer)
        }
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        HengeVMBridge.shared.attachDisplayLayer(nil)
    }
}
