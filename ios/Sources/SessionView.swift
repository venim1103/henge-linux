// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

/// Primary Arch Linux display surface hosting the Metal-backed UEFI/Wayland
/// framebuffer, hardware/software HID keyboard input, and adaptive single-screen
/// or clamshell trackpad deck.
struct SessionView: View {
    let profile: MachineProfile
    @ObservedObject var lifecycle: MetalLifecycleGuard
    @Binding var posture: DevicePosture
    let bootWarning: String?
    let onStopSession: () -> Void

    @State private var showModifierBar: Bool = true
    @State private var focusSoftwareKeyboard: Bool = false
    @State private var ctrlActive: Bool = false
    @State private var altActive: Bool = false
    @State private var superActive: Bool = false
    @State private var cursorNormX: Double = 0.5
    @State private var cursorNormY: Double = 0.5
    @State private var lastTrackpadPoint: CGPoint?

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

                MetalFramebufferRepresentable(
                    lifecycle: lifecycle,
                    focusKeyboard: $focusSoftwareKeyboard
                )
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
            .onDisappear {
                releaseActiveModifiers()
            }
        }
    }

    private func releaseActiveModifiers() {
        if ctrlActive {
            ctrlActive = false
            HengeVMBridge.shared.sendHidKeyUsage(0xE0, pressed: false)
        }
        if altActive {
            altActive = false
            HengeVMBridge.shared.sendHidKeyUsage(0xE2, pressed: false)
        }
        if superActive {
            superActive = false
            HengeVMBridge.shared.sendHidKeyUsage(0xE3, pressed: false)
        }
    }

    private var displayRamMiB: Int {
        let active = Int(HengeVMBridge.shared.activeRamMiB)
        return active > 0 ? active : profile.ramMiB
    }

    private var topStatusBar: some View {
        HStack(spacing: 10) {
            HingeSensorView(posture: $posture)

            Spacer()

            Text("\(displayRamMiB) MiB · \(profile.cpuCount) vCPU")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                focusSoftwareKeyboard.toggle()
            } label: {
                Image(systemName: focusSoftwareKeyboard ? "keyboard.fill" : "keyboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button {
                showModifierBar.toggle()
            } label: {
                Image(systemName: showModifierBar ? "slider.horizontal.below.rectangle" : "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button("Stop", role: .destructive) {
                focusSoftwareKeyboard = false
                releaseActiveModifiers()
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
                hidPulseButton("↑", usage: 0x52)
                hidPulseButton("↓", usage: 0x51)
                hidPulseButton("←", usage: 0x50)
                hidPulseButton("→", usage: 0x4F)
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
        VStack(spacing: 8) {
            compactModifierStrip

            GeometryReader { padGeo in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.14))
                    .overlay(
                        VStack(spacing: 4) {
                            Text("Multi-Touch Trackpad & HID Deck")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text("Relative drag · Tap left-click · 2-finger tap right-click")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let w = max(padGeo.size.width, 1)
                                let h = max(padGeo.size.height, 1)
                                if let prev = lastTrackpadPoint {
                                    let dx = Double((value.location.x - prev.x) / w) * 1.35
                                    let dy = Double((value.location.y - prev.y) / h) * 1.35
                                    cursorNormX = min(max(cursorNormX + dx, 0), 1)
                                    cursorNormY = min(max(cursorNormY + dy, 0), 1)
                                    HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: 0, wheel: 0)
                                }
                                lastTrackpadPoint = value.location
                            }
                            .onEnded { _ in
                                lastTrackpadPoint = nil
                            }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { _ in
                                pulseMouseButton(1)
                            }
                    )
            }
            .padding(.horizontal, 14)

            HStack(spacing: 10) {
                Button("Left Click") {
                    pulseMouseButton(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

                Button("Right Click") {
                    pulseMouseButton(2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(Color(white: 0.08))
    }

    private func pulseMouseButton(_ mask: UInt8) {
        HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: mask, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: 0, wheel: 0)
        }
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

final class MetalDisplaySurfaceView: UIView, UIKeyInput {
    var onFocusChanged: ((Bool) -> Void)?

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    var metalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }

    var hasText: Bool {
        true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupInteraction()
    }

    private func setupInteraction() {
        backgroundColor = .black
        isMultipleTouchEnabled = true

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.numberOfTouchesRequired = 1
        addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasRightClick(_:)))
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCanvasPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        onFocusChanged?(ok)
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        onFocusChanged?(false)
        return ok
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metalLayer else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
    }

    // MARK: - Hardware Keyboard (UIResponder presses)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let usage = Self.hidUsage(from: key.keyCode) {
                HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: true)
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let usage = Self.hidUsage(from: key.keyCode) {
                HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: false)
                handled = true
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private static func hidUsage(from code: UIKeyboardHIDUsage) -> UInt8? {
        let raw = code.rawValue
        if raw >= 0x04 && raw <= 0xE7 {
            return UInt8(raw)
        }
        return nil
    }

    // MARK: - Software On-Screen Keyboard (UIKeyInput)

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            guard let (usage, shift) = Self.asciiToHid(scalar.value) else { continue }
            if shift {
                HengeVMBridge.shared.sendHidKeyUsage(0xE1, pressed: true)
            }
            HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: true)
            HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: false)
            if shift {
                HengeVMBridge.shared.sendHidKeyUsage(0xE1, pressed: false)
            }
        }
    }

    func deleteBackward() {
        HengeVMBridge.shared.tapHidKeyUsage(0x2A)
    }

    private static func asciiToHid(_ cp: UInt32) -> (UInt8, Bool)? {
        if cp >= 97 && cp <= 122 {
            return (UInt8(cp - 97 + 0x04), false)
        }
        if cp >= 65 && cp <= 90 {
            return (UInt8(cp - 65 + 0x04), true)
        }
        if cp >= 49 && cp <= 57 {
            return (UInt8(cp - 49 + 0x1E), false)
        }
        switch cp {
        case 48: return (0x27, false) // 0
        case 10, 13: return (0x28, false) // Enter
        case 9: return (0x2B, false) // Tab
        case 32: return (0x2C, false) // Space
        case 45: return (0x2D, false) // -
        case 95: return (0x2D, true)  // _
        case 61: return (0x2E, false) // =
        case 43: return (0x2E, true)  // +
        case 91: return (0x2F, false) // [
        case 123: return (0x2F, true) // {
        case 93: return (0x30, false) // ]
        case 125: return (0x30, true) // }
        case 92: return (0x31, false) // backslash
        case 124: return (0x31, true) // |
        case 59: return (0x33, false) // ;
        case 58: return (0x33, true)  // :
        case 39: return (0x34, false) // '
        case 34: return (0x34, true)  // "
        case 96: return (0x35, false) // `
        case 126: return (0x35, true) // ~
        case 44: return (0x36, false) // ,
        case 60: return (0x36, true)  // <
        case 46: return (0x37, false) // .
        case 62: return (0x37, true)  // >
        case 47: return (0x38, false) // /
        case 63: return (0x38, true)  // ?
        case 33: return (0x1E, true)  // !
        case 64: return (0x1F, true)  // @
        case 35: return (0x20, true)  // #
        case 36: return (0x21, true)  // $
        case 37: return (0x22, true)  // %
        case 94: return (0x23, true)  // ^
        case 38: return (0x24, true)  // &
        case 42: return (0x25, true)  // *
        case 40: return (0x26, true)  // (
        case 41: return (0x27, true)  // )
        default: return nil
        }
    }

    // MARK: - Direct Canvas Touch / Pointer Gestures

    private func normalizedPoint(_ pt: CGPoint) -> (Double, Double) {
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let nx = min(max(Double(pt.x / w), 0.0), 1.0)
        let ny = min(max(Double(pt.y / h), 0.0), 1.0)
        return (nx, ny)
    }

    @objc private func handleCanvasTap(_ gr: UITapGestureRecognizer) {
        let (nx, ny) = normalizedPoint(gr.location(in: self))
        HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 1, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 0, wheel: 0)
        }
    }

    @objc private func handleCanvasRightClick(_ gr: UITapGestureRecognizer) {
        let (nx, ny) = normalizedPoint(gr.location(in: self))
        HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 2, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 0, wheel: 0)
        }
    }

    @objc private func handleCanvasPan(_ gr: UIPanGestureRecognizer) {
        let (nx, ny) = normalizedPoint(gr.location(in: self))
        if gr.numberOfTouches >= 2 {
            let vy = gr.translation(in: self).y
            let wheelStep = Int8(max(-5, min(5, Int(vy / 24.0))))
            if wheelStep != 0 {
                HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 0, wheel: wheelStep)
                gr.setTranslation(.zero, in: self)
            }
            return
        }
        let buttons: UInt8 = (gr.state == .began || gr.state == .changed) ? 1 : 0
        HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: buttons, wheel: 0)
    }
}

struct MetalFramebufferRepresentable: UIViewRepresentable {
    @ObservedObject var lifecycle: MetalLifecycleGuard
    @Binding var focusKeyboard: Bool

    func makeUIView(context: Context) -> MetalDisplaySurfaceView {
        let view = MetalDisplaySurfaceView(frame: .zero)
        view.onFocusChanged = { isFocused in
            if focusKeyboard != isFocused {
                focusKeyboard = isFocused
            }
        }
        if let metalLayer = view.metalLayer {
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            HengeVMBridge.shared.attachDisplayLayer(metalLayer)
        }
        return view
    }

    func updateUIView(_ uiView: MetalDisplaySurfaceView, context: Context) {
        _ = lifecycle.isPaused
        if focusKeyboard && !uiView.isFirstResponder {
            _ = uiView.becomeFirstResponder()
        } else if !focusKeyboard && uiView.isFirstResponder {
            _ = uiView.resignFirstResponder()
        }
        if let metalLayer = uiView.metalLayer {
            HengeVMBridge.shared.attachDisplayLayer(metalLayer)
        }
    }

    static func dismantleUIView(_ uiView: MetalDisplaySurfaceView, coordinator: ()) {
        HengeVMBridge.shared.attachDisplayLayer(nil)
    }
}
