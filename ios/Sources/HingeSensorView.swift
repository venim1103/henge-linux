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
        HStack(spacing: 6) {
            Label(postureLabel, systemImage: postureIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Toggle("Split Deck", isOn: $forceClamshellPreview)
                .toggleStyle(.button)
                .controlSize(.mini)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .onChange(of: forceClamshellPreview) { _, enabled in
                    if enabled {
                        posture = .clamshell(angleDegrees: 115.0)
                    } else {
                        posture = Self.hasHardwareHingeSensor ? .openStudio : .singleScreen
                    }
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

    private var postureLabel: String {
        switch posture {
        case .singleScreen:
            return "Canvas"
        case .clamshell(let angle):
            return String(format: "Clamshell %.0f°", angle)
        case .openStudio:
            return "Studio"
        }
    }

    private var postureIcon: String {
        switch posture {
        case .singleScreen:
            return "iphone"
        case .clamshell:
            return "laptopcomputer"
        case .openStudio:
            return "rectangle.split.2x1"
        }
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
