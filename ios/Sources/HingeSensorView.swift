// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

enum DevicePosture: Equatable {
    case singleScreen
    case clamshell(angleDegrees: Double)
    case openStudio
}

/// Adapts between foldable dual-screen devices (iPhone Duo via UIHingeInteraction
/// when available at runtime) and standard single-screen iPhones/iPads (e.g., iPhone 16 Pro).
struct HingeSensorView: View {
    @Binding var posture: DevicePosture
    @State private var forceClamshellPreview: Bool = false

    var body: some View {
        Button {
            forceClamshellPreview.toggle()
        } label: {
            Image(systemName: isClamshellActive ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isClamshellActive ? Color.white : Color.blue)
                .frame(width: 30, height: 28)
                .background(
                    isClamshellActive ? Color.blue : Color.white.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Split Deck")
        .onChange(of: forceClamshellPreview) { _, enabled in
            if enabled {
                posture = .clamshell(angleDegrees: 115.0)
            } else {
                posture = Self.hasHardwareHingeSensor ? .openStudio : .singleScreen
            }
        }
        .background {
            if Self.hasHardwareHingeSensor {
                HingeInteractionObserverView { angleDegrees in
                    guard !forceClamshellPreview else { return }
                    if angleDegrees > 15.0 && angleDegrees < 165.0 {
                        posture = .clamshell(angleDegrees: angleDegrees)
                    } else {
                        posture = .openStudio
                    }
                }
                .frame(width: 0, height: 0)
            }
        }
        .onAppear {
            if forceClamshellPreview {
                posture = .clamshell(angleDegrees: 115.0)
            } else if Self.hasHardwareHingeSensor {
                posture = .openStudio
            } else {
                posture = .singleScreen
            }
        }
    }

    static var hasHardwareHingeSensor: Bool {
        NSClassFromString("UIHingeInteraction") != nil
    }

    private var isClamshellActive: Bool {
        if case .clamshell = posture {
            return true
        }
        return false
    }
}

private struct HingeInteractionObserverView: UIViewRepresentable {
    let onAngleChanged: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAngleChanged: onAngleChanged)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onAngleChanged = onAngleChanged
    }

    final class Coordinator: NSObject {
        var onAngleChanged: (Double) -> Void
        private var attachedInteraction: NSObject?

        init(onAngleChanged: @escaping (Double) -> Void) {
            self.onAngleChanged = onAngleChanged
        }

        func attach(to view: UIView) {
            guard attachedInteraction == nil,
                  let interactionCls = NSClassFromString("UIHingeInteraction") as? NSObject.Type else {
                return
            }
            let allocSel = NSSelectorFromString("alloc")
            let initSel = NSSelectorFromString("initWithDelegate:")
            guard interactionCls.responds(to: allocSel) else { return }
            let allocated = (interactionCls as AnyObject).perform(allocSel)?.takeUnretainedValue() as? NSObject
            guard let instance = allocated, instance.responds(to: initSel) else { return }
            _ = instance.perform(initSel, with: self)
            if let interaction = instance as? UIInteraction {
                view.addInteraction(interaction)
                attachedInteraction = instance
            }
        }

        @objc(hingeInteractionDidUpdate:)
        func hingeInteractionDidUpdate(_ interaction: NSObject) {
            if let angle = interaction.value(forKey: "angle") as? Double {
                onAngleChanged(angle)
            }
        }
    }
}
