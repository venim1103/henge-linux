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
    @State private var showDebugConsole: Bool = false
    @State private var focusSoftwareKeyboard: Bool = false
    @State private var ctrlActive: Bool = false
    @State private var altActive: Bool = false
    @State private var superActive: Bool = false
    @State private var cursorNormX: Double = 0.5
    @State private var cursorNormY: Double = 0.5

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
                    focusKeyboard: $focusSoftwareKeyboard,
                    suppressSoftwareKeyboard: !focusSoftwareKeyboard,
                    onCharacterTyped: {
                        releaseActiveModifiers()
                    }
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
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .background(Color.black.ignoresSafeArea())
            .sheet(isPresented: $showDebugConsole) {
                DebugConsoleSheetView()
            }
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

    private var displayCpuCount: Int {
        let active = Int(HengeVMBridge.shared.activeCpuCount)
        return active > 0 ? active : profile.cpuCount
    }

    private var topStatusBar: some View {
        HStack(spacing: 6) {
            HingeSensorView(posture: $posture)

            Spacer(minLength: 2)

            Text("\(displayRamMiB)M·\(displayCpuCount)c")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Button {
                showDebugConsole = true
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel("Debug & Serial Logs")

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
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var compactModifierStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                hidPulseButton("Esc", usage: 0x29)
                hidPulseButton("Tab", usage: 0x2B)
                hidPulseButton("Bck", usage: 0x2A)
                hidPulseButton("Del", usage: 0x4C)
                modifierToggle("Ctrl", usage: 0xE0, isOn: $ctrlActive)
                modifierToggle("Alt", usage: 0xE2, isOn: $altActive)
                modifierToggle("Super", usage: 0xE3, isOn: $superActive)
                hidPulseButton("←", usage: 0x50)
                hidPulseButton("→", usage: 0x4F)
                hidPulseButton("↑", usage: 0x52)
                hidPulseButton("↓", usage: 0x51)
                hidPulseButton("Home", usage: 0x4A)
                hidPulseButton("End", usage: 0x4D)
                hidPulseButton("PgUp", usage: 0x4B)
                hidPulseButton("PgDn", usage: 0x4E)
                hidPulseButton("F1", usage: 0x3A)
                hidPulseButton("F2", usage: 0x3B)
                hidPulseButton("F3", usage: 0x3C)
                hidPulseButton("F4", usage: 0x3D)
                hidPulseButton("F11", usage: 0x44)
                hidPulseButton("F12", usage: 0x45)
                Button("Paste") {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        HengeVMBridge.shared.pushHostClipboard(clip)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption.monospaced())
                Button("CAD") {
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
                    .overlay(
                        TrackpadSurfaceRepresentable(
                            onRelativeMove: { dx, dy in
                                cursorNormX = min(max(cursorNormX + dx, 0), 1)
                                cursorNormY = min(max(cursorNormY + dy, 0), 1)
                                HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: 0, wheel: 0)
                            },
                            onSingleTap: {
                                pulseMouseButton(1)
                            },
                            onTwoFingerTap: {
                                pulseMouseButton(2)
                            },
                            onTwoFingerScroll: { wheelStep in
                                HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: 0, wheel: wheelStep)
                            }
                        )
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
            releaseActiveModifiers()
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
    var onCharacterTyped: (() -> Void)?
    /// When true, `inputView` returns an empty `UIView` so the view remains first
    /// responder for Bluetooth/hardware keyboard `pressesBegan` events without
    /// popping up the on-screen iOS software keyboard.
    var suppressSoftwareKeyboard: Bool = true {
        didSet {
            if oldValue != suppressSoftwareKeyboard, isFirstResponder {
                reloadInputViews()
            }
        }
    }
    private let emptyInputView = UIView(frame: .zero)
    private var pendingKeystrokes: [(usage: UInt8, shift: Bool)] = []
    private var isDrainingKeystrokes = false

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    var metalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override var inputView: UIView? {
        suppressSoftwareKeyboard ? emptyInputView : nil
    }

    var keyboardType: UIKeyboardType {
        get { .asciiCapable }
        set {}
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
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

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasRightClick(_:)))
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.numberOfTouchesRequired = 2
        singleTap.require(toFail: twoFingerTap)

        addGestureRecognizer(twoFingerTap)
        addGestureRecognizer(singleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCanvasPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && !isFirstResponder {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                _ = self.becomeFirstResponder()
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if !suppressSoftwareKeyboard {
            onFocusChanged?(ok)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        pendingKeystrokes.removeAll()
        isDrainingKeystrokes = false
        for mod: UInt8 in 0xE0...0xE7 {
            HengeVMBridge.shared.sendHidKeyUsage(mod, pressed: false)
        }
        let ok = super.resignFirstResponder()
        onFocusChanged?(false)
        return ok
    }

    deinit {
        pendingKeystrokes.removeAll()
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

    private func enqueueHidKeystroke(usage: UInt8, shift: Bool) {
        pendingKeystrokes.append((usage: usage, shift: shift))
        if !isDrainingKeystrokes {
            drainNextKeystroke()
        }
    }

    private func drainNextKeystroke() {
        guard !pendingKeystrokes.isEmpty else {
            isDrainingKeystrokes = false
            return
        }
        isDrainingKeystrokes = true
        let next = pendingKeystrokes.removeFirst()
        if next.shift {
            HengeVMBridge.shared.sendHidKeyUsage(0xE1, pressed: true)
        }
        HengeVMBridge.shared.sendHidKeyUsage(next.usage, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.014) { [weak self] in
            HengeVMBridge.shared.sendHidKeyUsage(next.usage, pressed: false)
            if next.shift {
                HengeVMBridge.shared.sendHidKeyUsage(0xE1, pressed: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                self?.drainNextKeystroke()
            }
        }
    }

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            guard let (usage, shift) = Self.asciiToHid(scalar.value) else { continue }
            enqueueHidKeystroke(usage: usage, shift: shift)
        }
        onCharacterTyped?()
    }

    func deleteBackward() {
        enqueueHidKeystroke(usage: 0x2A, shift: false)
        onCharacterTyped?()
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
        case 39, 0x2018, 0x2019: return (0x34, false) // ' and curly single quotes
        case 34, 0x201C, 0x201D: return (0x34, true)  // " and curly double quotes
        case 0x2013, 0x2014: return (0x2D, false)     // en-dash / em-dash -> -
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
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
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

final class MultiTouchTrackpadUIView: UIView {
    var onRelativeMove: ((Double, Double) -> Void)?
    var onSingleTap: (() -> Void)?
    var onTwoFingerTap: (() -> Void)?
    var onTwoFingerScroll: ((Int8) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }

    private func setupGestures() {
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.numberOfTouchesRequired = 1

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoTap.numberOfTapsRequired = 1
        twoTap.numberOfTouchesRequired = 2
        singleTap.require(toFail: twoTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2

        addGestureRecognizer(twoTap)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(pan)
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleTwoFingerTap() {
        onTwoFingerTap?()
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let delta = gr.translation(in: self)
        if gr.numberOfTouches >= 2 {
            let wheelStep = Int8(max(-5, min(5, Int(delta.y / 24.0))))
            if wheelStep != 0 {
                onTwoFingerScroll?(wheelStep)
                gr.setTranslation(.zero, in: self)
            }
            return
        }
        if gr.state == .changed {
            let dx = Double(delta.x / w) * 1.35
            let dy = Double(delta.y / h) * 1.35
            onRelativeMove?(dx, dy)
            gr.setTranslation(.zero, in: self)
        }
    }
}

struct TrackpadSurfaceRepresentable: UIViewRepresentable {
    let onRelativeMove: (Double, Double) -> Void
    let onSingleTap: () -> Void
    let onTwoFingerTap: () -> Void
    let onTwoFingerScroll: (Int8) -> Void

    func makeUIView(context: Context) -> MultiTouchTrackpadUIView {
        let view = MultiTouchTrackpadUIView(frame: .zero)
        view.onRelativeMove = onRelativeMove
        view.onSingleTap = onSingleTap
        view.onTwoFingerTap = onTwoFingerTap
        view.onTwoFingerScroll = onTwoFingerScroll
        return view
    }

    func updateUIView(_ uiView: MultiTouchTrackpadUIView, context: Context) {
        uiView.onRelativeMove = onRelativeMove
        uiView.onSingleTap = onSingleTap
        uiView.onTwoFingerTap = onTwoFingerTap
        uiView.onTwoFingerScroll = onTwoFingerScroll
    }
}

struct MetalFramebufferRepresentable: UIViewRepresentable {
    @ObservedObject var lifecycle: MetalLifecycleGuard
    @Binding var focusKeyboard: Bool
    var suppressSoftwareKeyboard: Bool
    var onCharacterTyped: (() -> Void)?

    func makeUIView(context: Context) -> MetalDisplaySurfaceView {
        let view = MetalDisplaySurfaceView(frame: .zero)
        view.suppressSoftwareKeyboard = suppressSoftwareKeyboard
        view.onFocusChanged = { isFocused in
            DispatchQueue.main.async {
                if !isFocused && focusKeyboard {
                    focusKeyboard = false
                } else if isFocused && !view.suppressSoftwareKeyboard && !focusKeyboard {
                    focusKeyboard = true
                }
            }
        }
        view.onCharacterTyped = onCharacterTyped
        if let metalLayer = view.metalLayer {
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            HengeVMBridge.shared.attachDisplayLayer(metalLayer)
        }
        return view
    }

    func updateUIView(_ uiView: MetalDisplaySurfaceView, context: Context) {
        _ = lifecycle.isPaused
        uiView.onCharacterTyped = onCharacterTyped
        uiView.suppressSoftwareKeyboard = suppressSoftwareKeyboard
        if !uiView.isFirstResponder {
            DispatchQueue.main.async {
                if !uiView.isFirstResponder {
                    _ = uiView.becomeFirstResponder()
                }
            }
        }
        if let metalLayer = uiView.metalLayer {
            HengeVMBridge.shared.attachDisplayLayer(metalLayer)
        }
    }

    static func dismantleUIView(_ uiView: MetalDisplaySurfaceView, coordinator: ()) {
        HengeVMBridge.shared.detachDisplayLayer(ifMatching: uiView.metalLayer)
    }
}
