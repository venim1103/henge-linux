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
    let onStopSession: () -> Void

    @State private var showModifierBar: Bool = true
    @State private var ctrlActive: Bool = false
    @State private var altActive: Bool = false
    @State private var superActive: Bool = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topStatusBar

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

            Button("Stop", role: .destructive, action: onStopSession)
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
                modifierToggle("Esc", isOn: .constant(false))
                modifierToggle("Tab", isOn: .constant(false))
                modifierToggle("Ctrl", isOn: $ctrlActive)
                modifierToggle("Alt", isOn: $altActive)
                modifierToggle("Super", isOn: $superActive)
                modifierToggle("F1", isOn: .constant(false))
                modifierToggle("F2", isOn: .constant(false))
                modifierToggle("F12", isOn: .constant(false))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private var clamshellInputDeck: some View {
        VStack(spacing: 10) {
            compactModifierStrip

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.14))
                .overlay(
                    Text("Multi-Touch Trackpad & HID Deck")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .background(Color(white: 0.08))
    }

    private func modifierToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.button)
            .controlSize(.small)
            .font(.caption.monospaced())
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
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.isPaused = lifecycle.isPaused
    }
}
