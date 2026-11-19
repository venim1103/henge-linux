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

    private enum SessionTab: String, CaseIterable, Identifiable {
        case display = "Display"
        case terminal = "ttyAMA0"
        var id: String { rawValue }
    }

    private struct PasteRequest: Equatable {
        let id = UUID()
        let text: String
    }

    @State private var activeTab: SessionTab = .display
    @State private var showModifierBar: Bool = true
    @State private var showDebugConsole: Bool = false
    @State private var focusSoftwareKeyboard: Bool = false
    @State private var pendingPaste: PasteRequest?
    @State private var shiftActive: Bool = false
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

                if activeTab == .display {
                    MetalFramebufferRepresentable(
                        lifecycle: lifecycle,
                        focusKeyboard: $focusSoftwareKeyboard,
                        suppressSoftwareKeyboard: !focusSoftwareKeyboard,
                        pendingPasteID: pendingPaste?.id,
                        pendingPasteText: pendingPaste?.text,
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
                } else {
                    InteractiveSerialTerminalView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if shiftActive {
            shiftActive = false
            HengeVMBridge.shared.sendHidKeyUsage(0xE1, pressed: false)
        }
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
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Picker("View", selection: $activeTab) {
                    ForEach(SessionTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 148, maxWidth: 184)
                .layoutPriority(1)

                Spacer(minLength: 4)

                Text("\(displayRamMiB)M·\(displayCpuCount)c")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

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

            HStack(spacing: 6) {
                HingeSensorView(posture: $posture)

                Spacer(minLength: 4)

                Button {
                    showDebugConsole = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Debug & Telemetry Logs")

                if activeTab == .display {
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
                }
            }
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
                modifierToggle("Shift", usage: 0xE1, isOn: $shiftActive)
                modifierToggle("Ctrl", usage: 0xE0, isOn: $ctrlActive)
                modifierToggle("Alt", usage: 0xE2, isOn: $altActive)
                modifierToggle("Super", usage: 0xE3, isOn: $superActive)
                hidPulseButton("Caps", usage: 0x39)
                hidPulseButton("←", usage: 0x50)
                hidPulseButton("→", usage: 0x4F)
                hidPulseButton("↑", usage: 0x52)
                hidPulseButton("↓", usage: 0x51)
                hidPulseButton("Home", usage: 0x4A)
                hidPulseButton("End", usage: 0x4D)
                hidPulseButton("PgUp", usage: 0x4B)
                hidPulseButton("PgDn", usage: 0x4E)
                hidPulseButton("Ins", usage: 0x49)
                hidPulseButton("Prnt", usage: 0x46)
                hidPulseButton("ScrLk", usage: 0x47)
                hidPulseButton("Pause", usage: 0x48)
                hidPulseButton("Menu", usage: 0x65)
                hidPulseButton("F1", usage: 0x3A)
                hidPulseButton("F2", usage: 0x3B)
                hidPulseButton("F3", usage: 0x3C)
                hidPulseButton("F4", usage: 0x3D)
                hidPulseButton("F5", usage: 0x3E)
                hidPulseButton("F6", usage: 0x3F)
                hidPulseButton("F7", usage: 0x40)
                hidPulseButton("F8", usage: 0x41)
                hidPulseButton("F9", usage: 0x42)
                hidPulseButton("F10", usage: 0x43)
                hidPulseButton("F11", usage: 0x44)
                hidPulseButton("F12", usage: 0x45)
                Button("Paste") {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        HengeVMBridge.shared.pushHostClipboard(clip)
                        pendingPaste = PasteRequest(text: clip)
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
        HidHoldKeyButton(label: label, usage: usage) {
            releaseActiveModifiers()
        }
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

/// Hold-capable HID key button that preserves horizontal ScrollView gestures:
/// sends key-down on press and holds until release (enabling native guest key
/// repeat for Esc, Backspace, Delete, arrows, F1-F12, etc.).
private struct HidHoldKeyButton: View {
    let label: String
    let usage: UInt8
    let onRelease: () -> Void

    @State private var didHandlePress: Bool = false

    var body: some View {
        Button {
            if !didHandlePress {
                HengeVMBridge.shared.tapHidKeyUsage(usage)
                onRelease()
            }
            didHandlePress = false
        } label: {
            Text(label)
        }
        .buttonStyle(HidHoldKeyButtonStyle(usage: usage, didHandlePress: $didHandlePress, onRelease: onRelease))
    }
}

private struct HidHoldKeyButtonStyle: ButtonStyle {
    let usage: UInt8
    @Binding var didHandlePress: Bool
    let onRelease: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        HidHoldKeyBody(
            configuration: configuration,
            usage: usage,
            didHandlePress: $didHandlePress,
            onRelease: onRelease
        )
    }
}

private struct HidHoldKeyBody: View {
    let configuration: ButtonStyle.Configuration
    let usage: UInt8
    @Binding var didHandlePress: Bool
    let onRelease: () -> Void

    @State private var isHeld: Bool = false
    @State private var pressedAt: Date?

    var body: some View {
        configuration.label
            .font(.caption.monospaced())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.22))
            )
            .foregroundStyle(configuration.isPressed ? .white : .primary)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    if !isHeld {
                        isHeld = true
                        didHandlePress = true
                        pressedAt = Date()
                        HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: true)
                    }
                } else if isHeld {
                    isHeld = false
                    let elapsed = pressedAt.map { Date().timeIntervalSince($0) } ?? 0.0
                    let minDwell = max(0.0, 0.02 - elapsed)
                    pressedAt = nil
                    if minDwell > 0.0 {
                        let keyUsage = usage
                        let dwellNanos = UInt64(minDwell * 1_000_000_000.0)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: dwellNanos)
                            HengeVMBridge.shared.sendHidKeyUsage(keyUsage, pressed: false)
                            onRelease()
                        }
                    } else {
                        HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: false)
                        onRelease()
                    }
                }
            }
            .onDisappear {
                if isHeld {
                    isHeld = false
                    pressedAt = nil
                    HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: false)
                }
            }
    }
}

