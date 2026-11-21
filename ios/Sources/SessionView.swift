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
        var iconName: String {
            switch self {
            case .display: return "display"
            case .terminal: return "terminal"
            }
        }
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
    @State private var heldMouseButtons: UInt8 = 0
    @State private var keyboardHeight: CGFloat = 0

    var body: some View {
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

            ZStack {
                VStack(spacing: 0) {
                    MetalFramebufferRepresentable(
                        lifecycle: lifecycle,
                        focusKeyboard: $focusSoftwareKeyboard,
                        suppressSoftwareKeyboard: !focusSoftwareKeyboard || activeTab != .display,
                        allowGuestResize: !isSoftwareKeyboardVisible && !isClamshellPosture && activeTab == .display,
                        layoutTrigger: "\(posture)-\(showModifierBar)-\(activeTab == .display)",
                        pendingPasteID: pendingPaste?.id,
                        pendingPasteText: pendingPaste?.text,
                        onPasteConsumed: {
                            pendingPaste = nil
                        },
                        onCharacterTyped: {
                            releaseActiveModifiers()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                    if case .clamshell = posture {
                        clamshellInputDeck
                            .containerRelativeFrame(.vertical) { height, _ in
                                clamshellDeckHeight(forContainerHeight: height)
                            }
                    } else if showModifierBar {
                        compactModifierStrip
                    }
                }
                .opacity(activeTab == .display ? 1 : 0)
                .allowsHitTesting(activeTab == .display)

                if activeTab == .terminal {
                    InteractiveSerialTerminalView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, keyboardHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showDebugConsole) {
            DebugConsoleSheetView()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardHeight(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardHeight != 0 {
                keyboardHeight = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            if keyboardHeight != 0 {
                keyboardHeight = 0
            }
        }
        .onChange(of: focusSoftwareKeyboard) { _, show in
            if !show && keyboardHeight != 0 {
                keyboardHeight = 0
            }
        }
        .onChange(of: activeTab) { _, tab in
            pendingPaste = nil
            if tab != .display && focusSoftwareKeyboard {
                focusSoftwareKeyboard = false
            }
            if keyboardHeight != 0 {
                keyboardHeight = 0
            }
        }
        .onDisappear {
            pendingPaste = nil
            keyboardHeight = 0
            releaseActiveModifiers()
            if heldMouseButtons != 0 {
                heldMouseButtons = 0
                HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: 0, wheel: 0)
            }
        }
    }

    private func updateKeyboardHeight(from notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        let keyWindow = windowScene?.windows.first(where: \.isKeyWindow) ?? windowScene?.windows.first
        let screenHeight = keyWindow?.bounds.height ?? windowScene?.screen.bounds.height ?? 0
        let bottomInset = keyWindow?.safeAreaInsets.bottom ?? 0
        guard screenHeight > 0 else { return }
        let nextHeight: CGFloat
        if endFrame.minY >= screenHeight - 1 || endFrame.height <= 0 {
            nextHeight = 0
        } else {
            nextHeight = max(0, screenHeight - endFrame.minY - bottomInset)
        }
        if abs(keyboardHeight - nextHeight) > 0.5 {
            keyboardHeight = nextHeight
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

    private var topStatusBar: some View {
        HStack(spacing: 8) {
            Picker("View", selection: $activeTab) {
                ForEach(SessionTab.allCases) { tab in
                    Image(systemName: tab.iconName)
                        .accessibilityLabel(tab.rawValue)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 92)

            if activeTab == .display {
                HingeSensorView(posture: $posture)
            }

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
                .accessibilityLabel("Toggle Keyboard")

                Button {
                    showModifierBar.toggle()
                } label: {
                    Image(systemName: showModifierBar ? "slider.horizontal.below.rectangle" : "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Toggle Special Keys")
            }

            Button(role: .destructive) {
                focusSoftwareKeyboard = false
                releaseActiveModifiers()
                HengeVMBridge.shared.stopGuest()
                onStopSession()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel("Stop VM")
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
                hidPulseButton("Caps", usage: 0x39, repeatable: false)
                hidPulseButton("←", usage: 0x50)
                hidPulseButton("→", usage: 0x4F)
                hidPulseButton("↑", usage: 0x52)
                hidPulseButton("↓", usage: 0x51)
                hidPulseButton("Home", usage: 0x4A)
                hidPulseButton("End", usage: 0x4D)
                hidPulseButton("PgUp", usage: 0x4B)
                hidPulseButton("PgDn", usage: 0x4E)
                hidPulseButton("Ins", usage: 0x49, repeatable: false)
                hidPulseButton("Prnt", usage: 0x46, repeatable: false)
                hidPulseButton("ScrLk", usage: 0x47, repeatable: false)
                hidPulseButton("Pause", usage: 0x48, repeatable: false)
                hidPulseButton("Menu", usage: 0x65, repeatable: false)
                hidPulseButton("F1", usage: 0x3A, repeatable: false)
                hidPulseButton("F2", usage: 0x3B, repeatable: false)
                hidPulseButton("F3", usage: 0x3C, repeatable: false)
                hidPulseButton("F4", usage: 0x3D, repeatable: false)
                hidPulseButton("F5", usage: 0x3E, repeatable: false)
                hidPulseButton("F6", usage: 0x3F, repeatable: false)
                hidPulseButton("F7", usage: 0x40, repeatable: false)
                hidPulseButton("F8", usage: 0x41, repeatable: false)
                hidPulseButton("F9", usage: 0x42, repeatable: false)
                hidPulseButton("F10", usage: 0x43, repeatable: false)
                hidPulseButton("F11", usage: 0x44, repeatable: false)
                hidPulseButton("F12", usage: 0x45, repeatable: false)
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

    private var isSoftwareKeyboardVisible: Bool {
        keyboardHeight > 0 || focusSoftwareKeyboard
    }

    private var isClamshellPosture: Bool {
        if case .clamshell = posture {
            return true
        }
        return false
    }

    private func clamshellDeckHeight(forContainerHeight totalHeight: CGFloat) -> CGFloat {
        if isSoftwareKeyboardVisible {
            let remaining = max(120, totalHeight - keyboardHeight - 52)
            let cap: CGFloat = showModifierBar ? 164 : 118
            let floorH: CGFloat = showModifierBar ? 112 : 84
            return min(cap, max(floorH, remaining * 0.36))
        }
        return max(220, totalHeight * 0.42)
    }

    private var clamshellInputDeck: some View {
        let compact = isSoftwareKeyboardVisible
        return VStack(spacing: compact ? 4 : 8) {
            if showModifierBar {
                compactModifierStrip
            }

            GeometryReader { padGeo in
                RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                    .fill(Color(white: 0.14))
                    .overlay(
                        VStack(spacing: compact ? 0 : 4) {
                            if compact {
                                Text("Trackpad")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Multi-Touch Trackpad & HID Deck")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text("Relative drag · Tap click · Hold Left/Right to drag")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    )
                    .contentShape(Rectangle())
                    .overlay(
                        TrackpadSurfaceRepresentable(
                            onRelativeMove: { dx, dy in
                                cursorNormX = min(max(cursorNormX + dx, 0), 1)
                                cursorNormY = min(max(cursorNormY + dy, 0), 1)
                                HengeVMBridge.shared.sendPointerNormX(
                                    cursorNormX,
                                    normY: cursorNormY,
                                    buttons: heldMouseButtons,
                                    wheel: 0
                                )
                            },
                            onSingleTap: {
                                pulseMouseButton(1)
                            },
                            onTwoFingerTap: {
                                pulseMouseButton(2)
                            },
                            onTwoFingerScroll: { wheelStep in
                                HengeVMBridge.shared.sendPointerNormX(
                                    cursorNormX,
                                    normY: cursorNormY,
                                    buttons: heldMouseButtons,
                                    wheel: wheelStep
                                )
                            }
                        )
                    )
            }
            .padding(.horizontal, 14)

            HStack(spacing: 10) {
                MouseHoldButton(label: "Left Click", buttonMask: 1, compact: compact) { pressed in
                    setHeldMouseButton(1, pressed: pressed)
                }
                .frame(maxWidth: .infinity)

                MouseHoldButton(label: "Right Click", buttonMask: 2, compact: compact) { pressed in
                    setHeldMouseButton(2, pressed: pressed)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, compact ? 4 : 10)
        }
        .background(Color(white: 0.08))
    }

    private func setHeldMouseButton(_ mask: UInt8, pressed: Bool) {
        if pressed {
            heldMouseButtons |= mask
        } else {
            heldMouseButtons &= ~mask
        }
        HengeVMBridge.shared.sendPointerNormX(
            cursorNormX,
            normY: cursorNormY,
            buttons: heldMouseButtons,
            wheel: 0
        )
    }

    private func pulseMouseButton(_ mask: UInt8) {
        let downMask = heldMouseButtons | mask
        HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: downMask, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: heldMouseButtons, wheel: 0)
        }
    }

    private func hidPulseButton(_ label: String, usage: UInt8, repeatable: Bool = true) -> some View {
        HidHoldKeyButton(label: label, usage: usage, repeatable: repeatable) {
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

/// Hold-capable Left/Right mouse button for the Split Deck:
/// immediately asserts button-down on touch and holds it through simultaneous
/// trackpad dragging, with a minimum 25 ms dwell on quick taps.
private struct MouseHoldButton: View {
    let label: String
    let buttonMask: UInt8
    var compact: Bool = false
    let onPressChanged: (Bool) -> Void

    @State private var isPressed: Bool = false
    @State private var pressedAt: Date?

    var body: some View {
        Text(label)
            .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 5 : 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isPressed ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.24))
            )
            .foregroundStyle(isPressed ? .white : .primary)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        pressedAt = Date()
                        onPressChanged(true)
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        isPressed = false
                        let elapsed = pressedAt.map { Date().timeIntervalSince($0) } ?? 0.0
                        pressedAt = nil
                        let minDwell = max(0.0, 0.025 - elapsed)
                        if minDwell > 0.0 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + minDwell) {
                                onPressChanged(false)
                            }
                        } else {
                            onPressChanged(false)
                        }
                    }
            )
            .onDisappear {
                if isPressed {
                    isPressed = false
                    pressedAt = nil
                    onPressChanged(false)
                }
            }
    }
}

/// Hold-capable HID key button that preserves horizontal ScrollView gestures:
/// emits an immediate 20 ms key pulse on press, and for repeatable keys (arrows,
/// Backspace, Delete, Tab, PageUp/Down, etc.) drives host-paced repeat pulses
/// (~350 ms initial delay, ~15 Hz repeat) while held. Short discrete pulses work
/// identically on PL011 UART, UEFI, virtio-input, xHCI, and uinput without
/// triggering guest double-repeat or stuck keys.
private struct HidHoldKeyButton: View {
    let label: String
    let usage: UInt8
    let repeatable: Bool
    let onRelease: () -> Void

    @State private var didHandlePress: Bool = false

    var body: some View {
        Button {
            if !didHandlePress {
                HengeVMBridge.shared.tapHidKeyUsage(usage)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    onRelease()
                }
            }
            didHandlePress = false
        } label: {
            Text(label)
        }
        .buttonStyle(
            HidHoldKeyButtonStyle(
                usage: usage,
                repeatable: repeatable,
                didHandlePress: $didHandlePress,
                onRelease: onRelease
            )
        )
    }
}

private struct HidHoldKeyButtonStyle: ButtonStyle {
    let usage: UInt8
    let repeatable: Bool
    @Binding var didHandlePress: Bool
    let onRelease: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        HidHoldKeyBody(
            configuration: configuration,
            usage: usage,
            repeatable: repeatable,
            didHandlePress: $didHandlePress,
            onRelease: onRelease
        )
    }
}

private struct HidHoldKeyBody: View {
    let configuration: ButtonStyle.Configuration
    let usage: UInt8
    let repeatable: Bool
    @Binding var didHandlePress: Bool
    let onRelease: () -> Void

    @State private var isHeld: Bool = false
    @State private var repeatTask: Task<Void, Never>?

    private static let pulseDwellNs: UInt64 = 20_000_000     // 20 ms key-down pulse (< 250 ms guest EV_REP)
    private static let initialDelayNs: UInt64 = 330_000_000  // + 20 ms pulse = 350 ms before first repeat
    private static let repeatGapNs: UInt64 = 45_000_000      // + 20 ms pulse = 65 ms period (~15.4 Hz)

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
                    guard !isHeld else { return }
                    isHeld = true
                    didHandlePress = true
                    startRepeatLoop()
                } else if isHeld {
                    stopRepeatLoop(notifyRelease: true)
                }
            }
            .onDisappear {
                if isHeld {
                    stopRepeatLoop(notifyRelease: false)
                }
            }
    }

    private func startRepeatLoop() {
        repeatTask?.cancel()
        let keyUsage = usage
        let shouldRepeat = repeatable
        // Emit initial key-down synchronously so quick taps never get dropped if
        // SwiftUI toggles isPressed false before the async Task starts executing.
        HengeVMBridge.shared.sendHidKeyUsage(keyUsage, pressed: true)
        repeatTask = Task { @MainActor in
            var keyDown = true
            defer {
                if keyDown {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                        HengeVMBridge.shared.sendHidKeyUsage(keyUsage, pressed: false)
                    }
                }
            }

            do {
                try await Task.sleep(nanoseconds: Self.pulseDwellNs)
            } catch {
                return
            }
            HengeVMBridge.shared.sendHidKeyUsage(keyUsage, pressed: false)
            keyDown = false

            guard shouldRepeat, !Task.isCancelled else { return }

            do {
                try await Task.sleep(nanoseconds: Self.initialDelayNs)
            } catch {
                return
            }

            while !Task.isCancelled {
                HengeVMBridge.shared.sendHidKeyUsage(keyUsage, pressed: true)
                keyDown = true
                do {
                    try await Task.sleep(nanoseconds: Self.pulseDwellNs)
                } catch {
                    return
                }
                HengeVMBridge.shared.sendHidKeyUsage(keyUsage, pressed: false)
                keyDown = false
                do {
                    try await Task.sleep(nanoseconds: Self.repeatGapNs)
                } catch {
                    return
                }
            }
        }
    }

    private func stopRepeatLoop(notifyRelease: Bool) {
        isHeld = false
        repeatTask?.cancel()
        repeatTask = nil
        if notifyRelease {
            // Release sticky modifiers (Ctrl/Alt/Shift/Super) strictly after the
            // 25 ms key-up dwell completes so guest chords (e.g. Ctrl+Alt+F1)
            // always register with modifiers held.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                onRelease()
            }
        }
    }
}

