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
                .fixedSize(horizontal: true, vertical: false)

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
            return "Single-Screen Canvas"
        case .clamshell(let angle):
            return String(format: "Clamshell Deck (%.0f°)", angle)
        case .openStudio:
            return "Open Studio"
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