final class MetalDisplaySurfaceView: UIView, UIKeyInput, UIEditMenuInteractionDelegate {
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
    private var editMenuInteraction: UIEditMenuInteraction?
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

        let editMenu = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenu)
        editMenuInteraction = editMenu

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCanvasLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.numberOfTouchesRequired = 1
        addGestureRecognizer(longPress)
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
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale > 0 ? scale : 2.0
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

    @objc private func handleCanvasLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()
        let location = gr.location(in: self)
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        editMenuInteraction?.presentEditMenu(with: config)
    }

    private func sendHidChord(modifiers: [UInt8], key: UInt8) {
        for mod in modifiers {
            HengeVMBridge.shared.sendHidKeyUsage(mod, pressed: true)
        }
        HengeVMBridge.shared.sendHidKeyUsage(key, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            HengeVMBridge.shared.sendHidKeyUsage(key, pressed: false)
            for mod in modifiers.reversed() {
                HengeVMBridge.shared.sendHidKeyUsage(mod, pressed: false)
            }
        }
    }

    private func pullGuestClipboardAfterCopy() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let guestClip = HengeVMBridge.shared.takeGuestClipboard(), !guestClip.isEmpty {
                UIPasteboard.general.string = guestClip
            }
        }
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let selectAllAction = UIAction(title: "Select All") { [weak self] _ in
            self?.sendHidChord(modifiers: [0xE0], key: 0x04) // Ctrl+A
        }
        let copyAction = UIAction(title: "Copy") { [weak self] _ in
            self?.sendHidChord(modifiers: [0xE0], key: 0x06) // Ctrl+C
            self?.pullGuestClipboardAfterCopy()
        }
        let copyTermAction = UIAction(title: "Copy (Term)") { [weak self] _ in
            self?.sendHidChord(modifiers: [0xE0, 0xE1], key: 0x06) // Ctrl+Shift+C
            self?.pullGuestClipboardAfterCopy()
        }
        let pasteAction = UIAction(title: "Paste") { [weak self] _ in
            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                HengeVMBridge.shared.pushHostClipboard(clip)
                self?.insertText(clip)
            }
        }
        return UIMenu(children: [selectAllAction, copyAction, copyTermAction, pasteAction])
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
    final class Coordinator {
        var lastHandledPasteID: UUID?
    }

    @ObservedObject var lifecycle: MetalLifecycleGuard
    @Binding var focusKeyboard: Bool
    var suppressSoftwareKeyboard: Bool
    var pendingPasteID: UUID?
    var pendingPasteText: String?
    var onCharacterTyped: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
        if let pasteID = pendingPasteID,
           let pasteText = pendingPasteText,
           !pasteText.isEmpty,
           context.coordinator.lastHandledPasteID != pasteID {
            context.coordinator.lastHandledPasteID = pasteID
            uiView.insertText(pasteText)
        }
    }

    static func dismantleUIView(_ uiView: MetalDisplaySurfaceView, coordinator: Coordinator) {
        HengeVMBridge.shared.detachDisplayLayer(ifMatching: uiView.metalLayer)
    }
}