/// Dedicated hidden `UIKeyInput` proxy view that becomes first responder ONLY
/// when the user explicitly toggles the on-screen software keyboard. Keeping
/// `UIKeyInput` off `MetalDisplaySurfaceView` prevents UIKit from retaining a
/// ghost keyboard safe-area inset when the software keyboard is dismissed.
private final class SoftwareKeyboardInputProxyView: UIView, UIKeyInput {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onPressesBegan: ((Set<UIPress>, UIPressesEvent?) -> Bool)?
    var onPressesEnded: ((Set<UIPress>, UIPressesEvent?) -> Bool)?
    var onResignedFirstResponder: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

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

    func insertText(_ text: String) {
        onInsertText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPressesBegan?(presses, event) != true {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPressesEnded?(presses, event) != true {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        onResignedFirstResponder?()
        return ok
    }
}

final class MetalDisplaySurfaceView: UIView, @MainActor UIEditMenuInteractionDelegate {
    var onFocusChanged: ((Bool) -> Void)?
    var onCharacterTyped: (() -> Void)?
    /// Controls whether the hidden `SoftwareKeyboardInputProxyView` is first
    /// responder (showing the iOS software keyboard). When `true` (suppressed),
    /// the proxy resigns so UIKit collapses the keyboard safe area to 0, while
    /// `MetalDisplaySurfaceView` itself remains first responder for Bluetooth
    /// hardware keyboard `pressesBegan` events without triggering a keyboard.
    var suppressSoftwareKeyboard: Bool = true {
        didSet {
            guard oldValue != suppressSoftwareKeyboard else { return }
            scheduleSyncResponderState()
        }
    }
    var allowGuestResize: Bool = true {
        didSet {
            if allowGuestResize && !oldValue {
                scheduleGuestDisplayResize()
            }
        }
    }
    private let softwareKeyboardProxy = SoftwareKeyboardInputProxyView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var isProgrammaticResponderChange = false
    private var responderSyncScheduled = false
    private var pendingGuestResizeWorkItem: DispatchWorkItem?
    private var lastSentGuestWidth: Int = 0
    private var lastSentGuestHeight: Int = 0
    private var editMenuInteraction: UIEditMenuInteraction?
    private var pendingKeystrokes: [(usage: UInt8, shift: Bool)] = []
    private var activeSoftwareKeyUsage: UInt8?
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

    private func scheduleSyncResponderState() {
        guard !responderSyncScheduled else { return }
        responderSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.responderSyncScheduled = false
            self.syncResponderState()
        }
    }

    private func syncResponderState() {
        guard window != nil else { return }
        if suppressSoftwareKeyboard {
            let wasShowing = softwareKeyboardProxy.isFirstResponder
            if wasShowing {
                isProgrammaticResponderChange = true
                _ = softwareKeyboardProxy.resignFirstResponder()
                isProgrammaticResponderChange = false
                // Let UIKit finish dispatching keyboardWillHide before restoring
                // hardware-keyboard first-responder ownership on the Metal view.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self, self.window != nil, self.suppressSoftwareKeyboard, !self.isFirstResponder else { return }
                    _ = self.becomeFirstResponder()
                }
            } else if !isFirstResponder {
                _ = becomeFirstResponder()
            }
        } else {
            if !softwareKeyboardProxy.isFirstResponder {
                _ = softwareKeyboardProxy.becomeFirstResponder()
            }
        }
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

        softwareKeyboardProxy.isUserInteractionEnabled = false
        softwareKeyboardProxy.alpha = 0.0
        softwareKeyboardProxy.onInsertText = { [weak self] text in
            self?.insertText(text)
        }
        softwareKeyboardProxy.onDeleteBackward = { [weak self] in
            self?.deleteBackward()
        }
        softwareKeyboardProxy.onPressesBegan = { [weak self] presses, event in
            self?.handleHardwarePresses(presses, pressed: true) ?? false
        }
        softwareKeyboardProxy.onPressesEnded = { [weak self] presses, event in
            self?.handleHardwarePresses(presses, pressed: false) ?? false
        }
        softwareKeyboardProxy.onResignedFirstResponder = { [weak self] in
            guard let self else { return }
            if !self.isProgrammaticResponderChange {
                self.onFocusChanged?(false)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil, self.suppressSoftwareKeyboard, !self.isFirstResponder else { return }
                    _ = self.becomeFirstResponder()
                }
            }
        }
        addSubview(softwareKeyboardProxy)

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

        let leftHold = UILongPressGestureRecognizer(target: self, action: #selector(handleCanvasLeftHold(_:)))
        leftHold.minimumPressDuration = 0.22
        leftHold.allowableMovement = 18
        leftHold.numberOfTouchesRequired = 1
        addGestureRecognizer(leftHold)

        let menuLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCanvasLongPress(_:)))
        menuLongPress.minimumPressDuration = 0.45
        menuLongPress.numberOfTouchesRequired = 2
        addGestureRecognizer(menuLongPress)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.syncResponderState()
            }
        } else {
            pendingGuestResizeWorkItem?.cancel()
            pendingGuestResizeWorkItem = nil
        }
    }

    override func resignFirstResponder() -> Bool {
        pendingKeystrokes.removeAll()
        isDrainingKeystrokes = false
        if let held = activeSoftwareKeyUsage {
            activeSoftwareKeyUsage = nil
            HengeVMBridge.shared.sendHidKeyUsage(held, pressed: false)
        }
        for mod: UInt8 in 0xE0...0xE7 {
            HengeVMBridge.shared.sendHidKeyUsage(mod, pressed: false)
        }
        return super.resignFirstResponder()
    }

    deinit {
        pendingKeystrokes.removeAll()
    }

    override var bounds: CGRect {
        didSet {
            if oldValue.size != bounds.size {
                syncMetalDrawableSize()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncMetalDrawableSize()
    }

    private func syncMetalDrawableSize() {
        guard let metalLayer else { return }
        guard bounds.width >= 4 && bounds.height >= 4 else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let effectiveScale = scale > 0 ? scale : 2.0
        let targetSize = CGSize(
            width: (bounds.width * effectiveScale).rounded(),
            height: (bounds.height * effectiveScale).rounded()
        )
        guard targetSize.width >= 4 && targetSize.height >= 4 else { return }
        if metalLayer.contentsScale != effectiveScale || metalLayer.drawableSize != targetSize {
            // Never take hengelinux_render_lock() on the Main Thread: HvFbMetalPresenter
            // holds that lock across CAMetalLayer.nextDrawable(), which waits on
            // CoreAnimation/Main Thread and causes lock contention / UI stalls.
            metalLayer.contentsScale = effectiveScale
            metalLayer.drawableSize = targetSize
        }
        if allowGuestResize {
            scheduleGuestDisplayResize()
        }
    }

    private func scheduleGuestDisplayResize() {
        pendingGuestResizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.allowGuestResize, let win = self.window else { return }
            let scale = win.screen.scale > 0 ? win.screen.scale : self.traitCollection.displayScale
            let effectiveScale = scale > 0 ? scale : 2.0
            let kmsScale = min(effectiveScale, 2.0)
            // Compute the guest virtual monitor geometry from the stable window safe area.
            // In iPhone portrait orientation, keep standard 1280x800 desktop landscape
            // (matching 2D UEFI GOP) so opening Trackpad/Keyboard fills the full width
            // instead of pillarboxing a narrow portrait strip. In landscape (rotated iPhone,
            // iPad, external monitor), match the landscape safe-area aspect ratio.
            let safeBounds = win.bounds.inset(by: win.safeAreaInsets)
            let topBarOverhead: CGFloat = 44
            let targetW = max(safeBounds.width, 1)
            let targetH = max(safeBounds.height - topBarOverhead, 1)
            let clampedW: Int
            let clampedH: Int
            if targetH > targetW {
                clampedW = 1280
                clampedH = 800
            } else {
                var pxW = Int(targetW * kmsScale) & ~1
                var pxH = Int(targetH * kmsScale) & ~1
                if pxW > 1920 {
                    let ratio = 1920.0 / Double(pxW)
                    pxW = 1920
                    pxH = Int(Double(pxH) * ratio) & ~1
                }
                guard pxW >= 320 && pxH >= 240 else { return }
                clampedW = min(pxW, 1920)
                clampedH = min(pxH, 1200)
            }
            if self.lastSentGuestWidth > 0 &&
               abs(self.lastSentGuestWidth - clampedW) < 32 &&
               abs(self.lastSentGuestHeight - clampedH) < 32 {
                return
            }
            self.lastSentGuestWidth = clampedW
            self.lastSentGuestHeight = clampedH
            HengeVMBridge.shared.updateDisplaySize(
                width: UInt32(clampedW),
                height: UInt32(clampedH)
            )
        }
        pendingGuestResizeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - Hardware Keyboard (UIResponder presses)

    private func handleHardwarePresses(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        var handled = false
        for press in presses {
            if let key = press.key, let usage = Self.hidUsage(from: key.keyCode) {
                HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: pressed)
                handled = true
            }
        }
        return handled
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handleHardwarePresses(presses, pressed: true) {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handleHardwarePresses(presses, pressed: false) {
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
        activeSoftwareKeyUsage = next.usage
        HengeVMBridge.shared.sendHidKeyUsage(next.usage, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.014) { [weak self] in
            if self?.activeSoftwareKeyUsage == next.usage {
                self?.activeSoftwareKeyUsage = nil
            }
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
        if suppressSoftwareKeyboard && !isFirstResponder {
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

    @objc private func handleCanvasLeftHold(_ gr: UILongPressGestureRecognizer) {
        let (nx, ny) = normalizedPoint(gr.location(in: self))
        switch gr.state {
        case .began:
            if suppressSoftwareKeyboard && !isFirstResponder {
                _ = becomeFirstResponder()
            }
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.impactOccurred()
            HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 1, wheel: 0)
        case .changed:
            HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 1, wheel: 0)
        case .ended, .cancelled, .failed:
            HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 0, wheel: 0)
        default:
            break
        }
    }

    @objc private func handleCanvasLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        if suppressSoftwareKeyboard && !isFirstResponder {
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
        let pasteAction = UIAction(title: "Paste") { [weak self] _ in
            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                HengeVMBridge.shared.pushHostClipboard(clip)
                self?.insertText(clip)
            }
        }
        let copySerialAction = UIAction(title: "Copy Serial Log") { _ in
            let log = HengeVMBridge.shared.copyConsoleLog()
            if !log.isEmpty {
                UIPasteboard.general.string = log
            }
        }
        let desktopMenu = UIMenu(
            title: "Desktop…",
            children: [
                UIAction(title: "Select All (Ctrl+A)") { [weak self] _ in
                    self?.sendHidChord(modifiers: [0xE0], key: 0x04)
                },
                UIAction(title: "Copy (Ctrl+C)") { [weak self] _ in
                    self?.sendHidChord(modifiers: [0xE0], key: 0x06)
                    self?.pullGuestClipboardAfterCopy()
                },
                UIAction(title: "Copy Terminal (Ctrl+Shift+C)") { [weak self] _ in
                    self?.sendHidChord(modifiers: [0xE0, 0xE1], key: 0x06)
                    self?.pullGuestClipboardAfterCopy()
                }
            ]
        )
        return UIMenu(children: [pasteAction, copySerialAction, desktopMenu])
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
        var lastLayoutTrigger: String = ""
    }

    @ObservedObject var lifecycle: MetalLifecycleGuard
    @Binding var focusKeyboard: Bool
    var suppressSoftwareKeyboard: Bool
    var allowGuestResize: Bool = true
    var layoutTrigger: String = ""
    var pendingPasteID: UUID?
    var pendingPasteText: String?
    var onPasteConsumed: (() -> Void)?
    var onCharacterTyped: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MetalDisplaySurfaceView {
        let view = MetalDisplaySurfaceView(frame: .zero)
        view.suppressSoftwareKeyboard = suppressSoftwareKeyboard
        view.allowGuestResize = allowGuestResize
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
        uiView.allowGuestResize = allowGuestResize
        uiView.suppressSoftwareKeyboard = suppressSoftwareKeyboard
        if context.coordinator.lastLayoutTrigger != layoutTrigger {
            context.coordinator.lastLayoutTrigger = layoutTrigger
            DispatchQueue.main.async {
                uiView.setNeedsLayout()
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
            let consumed = onPasteConsumed
            DispatchQueue.main.async {
                consumed?()
            }
        }
    }

    static func dismantleUIView(_ uiView: MetalDisplaySurfaceView, coordinator: Coordinator) {
        HengeVMBridge.shared.detachDisplayLayer(ifMatching: uiView.metalLayer)
    }
}

/// Read-only UIKit monospace log viewer (`UITextView`) used by both
/// `InteractiveSerialTerminalView` and `DebugConsoleSheetView` to avoid
/// SwiftUI `ScrollViewReader` + `.textSelection(.enabled)` AttributeGraph cycles.
struct MonospaceLogTextView: UIViewRepresentable {
    let text: String
    let placeholder: String
    let fontSize: CGFloat
    let autoScroll: Bool

    final class Coordinator {
        var lastText: String = ""
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .black
        tv.indicatorStyle = .white
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textColor = text.isEmpty ? .secondaryLabel : .systemGreen
        tv.text = text.isEmpty ? placeholder : text
        context.coordinator.lastText = text
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        guard context.coordinator.lastText != text else { return }
        context.coordinator.lastText = text
        uiView.textColor = text.isEmpty ? .secondaryLabel : .systemGreen
        uiView.text = text.isEmpty ? placeholder : text
        if autoScroll && !text.isEmpty {
            let nsLen = (uiView.text as NSString).length
            if nsLen > 0 {
                uiView.scrollRangeToVisible(NSRange(location: nsLen - 1, length: 1))
            }
        }
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
            MonospaceLogTextView(
                text: outputText,
                placeholder: "Connected to PL011 UART (ttyAMA0)...",
                fontSize: 12,
                autoScroll: autoScroll
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .onAppear {
                refreshOutput(force: true)
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