/// Interactive PL011 (`ttyAMA0`) serial console tab embedded in `SessionView`.
private struct InteractiveSerialTerminalView: View {
    @State private var outputText: String = ""
    @State private var inputLine: String = ""
    @State private var lastObservedBytes: UInt64 = UInt64.max
    @State private var autoScroll: Bool = true
    @State private var showRawAnsi: Bool = false

    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(outputText.isEmpty ? "Connected to PL011 UART (ttyAMA0)..." : outputText)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(outputText.isEmpty ? Color.secondary : Color.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .textSelection(.enabled)

                        Color.clear
                            .frame(height: 1)
                            .id("serial-term-bottom")
                    }
                }
                .background(Color.black)
                .onChange(of: outputText) { _, _ in
                    if autoScroll {
                        proxy.scrollTo("serial-term-bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    refreshOutput(force: true)
                    if autoScroll {
                        proxy.scrollTo("serial-term-bottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    serialByteButton("Ctrl-C", byte: 0x03)
                    serialByteButton("Ctrl-D", byte: 0x04)
                    serialByteButton("Ctrl-Z", byte: 0x1A)
                    serialByteButton("Esc", byte: 0x1B)
                    serialByteButton("Tab", byte: 0x09)
                    serialSeqButton("↑", seq: "\u{1B}[A")
                    serialSeqButton("↓", seq: "\u{1B}[B")
                    Button("Paste") {
                        if let clip = UIPasteboard.general.string, !clip.isEmpty {
                            HengeVMBridge.shared.sendSerialText(clip)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.caption.monospaced())

                    Button(showRawAnsi ? "Clean" : "Raw") {
                        showRawAnsi.toggle()
                        refreshOutput(force: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.caption.monospaced())

                    Button("Clear") {
                        HengeVMBridge.shared.clearConsoleLog()
                        refreshOutput(force: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.caption.monospaced())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(white: 0.10))

            HStack(spacing: 8) {
                TextField("Send command to ttyAMA0...", text: $inputLine)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit {
                        sendCurrentInput()
                    }

                Button("Send") {
                    sendCurrentInput()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(white: 0.14))
        }
        .onReceive(pollTimer) { _ in
            refreshOutput(force: false)
        }
    }

    private func sendCurrentInput() {
        let payload = inputLine + "\r"
        inputLine = ""
        HengeVMBridge.shared.sendSerialText(payload)
    }

    private func serialByteButton(_ title: String, byte: UInt8) -> some View {
        Button(title) {
            HengeVMBridge.shared.sendSerialControlByte(byte)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .font(.caption.monospaced())
    }

    private func serialSeqButton(_ title: String, seq: String) -> some View {
        Button(title) {
            HengeVMBridge.shared.sendSerialText(seq)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .font(.caption.monospaced())
    }

    private func refreshOutput(force: Bool) {
        let bridge = HengeVMBridge.shared
        let total = bridge.consoleTotalBytes
        guard force || total != lastObservedBytes else {
            return
        }
        lastObservedBytes = total
        let raw = bridge.copyConsoleLog()
        outputText = showRawAnsi ? raw : DebugConsoleSheetView.sanitizeTerminalOutput(raw)
    }
}
