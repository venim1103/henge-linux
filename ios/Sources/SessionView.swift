// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

/// Primary Arch Linux display surface hosting the Metal-backed UEFI/Wayland
/// framebuffer, hardware/software HID keyboard input, and adaptive single-screen
/// or clamshell trackpad deck.
struct SessionView: View {
    let profile: MachineProfile
    @ObservedObject var lifecycle: MetalLifecycleGuard
    @ObservedObject var externalDisplay: ExternalDisplayManager
    @ObservedObject private var hardwareInput = HardwareInputManager.shared
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

    @AppStorage("oledScreenSaverAutoDimSeconds") private var autoDimSeconds: Int = 0
    @AppStorage("showPerformanceHUD") private var showPerformanceHUD: Bool = false
    @State private var activeTab: SessionTab = .display
    @State private var showModifierBar: Bool = true
    @State private var showExternalMousepad: Bool = true
    @State private var showDebugConsole: Bool = false
    @State private var focusSoftwareKeyboard: Bool = false
    @State private var focusTerminalKeyboard: Bool = false
    @State private var pendingPaste: PasteRequest?
    @State private var shiftActive: Bool = false
    @State private var ctrlActive: Bool = false
    @State private var altActive: Bool = false
    @State private var superActive: Bool = false
    @State private var cursorNormX: Double = 0.5
    @State private var cursorNormY: Double = 0.5
    @State private var heldMouseButtons: UInt8 = 0
    @State private var hardwareMouseButtons: UInt8 = 0
    @State private var keyboardHeight: CGFloat = 0
    @State private var isScreenSaverActive: Bool = false
    @State private var savedScreenBrightness: CGFloat?
    @State private var lastUserActivityAt: Date = Date()

    private let idleCheckTimer = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { rootGeo in
            let totalW = max(rootGeo.size.width, 1)
            let totalH = max(rootGeo.size.height, 1)
            let isLandscape = totalW > totalH
            let effectiveKeyboardHeight = min(keyboardHeight, max(0, totalH - (isLandscape ? 110 : 140)))
            let topBarEstHeight: CGFloat = isLandscape ? 34 : 44
            let contentAvailHeight = max(0, totalH - effectiveKeyboardHeight - topBarEstHeight)
            let sideBySide = isLandscape && isClamshellPosture && !externalDisplay.isRenderingOnExternalDisplay
            let deckLayout = sideBySide
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))

            ZStack {
                VStack(spacing: 0) {
                    topStatusBar(isLandscape: isLandscape)
                        .layoutPriority(2)

                    if let bootWarning {
                        Text(bootWarning)
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 12)
                            .padding(.vertical, isLandscape ? 3 : 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(white: 0.12))
                    }

                    ZStack {
                        VStack(spacing: 0) {
                            deckLayout {
                                ZStack {
                                    MetalFramebufferRepresentable(
                                        lifecycle: lifecycle,
                                        focusKeyboard: $focusSoftwareKeyboard,
                                        isActiveDisplayTab: activeTab == .display && !showDebugConsole,
                                        suppressSoftwareKeyboard: !focusSoftwareKeyboard || activeTab != .display || isScreenSaverActive,
                                        allowGuestResize: !isSoftwareKeyboardVisible && !isClamshellPosture && activeTab == .display && !externalDisplay.isRenderingOnExternalDisplay,
                                        layoutTrigger: "\(posture)-\(showModifierBar)-\(activeTab == .display)-\(externalDisplay.isRenderingOnExternalDisplay)-\(isLandscape)-\(Int(effectiveKeyboardHeight))",
                                        pendingPasteID: pendingPaste?.id,
                                        pendingPasteText: pendingPaste?.text,
                                        onPasteConsumed: {
                                            pendingPaste = nil
                                        },
                                        onCharacterTyped: {
                                            releaseActiveModifiers()
                                        },
                                        onPointerMoved: { nx, ny in
                                            cursorNormX = nx
                                            cursorNormY = ny
                                        }
                                    )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.black)

                                    if externalDisplay.isRenderingOnExternalDisplay {
                                        externalMonitorControlDeck(isLandscape: isLandscape)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                if !externalDisplay.isRenderingOnExternalDisplay {
                                    if isClamshellPosture {
                                        clamshellInputDeck(
                                            includeModifierStrip: !sideBySide && showModifierBar,
                                            compact: isSoftwareKeyboardVisible || sideBySide
                                        )
                                        .frame(
                                            width: sideBySide ? landscapeDeckWidth(totalWidth: totalW) : nil,
                                            height: sideBySide ? nil : min(clamshellDeckHeight(forContainerHeight: totalH), max(88, contentAvailHeight * 0.56))
                                        )
                                        .frame(maxHeight: sideBySide ? .infinity : nil)
                                    } else if showModifierBar && !sideBySide {
                                        compactModifierStrip(compact: isLandscape || isSoftwareKeyboardVisible)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if sideBySide && showModifierBar {
                                compactModifierStrip(compact: true)
                            }
                        }
                        .opacity(activeTab == .display ? 1 : 0)
                        .allowsHitTesting(activeTab == .display)

                        InteractiveSerialTerminalView(
                            isActiveTab: activeTab == .terminal,
                            showModifierBar: showModifierBar,
                            compactBar: isLandscape || isSoftwareKeyboardVisible,
                            focusKeyboard: $focusTerminalKeyboard,
                            onOpenLogs: {
                                showDebugConsole = true
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .opacity(activeTab == .terminal ? 1 : 0)
                        .allowsHitTesting(activeTab == .terminal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if showPerformanceHUD && activeTab == .display && !isScreenSaverActive {
                            LivePerformanceHUDPill {
                                activateScreenSaver()
                            }
                            .padding(.top, 8)
                            .padding(.trailing, 8)
                        }
                    }
                }
                .padding(.bottom, effectiveKeyboardHeight)
                .frame(width: totalW, height: totalH, alignment: .top)
                .clipped()
                .background(Color.black.ignoresSafeArea())
                .overlay(
                    TouchActivityObserverRepresentable {
                        lastUserActivityAt = Date()
                    }
                )

                if isScreenSaverActive {
                    OLEDScreenSaverOverlayView(
                        externalMonitorLabel: externalDisplay.isRenderingOnExternalDisplay
                            ? "External \(externalDisplay.activeResolutionLabel)"
                            : nil,
                        onWake: {
                            deactivateScreenSaver()
                        }
                    )
                    .transition(.opacity)
                    .zIndex(100)
                }
            }
            .onChange(of: isLandscape) { _, _ in
                if !focusSoftwareKeyboard && !focusTerminalKeyboard && keyboardHeight != 0 {
                    keyboardHeight = 0
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(isScreenSaverActive)
        .sheet(isPresented: $showDebugConsole) {
            DebugConsoleSheetView()
        }
        .onReceive(idleCheckTimer) { now in
            guard autoDimSeconds > 0, !isScreenSaverActive else { return }
            if now.timeIntervalSince(lastUserActivityAt) >= TimeInterval(autoDimSeconds) {
                activateScreenSaver()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if isScreenSaverActive {
                deactivateScreenSaver()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardHeight(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { note in
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
        .onChange(of: shiftActive) { _, pressed in
            HengeVMBridge.shared.sendHidKeyUsage(0xE1, pressed: pressed)
        }
        .onChange(of: ctrlActive) { _, pressed in
            HengeVMBridge.shared.sendHidKeyUsage(0xE0, pressed: pressed)
        }
        .onChange(of: altActive) { _, pressed in
            HengeVMBridge.shared.sendHidKeyUsage(0xE2, pressed: pressed)
        }
        .onChange(of: superActive) { _, pressed in
            HengeVMBridge.shared.sendHidKeyUsage(0xE3, pressed: pressed)
        }
        .onChange(of: focusSoftwareKeyboard) { _, show in
            lastUserActivityAt = Date()
            if !show && !focusTerminalKeyboard && keyboardHeight != 0 {
                keyboardHeight = 0
            }
        }
        .onChange(of: focusTerminalKeyboard) { _, show in
            lastUserActivityAt = Date()
            if !show && !focusSoftwareKeyboard && keyboardHeight != 0 {
                keyboardHeight = 0
            }
        }
        .onChange(of: activeTab) { _, tab in
            lastUserActivityAt = Date()
            pendingPaste = nil
            if tab != .display && focusSoftwareKeyboard {
                focusSoftwareKeyboard = false
            }
            if tab != .terminal && focusTerminalKeyboard {
                focusTerminalKeyboard = false
            }
            if keyboardHeight != 0 {
                keyboardHeight = 0
            }
            syncHardwareInputSessionState()
        }
        .onChange(of: isScreenSaverActive) { _, _ in
            syncHardwareInputSessionState()
        }
        .onChange(of: showDebugConsole) { _, _ in
            syncHardwareInputSessionState()
        }
        .onAppear {
            configureHardwareInputCallbacks()
            hardwareInput.refreshConnectedDevices()
            syncHardwareInputSessionState()
        }
        .onDisappear {
            hardwareInput.isDisplaySessionActive = false
            hardwareInput.onActivity = nil
            hardwareInput.onRelativePointerMove = nil
            hardwareInput.onHardwareMouseButtonsChanged = nil
            hardwareInput.onHardwareMouseWheel = nil
            hardwareInput.onHardwareKeyTyped = nil
            if isScreenSaverActive {
                deactivateScreenSaver()
            }
            pendingPaste = nil
            keyboardHeight = 0
            releaseActiveModifiers()
            if heldMouseButtons != 0 || hardwareMouseButtons != 0 {
                heldMouseButtons = 0
                hardwareMouseButtons = 0
                HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: 0, wheel: 0)
            }
        }
    }

    private var effectiveMouseButtons: UInt8 {
        heldMouseButtons | hardwareMouseButtons
    }

    private func syncHardwareInputSessionState() {
        // Keep physical USB/Bluetooth keyboard and mouse active during the OLED
        // Screen Saver so users can keep typing/mousing on an external monitor
        // while the iPhone screen stays black.
        hardwareInput.isDisplaySessionActive = (activeTab == .display) && !showDebugConsole
    }

    private func configureHardwareInputCallbacks() {
        hardwareInput.onActivity = {
            lastUserActivityAt = Date()
        }
        hardwareInput.onRelativePointerMove = { dx, dy in
            cursorNormX = min(max(cursorNormX + dx, 0), 1)
            cursorNormY = min(max(cursorNormY + dy, 0), 1)
            HengeVMBridge.shared.sendPointerNormX(
                cursorNormX,
                normY: cursorNormY,
                buttons: effectiveMouseButtons,
                wheel: 0
            )
        }
        hardwareInput.onHardwareMouseButtonsChanged = { mask in
            hardwareMouseButtons = mask
            HengeVMBridge.shared.sendPointerNormX(
                cursorNormX,
                normY: cursorNormY,
                buttons: effectiveMouseButtons,
                wheel: 0
            )
        }
        hardwareInput.onHardwareMouseWheel = { wheelStep in
            HengeVMBridge.shared.sendPointerNormX(
                cursorNormX,
                normY: cursorNormY,
                buttons: effectiveMouseButtons,
                wheel: wheelStep
            )
        }
        hardwareInput.onHardwareKeyTyped = {
            releaseActiveModifiers()
        }
    }

    private func activateScreenSaver() {
        guard !isScreenSaverActive else { return }
        focusSoftwareKeyboard = false
        focusTerminalKeyboard = false
        releaseActiveModifiers()
        if let screen = ExternalDisplayManager.mainApplicationScreen() {
            if savedScreenBrightness == nil {
                savedScreenBrightness = screen.brightness
            }
            screen.brightness = 0.01
        }
        externalDisplay.setLocalScreenSaverActive(true)
        withAnimation(.easeInOut(duration: 0.2)) {
            isScreenSaverActive = true
        }
    }

    private func deactivateScreenSaver() {
        lastUserActivityAt = Date()
        externalDisplay.setLocalScreenSaverActive(false)
        if let previous = savedScreenBrightness,
           let screen = ExternalDisplayManager.mainApplicationScreen() {
            screen.brightness = previous
        }
        savedScreenBrightness = nil
        if isScreenSaverActive {
            withAnimation(.easeInOut(duration: 0.15)) {
                isScreenSaverActive = false
            }
        }
    }

    private func updateKeyboardHeight(from notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let appScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let windowScene = appScenes.first(where: { $0.activationState == .foregroundActive }) ?? appScenes.first
        let keyWindow = windowScene?.windows.first(where: \.isKeyWindow) ?? windowScene?.windows.first
        let windowBounds = keyWindow?.bounds ?? windowScene?.screen.bounds ?? .zero
        let screenHeight = windowBounds.height
        let bottomInset = keyWindow?.safeAreaInsets.bottom ?? 0
        guard screenHeight > 0 else { return }
        let localEndFrame = keyWindow?.convert(endFrame, from: nil) ?? endFrame
        let overlap = windowBounds.maxY - localEndFrame.minY
        let nextHeight: CGFloat
        if overlap <= 1 || localEndFrame.height <= 0 {
            nextHeight = 0
        } else {
            nextHeight = max(0, overlap - bottomInset)
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

    private func topStatusBar(isLandscape: Bool) -> some View {
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
                if externalDisplay.isRenderingOnExternalDisplay {
                    Button {
                        showExternalMousepad.toggle()
                    } label: {
                        Image(systemName: showExternalMousepad ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(showExternalMousepad ? .blue : .secondary)
                    .accessibilityLabel(showExternalMousepad ? "Hide Mousepad" : "Show Mousepad")
                } else {
                    HingeSensorView(posture: $posture)
                }
            }

            if externalDisplay.isExternalDisplayConnected {
                Button {
                    externalDisplay.routeToExternalDisplay.toggle()
                } label: {
                    Image(systemName: externalDisplay.isRenderingOnExternalDisplay ? "tv.fill" : "iphone")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(externalDisplay.isRenderingOnExternalDisplay ? .blue : .secondary)
                .accessibilityLabel(externalDisplay.isRenderingOnExternalDisplay ? "Switch Display to iPhone" : "Route Display to External Monitor")
            }

            Spacer(minLength: 4)

            Button {
                showPerformanceHUD.toggle()
            } label: {
                Image(systemName: showPerformanceHUD ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(showPerformanceHUD ? .blue : .secondary)
            .accessibilityLabel(showPerformanceHUD ? "Hide Performance HUD" : "Show Performance HUD")

            Button {
                activateScreenSaver()
            } label: {
                Image(systemName: "moon.stars.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel("OLED Screen Saver")

            Button {
                showDebugConsole = true
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel("Debug & Telemetry Logs")

            Button {
                if activeTab == .display {
                    focusSoftwareKeyboard.toggle()
                } else {
                    focusTerminalKeyboard.toggle()
                }
            } label: {
                let kbdOn = (activeTab == .display) ? focusSoftwareKeyboard : focusTerminalKeyboard
                Image(systemName: kbdOn ? "keyboard.fill" : "keyboard")
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

            Button(role: .destructive) {
                if isScreenSaverActive {
                    deactivateScreenSaver()
                }
                focusSoftwareKeyboard = false
                focusTerminalKeyboard = false
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
        .padding(.vertical, isLandscape ? 3 : 6)
        .background(.ultraThinMaterial)
    }

    private func sendDisplayCtrlChord(_ keyUsage: UInt8) {
        HengeVMBridge.shared.sendHidKeyUsage(0xE0, pressed: true)
        HengeVMBridge.shared.sendHidKeyUsage(keyUsage, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            HengeVMBridge.shared.sendHidKeyUsage(keyUsage, pressed: false)
            if !ctrlActive {
                HengeVMBridge.shared.sendHidKeyUsage(0xE0, pressed: false)
            }
        }
    }

    private func compactModifierStrip(compact: Bool = false) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 6 : 8) {
                hidPulseButton("PgUp", usage: 0x4B, compact: compact)
                hidPulseButton("PgDn", usage: 0x4E, compact: compact)
                hidPulseButton("Home", usage: 0x4A, compact: compact)
                hidPulseButton("End", usage: 0x4D, compact: compact)
                hidPulseButton("Ins", usage: 0x49, repeatable: false, compact: compact)
                hidPulseButton("Del", usage: 0x4C, compact: compact)
                modifierToggle("Ctrl", isOn: $ctrlActive, compact: compact)
                modifierToggle("Shift", isOn: $shiftActive, compact: compact)
                modifierToggle("Alt", isOn: $altActive, compact: compact)
                Button("Paste") {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        HengeVMBridge.shared.pushHostClipboard(clip)
                        pendingPaste = PasteRequest(text: clip)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .mini : .small)
                .font(.caption.monospaced())
                Button("^C") { sendDisplayCtrlChord(0x06) }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .mini : .small)
                    .font(.caption.monospaced())
                Button("^D") { sendDisplayCtrlChord(0x07) }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .mini : .small)
                    .font(.caption.monospaced())
                Button("^Z") { sendDisplayCtrlChord(0x1D) }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .mini : .small)
                    .font(.caption.monospaced())
                hidPulseButton("Esc", usage: 0x29, compact: compact)
                hidPulseButton("Tab", usage: 0x2B, compact: compact)
                hidPulseButton("Bck", usage: 0x2A, compact: compact)
                hidPulseButton("Space", usage: 0x2C, compact: compact)
                hidPulseButton("↑", usage: 0x52, compact: compact)
                hidPulseButton("↓", usage: 0x51, compact: compact)
                hidPulseButton("←", usage: 0x50, compact: compact)
                hidPulseButton("→", usage: 0x4F, compact: compact)
                hidPulseButton("F1", usage: 0x3A, repeatable: false, compact: compact)
                hidPulseButton("F2", usage: 0x3B, repeatable: false, compact: compact)
                hidPulseButton("F3", usage: 0x3C, repeatable: false, compact: compact)
                hidPulseButton("F4", usage: 0x3D, repeatable: false, compact: compact)
                hidPulseButton("F5", usage: 0x3E, repeatable: false, compact: compact)
                hidPulseButton("F6", usage: 0x3F, repeatable: false, compact: compact)
                hidPulseButton("F7", usage: 0x40, repeatable: false, compact: compact)
                hidPulseButton("F8", usage: 0x41, repeatable: false, compact: compact)
                hidPulseButton("F9", usage: 0x42, repeatable: false, compact: compact)
                hidPulseButton("F10", usage: 0x43, repeatable: false, compact: compact)
                hidPulseButton("F11", usage: 0x44, repeatable: false, compact: compact)
                hidPulseButton("F12", usage: 0x45, repeatable: false, compact: compact)
                modifierToggle("Super", isOn: $superActive, compact: compact)
                hidPulseButton("Caps", usage: 0x39, repeatable: false, compact: compact)
                hidPulseButton("Prnt", usage: 0x46, repeatable: false, compact: compact)
                hidPulseButton("ScrLk", usage: 0x47, repeatable: false, compact: compact)
                hidPulseButton("Pause", usage: 0x48, repeatable: false, compact: compact)
                hidPulseButton("Menu", usage: 0x65, repeatable: false, compact: compact)
                Button("CAD") {
                    HengeVMBridge.shared.sendCtrlAltDel()
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .mini : .small)
                .font(.caption.monospaced())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 4 : 7)
        }
        .background(.ultraThinMaterial)
    }

    private func landscapeDeckWidth(totalWidth: CGFloat) -> CGFloat {
        if isSoftwareKeyboardVisible {
            return min(max(totalWidth * 0.50, 280), 390)
        }
        return min(max(totalWidth * 0.42, 260), 360)
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

    private func externalMonitorControlDeck(isLandscape: Bool) -> some View {
        let compact = isSoftwareKeyboardVisible || isLandscape
        return VStack(spacing: compact ? 4 : 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("External Monitor · \(externalDisplay.activeResolutionLabel)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Menu {
                    ForEach(ExternalDisplayResolutionPreset.allCases) { preset in
                        Button {
                            externalDisplay.resolutionPreset = preset
                        } label: {
                            if externalDisplay.resolutionPreset == preset {
                                Label(preset.label, systemImage: "checkmark")
                            } else {
                                Text(preset.label)
                            }
                        }
                    }
                } label: {
                    Label(externalDisplay.resolutionPreset.shortLabel, systemImage: "aspectratio")
                        .font(.caption2.monospaced())
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.top, compact ? 4 : 8)

            if showExternalMousepad {
                deck6x3Grid(compact: compact)
                    .padding(.horizontal, 10)
                    .padding(.bottom, showModifierBar ? 2 : (compact ? 4 : 10))
            } else {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if !compact {
                        Text("Mousepad hidden")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Button("Show Mousepad") {
                            showExternalMousepad = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showModifierBar {
                compactModifierStrip(compact: compact)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06))
    }

    private func clamshellInputDeck(includeModifierStrip: Bool, compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 6) {
            if includeModifierStrip {
                compactModifierStrip(compact: compact)
            }

            deck6x3Grid(compact: compact)
                .padding(.horizontal, 10)
                .padding(.bottom, compact ? 4 : 8)
        }
        .background(Color(white: 0.08))
    }

    private func deck6x3Grid(compact: Bool) -> some View {
        GeometryReader { padGeo in
            let gap: CGFloat = compact ? 4 : 6
            let w = max(padGeo.size.width, 60)
            let h = max(padGeo.size.height, 48)
            let colW = max((w - gap * 5) / 6, 10)
            let doubleW = colW * 2 + gap
            let rowH = max((h - gap * 2) / 3, 12)
            let topH = rowH * 2 + gap

            VStack(spacing: gap) {
                // Top 2 rows: [2x2 Left Keys] [2x2 Square Trackpad] [2x2 Arrow Cluster]
                HStack(spacing: gap) {
                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            deckHoldKey("Esc", usage: 0x29, width: colW, height: rowH, compact: compact)
                            deckHoldKey("Tab", usage: 0x2B, width: colW, height: rowH, compact: compact)
                        }
                        HStack(spacing: gap) {
                            deckHoldKey("Bck", usage: 0x2A, width: colW, height: rowH, compact: compact)
                            deckModifierToggle("Alt", isOn: $altActive, width: colW, height: rowH, compact: compact)
                        }
                    }
                    .frame(width: doubleW, height: topH)

                    RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous)
                        .fill(Color(white: 0.14))
                        .overlay(
                            VStack(spacing: compact ? 0 : 2) {
                                Text("Trackpad")
                                    .font(compact ? .caption2.weight(.medium) : .footnote.weight(.medium))
                                    .foregroundStyle(.secondary)
                                if !compact {
                                    Text("Drag · Tap · 2F Scroll")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                            }
                            .padding(.horizontal, 4)
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
                                        buttons: effectiveMouseButtons,
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
                                        buttons: effectiveMouseButtons,
                                        wheel: wheelStep
                                    )
                                }
                            )
                        )
                        .frame(width: doubleW, height: topH)

                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            deckHoldKey("↑", usage: 0x52, width: colW, height: rowH, compact: compact)
                            deckHoldKey("↓", usage: 0x51, width: colW, height: rowH, compact: compact)
                        }
                        HStack(spacing: gap) {
                            deckHoldKey("←", usage: 0x50, width: colW, height: rowH, compact: compact)
                            deckHoldKey("→", usage: 0x4F, width: colW, height: rowH, compact: compact)
                        }
                    }
                    .frame(width: doubleW, height: topH)
                }
                .frame(width: w, height: topH)

                // Bottom row: [Space (1x)] [L (2x)] [R (2x)] [Enter (1x)]
                HStack(spacing: gap) {
                    deckHoldKey("␣", usage: 0x2C, width: colW, height: rowH, compact: compact)

                    MouseHoldButton(label: "L", buttonMask: 1, compact: compact, fillContainer: true) { pressed in
                        setHeldMouseButton(1, pressed: pressed)
                    }
                    .frame(width: doubleW, height: rowH)

                    MouseHoldButton(label: "R", buttonMask: 2, compact: compact, fillContainer: true) { pressed in
                        setHeldMouseButton(2, pressed: pressed)
                    }
                    .frame(width: doubleW, height: rowH)

                    deckHoldKey("↵", usage: 0x28, width: colW, height: rowH, compact: compact)
                }
                .frame(width: w, height: rowH)
            }
            .frame(width: w, height: h)
        }
    }

    private func deckHoldKey(_ label: String, usage: UInt8, width: CGFloat, height: CGFloat, compact: Bool) -> some View {
        HidHoldKeyButton(
            label: label,
            usage: usage,
            repeatable: true,
            compact: compact,
            fillContainer: true
        ) {
            releaseActiveModifiers()
        }
        .frame(width: width, height: height)
    }

    private func deckModifierToggle(_ label: String, isOn: Binding<Bool>, width: CGFloat, height: CGFloat, compact: Bool) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(compact ? .caption2.monospaced().weight(.medium) : .caption.monospaced().weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.22))
                )
                .foregroundStyle(isOn.wrappedValue ? .white : .primary)
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
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
            buttons: effectiveMouseButtons,
            wheel: 0
        )
    }

    private func pulseMouseButton(_ mask: UInt8) {
        let downMask = effectiveMouseButtons | mask
        HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: downMask, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            HengeVMBridge.shared.sendPointerNormX(cursorNormX, normY: cursorNormY, buttons: effectiveMouseButtons, wheel: 0)
        }
    }

    private func hidPulseButton(_ label: String, usage: UInt8, repeatable: Bool = true, compact: Bool = false) -> some View {
        HidHoldKeyButton(label: label, usage: usage, repeatable: repeatable, compact: compact) {
            releaseActiveModifiers()
        }
    }

    private func modifierToggle(_ label: String, isOn: Binding<Bool>, compact: Bool = false) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.button)
            .controlSize(compact ? .mini : .small)
            .font(.caption.monospaced())
    }
}

/// Hold-capable Left/Right mouse button for the Split Deck:
/// immediately asserts button-down on touch and holds it through simultaneous
/// trackpad dragging, with a minimum 25 ms dwell on quick taps.
private struct MouseHoldButton: View {
    let label: String
    let buttonMask: UInt8
    var compact: Bool = false
    var fillContainer: Bool = false
    let onPressChanged: (Bool) -> Void

    @State private var isPressed: Bool = false
    @State private var pressedAt: Date?

    var body: some View {
        Text(label)
            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: fillContainer ? .infinity : nil)
            .padding(.vertical, fillContainer ? 0 : (compact ? 5 : 8))
            .background(
                RoundedRectangle(cornerRadius: fillContainer ? 7 : 8, style: .continuous)
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
    var compact: Bool = false
    var fillContainer: Bool = false
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
                compact: compact,
                fillContainer: fillContainer,
                didHandlePress: $didHandlePress,
                onRelease: onRelease
            )
        )
    }
}

private struct HidHoldKeyButtonStyle: ButtonStyle {
    let usage: UInt8
    let repeatable: Bool
    let compact: Bool
    let fillContainer: Bool
    @Binding var didHandlePress: Bool
    let onRelease: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        HidHoldKeyBody(
            configuration: configuration,
            usage: usage,
            repeatable: repeatable,
            compact: compact,
            fillContainer: fillContainer,
            didHandlePress: $didHandlePress,
            onRelease: onRelease
        )
    }
}

private struct HidHoldKeyBody: View {
    let configuration: ButtonStyle.Configuration
    let usage: UInt8
    let repeatable: Bool
    let compact: Bool
    let fillContainer: Bool
    @Binding var didHandlePress: Bool
    let onRelease: () -> Void

    @State private var isHeld: Bool = false
    @State private var repeatTask: Task<Void, Never>?

    private static let pulseDwellNs: UInt64 = 20_000_000     // 20 ms key-down pulse (< 250 ms guest EV_REP)
    private static let initialDelayNs: UInt64 = 330_000_000  // + 20 ms pulse = 350 ms before first repeat
    private static let repeatGapNs: UInt64 = 45_000_000      // + 20 ms pulse = 65 ms period (~15.4 Hz)

    var body: some View {
        configuration.label
            .font(fillContainer ? (compact ? .caption2.monospaced().weight(.medium) : .caption.monospaced().weight(.medium)) : .caption.monospaced())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: fillContainer ? .infinity : nil, maxHeight: fillContainer ? .infinity : nil)
            .padding(.horizontal, fillContainer ? 2 : (compact ? 8 : 10))
            .padding(.vertical, fillContainer ? 0 : (compact ? 4 : 6))
            .background(
                RoundedRectangle(cornerRadius: fillContainer ? 7 : 6, style: .continuous)
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

/// Hidden `UITextView`-backed software keyboard responder shared by both the
/// Metal Display surface and the `ttyAMA0` terminal canvas.
///
/// Using `UITextView` (full `UITextInput` conformance) with a non-empty sentinel
/// buffer before the caret enables native iOS hold-to-repeat on `⌫` (Backspace),
/// while `keyboardType = .default` restores the native `🌐` language switcher
/// and left/right one-handed keyboards without enabling autocorrect or smart punctuation.
final class HengeSoftwareKeyboardProxyView: UITextView {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onPressesBegan: ((Set<UIPress>, UIPressesEvent?) -> Bool)?
    var onPressesEnded: ((Set<UIPress>, UIPressesEvent?) -> Bool)?
    var onResignedFirstResponder: (() -> Void)?

    private static let sentinelText = "--------------------------------"
    private static let sentinelCursor = NSRange(location: 16, length: 0)
    private var isRestoringSentinel = false
    private var isHandlingMutation = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configureProxy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureProxy()
    }

    private func configureProxy() {
        isUserInteractionEnabled = false
        alpha = 0.01
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        isEditable = true
        isSelectable = true
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0

        keyboardType = .default
        keyboardAppearance = .dark
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []

        restoreSentinelIfNeeded(force: true)
    }

    override var hasText: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            restoreSentinelIfNeeded(force: true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        onResignedFirstResponder?()
        return ok
    }

    override func insertText(_ text: String) {
        if isHandlingMutation {
            super.insertText(text)
            return
        }
        guard !text.isEmpty else { return }
        if markedTextRange != nil {
            super.unmarkText()
        }
        onInsertText?(text)
        restoreSentinelIfNeeded(force: false)
    }

    override func deleteBackward() {
        if isHandlingMutation || markedTextRange != nil {
            super.deleteBackward()
            return
        }
        isHandlingMutation = true
        onDeleteBackward?()
        super.deleteBackward()
        isHandlingMutation = false
        if selectedRange.location <= 6 || (super.text?.count ?? 0) <= 10 {
            restoreSentinelIfNeeded(force: true)
        }
    }

    override func replace(_ range: UITextRange, withText text: String) {
        if isHandlingMutation || markedTextRange != nil {
            super.replace(range, withText: text)
            return
        }
        isHandlingMutation = true
        if text.isEmpty {
            onDeleteBackward?()
        } else {
            onInsertText?(text)
        }
        isHandlingMutation = false
        restoreSentinelIfNeeded(force: true)
    }

    private func restoreSentinelIfNeeded(force: Bool) {
        guard !isRestoringSentinel else { return }
        isRestoringSentinel = true
        defer { isRestoringSentinel = false }
        if force || super.text != Self.sentinelText {
            super.text = Self.sentinelText
        }
        if force || super.selectedRange != Self.sentinelCursor {
            super.selectedRange = Self.sentinelCursor
        }
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
}

final class MetalDisplaySurfaceView: UIView, @MainActor UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    var onFocusChanged: ((Bool) -> Void)?
    var onCharacterTyped: (() -> Void)?
    var onPointerMoved: ((Double, Double) -> Void)?
    /// Controls whether the hidden `SoftwareKeyboardInputProxyView` is first
    /// responder (showing the iOS software keyboard). When `true` (suppressed),
    /// the proxy resigns so UIKit collapses the keyboard safe area to 0, while
    /// `MetalDisplaySurfaceView` itself remains first responder for Bluetooth
    /// hardware keyboard `pressesBegan` events without triggering a keyboard.
    var isActiveDisplayTab: Bool = true {
        didSet {
            guard oldValue != isActiveDisplayTab else { return }
            scheduleSyncResponderState()
        }
    }
    var suppressSoftwareKeyboard: Bool = true {
        didSet {
            guard oldValue != suppressSoftwareKeyboard else { return }
            scheduleSyncResponderState()
        }
    }
    var allowGuestResize: Bool = true {
        didSet {
            if allowGuestResize && !oldValue {
                lastSentGuestWidth = 0
                lastSentGuestHeight = 0
                scheduleGuestDisplayResize()
            }
        }
    }
    private let softwareKeyboardProxy = HengeSoftwareKeyboardProxyView(
        frame: CGRect(x: 0, y: 0, width: 1, height: 1),
        textContainer: nil
    )
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
        if !isActiveDisplayTab {
            if softwareKeyboardProxy.isFirstResponder {
                isProgrammaticResponderChange = true
                _ = softwareKeyboardProxy.resignFirstResponder()
                isProgrammaticResponderChange = false
            }
            if isFirstResponder {
                _ = resignFirstResponder()
            }
            return
        }
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
        singleTap.delegate = self

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasRightClick(_:)))
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.numberOfTouchesRequired = 2
        singleTap.require(toFail: twoFingerTap)

        addGestureRecognizer(twoFingerTap)
        addGestureRecognizer(singleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCanvasPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)

        let editMenu = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenu)
        editMenuInteraction = editMenu

        let leftHold = UILongPressGestureRecognizer(target: self, action: #selector(handleCanvasLeftHold(_:)))
        leftHold.minimumPressDuration = 0.22
        leftHold.allowableMovement = 18
        leftHold.numberOfTouchesRequired = 1
        leftHold.delegate = self
        addGestureRecognizer(leftHold)

        let menuLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCanvasLongPress(_:)))
        menuLongPress.minimumPressDuration = 0.45
        menuLongPress.numberOfTouchesRequired = 2
        addGestureRecognizer(menuLongPress)

        // Indirect pointer (USB/Bluetooth mouse & iPad trackpad) fallback when GCMouse is not active.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleCanvasHover(_:)))
        addGestureRecognizer(hover)

        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(handleCanvasRightClick(_:)))
        secondaryClick.numberOfTapsRequired = 1
        secondaryClick.buttonMaskRequired = .secondary
        secondaryClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(secondaryClick)

        let indirectScroll = UIPanGestureRecognizer(target: self, action: #selector(handleIndirectScroll(_:)))
        indirectScroll.allowedScrollTypesMask = .all
        indirectScroll.allowedTouchTypes = []
        addGestureRecognizer(indirectScroll)
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
            // In iPhone portrait orientation, use 1024x768 (4:3, matching 2D UEFI GOP)
            // so opening Trackpad + Keyboard fills the full viewport height & width cleanly.
            // In landscape (rotated iPhone, iPad, external monitor), match the landscape aspect ratio.
            let safeBounds = win.bounds.inset(by: win.safeAreaInsets)
            let topBarOverhead: CGFloat = 44
            let targetW = max(safeBounds.width, 1)
            let targetH = max(safeBounds.height - topBarOverhead, 1)
            let clampedW: Int
            let clampedH: Int
            if targetH > targetW {
                clampedW = 1024
                clampedH = 768
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
        if HardwareInputManager.shared.isCapturingDisplayKeyboard {
            return true
        }
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.type == .indirectPointer && HardwareInputManager.shared.isCapturingDisplayMouse {
            return false
        }
        return true
    }

    private func normalizedPoint(_ pt: CGPoint) -> (Double, Double) {
        var fbW: UInt32 = 0
        var fbH: UInt32 = 0
        hengelinux_get_presented_fb_size(&fbW, &fbH)
        if fbW < 4 || fbH < 4 {
            fbW = UInt32(max(lastSentGuestWidth, 0))
            fbH = UInt32(max(lastSentGuestHeight, 0))
        }
        var nx: Double = 0.0
        var ny: Double = 0.0
        henge_map_touch_to_guest_norm(
            Double(pt.x),
            Double(pt.y),
            Double(bounds.width),
            Double(bounds.height),
            fbW,
            fbH,
            &nx,
            &ny
        )
        onPointerMoved?(nx, ny)
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
        if gr.buttonMaskRequired == .secondary && HardwareInputManager.shared.isCapturingDisplayMouse {
            return
        }
        let (nx, ny) = normalizedPoint(gr.location(in: self))
        HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 2, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 0, wheel: 0)
        }
    }

    @objc private func handleCanvasHover(_ gr: UIHoverGestureRecognizer) {
        guard !HardwareInputManager.shared.isCapturingDisplayMouse else { return }
        guard gr.state == .began || gr.state == .changed else { return }
        let (nx, ny) = normalizedPoint(gr.location(in: self))
        HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 0, wheel: 0)
    }

    @objc private func handleIndirectScroll(_ gr: UIPanGestureRecognizer) {
        guard !HardwareInputManager.shared.isCapturingDisplayMouse else { return }
        let (nx, ny) = normalizedPoint(gr.location(in: self))
        let vy = gr.translation(in: self).y
        let wheelStep = Int8(max(-5, min(5, Int(vy / 20.0))))
        if wheelStep != 0 {
            HengeVMBridge.shared.sendPointerNormX(nx, normY: ny, buttons: 0, wheel: wheelStep)
            gr.setTranslation(.zero, in: self)
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
            var fbW: UInt32 = 0
            var fbH: UInt32 = 0
            hengelinux_get_presented_fb_size(&fbW, &fbH)
            let aspect: Double = (fbW >= 4 && fbH >= 4)
                ? (Double(fbW) / Double(fbH))
                : (4.0 / 3.0)
            let span = Double(max(min(w, h), 1))
            let gain = 1.25
            let dx = (Double(delta.x) / span) * gain
            let dy = (Double(delta.y) / span) * gain * aspect
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
    var isActiveDisplayTab: Bool = true
    var suppressSoftwareKeyboard: Bool
    var allowGuestResize: Bool = true
    var layoutTrigger: String = ""
    var pendingPasteID: UUID?
    var pendingPasteText: String?
    var onPasteConsumed: (() -> Void)?
    var onCharacterTyped: (() -> Void)?
    var onPointerMoved: ((Double, Double) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MetalDisplaySurfaceView {
        let view = MetalDisplaySurfaceView(frame: .zero)
        view.isActiveDisplayTab = isActiveDisplayTab
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
        view.onPointerMoved = onPointerMoved
        if let metalLayer = view.metalLayer {
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            ExternalDisplayManager.shared.registerLocalDisplayLayer(metalLayer)
        }
        return view
    }

    func updateUIView(_ uiView: MetalDisplaySurfaceView, context: Context) {
        _ = lifecycle.isPaused
        uiView.onCharacterTyped = onCharacterTyped
        uiView.onPointerMoved = onPointerMoved
        uiView.allowGuestResize = allowGuestResize
        uiView.isActiveDisplayTab = isActiveDisplayTab
        uiView.suppressSoftwareKeyboard = suppressSoftwareKeyboard
        if context.coordinator.lastLayoutTrigger != layoutTrigger {
            context.coordinator.lastLayoutTrigger = layoutTrigger
            DispatchQueue.main.async {
                uiView.setNeedsLayout()
            }
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
        ExternalDisplayManager.shared.unregisterLocalDisplayLayer(uiView.metalLayer)
    }
}

/// Passive touch observer (`hitTest` always returns `nil`) so auto-dim timers
/// reset on every touch without intercepting any gestures or controls.
private final class TouchActivityObserverView: UIView {
    var onTouch: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches {
            onTouch?()
        }
        return nil
    }
}

private struct TouchActivityObserverRepresentable: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> TouchActivityObserverView {
        let view = TouchActivityObserverView(frame: .zero)
        view.backgroundColor = .clear
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ uiView: TouchActivityObserverView, context: Context) {
        uiView.onTouch = onTouch
    }
}

/// Pure `#000000` OLED burn-in protection overlay with a drifting ultra-dim
/// status readout that keeps iOS active (unthrottled) while protecting the panel.
private struct OLEDScreenSaverOverlayView: View {
    let externalMonitorLabel: String?
    let onWake: () -> Void

    @State private var driftIndex: Int = 0
    @State private var now: Date = Date()
    @State private var showWakeHintPulse: Bool = false

    private let driftTimer = Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()

    private static let anchorPositions: [(x: CGFloat, y: CGFloat)] = [
        (0.50, 0.30),
        (0.32, 0.45),
        (0.68, 0.58),
        (0.35, 0.70),
        (0.65, 0.36),
        (0.50, 0.52),
        (0.36, 0.28),
        (0.64, 0.72),
    ]

    private var thermalLabel: String? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return nil
        case .fair: return "Thermal: Fair"
        case .serious: return "Thermal: Serious"
        case .critical: return "Thermal: Critical"
        @unknown default: return nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let anchor = Self.anchorPositions[driftIndex % Self.anchorPositions.count]
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 6) {
                    Text(now, format: .dateTime.hour().minute())
                        .font(.system(size: 30, weight: .ultraLight, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.24))

                    Text(externalMonitorLabel ?? "HengeLinux VM Active")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color.white.opacity(0.20))

                    if let thermal = thermalLabel {
                        Text(thermal)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.orange.opacity(0.45))
                    }

                    Text("Double-tap to wake")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(showWakeHintPulse ? 0.45 : 0.14))
                        .padding(.top, 4)
                }
                .position(
                    x: geo.size.width * anchor.x,
                    y: geo.size.height * anchor.y
                )
                .animation(.easeInOut(duration: 1.2), value: driftIndex)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onWake()
            }
            .onTapGesture(count: 1) {
                showWakeHintPulse = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showWakeHintPulse = false
                }
            }
        }
        .ignoresSafeArea()
        .onReceive(driftTimer) { tick in
            now = tick
            driftIndex = (driftIndex + 1) % Self.anchorPositions.count
        }
    }
}

/// Read-only UIKit monospace log viewer (`UITextView` on TextKit 1) used by
/// `DebugConsoleSheetView` to avoid SwiftUI `ScrollViewReader` AttributeGraph
/// cycles and TextKit 2 viewport scroll jumps during live log streaming.
struct MonospaceLogTextView: UIViewRepresentable {
    let text: String
    let placeholder: String
    let fontSize: CGFloat
    let autoScroll: Bool

    final class Coordinator {
        var lastText: String = ""
        var lastAutoScroll: Bool = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .black
        tv.indicatorStyle = .white
        tv.alwaysBounceVertical = true
        tv.layoutManager.allowsNonContiguousLayout = false
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textColor = text.isEmpty ? .secondaryLabel : .systemGreen
        tv.text = text.isEmpty ? placeholder : text
        context.coordinator.lastText = text
        context.coordinator.lastAutoScroll = autoScroll
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let textChanged = (context.coordinator.lastText != text)
        let autoScrollEnabledNow = (!context.coordinator.lastAutoScroll && autoScroll)
        context.coordinator.lastAutoScroll = autoScroll
        guard textChanged || autoScrollEnabledNow else { return }
        let previousOffset = uiView.contentOffset
        if textChanged {
            context.coordinator.lastText = text
            uiView.textColor = text.isEmpty ? .secondaryLabel : .systemGreen
            uiView.text = text.isEmpty ? placeholder : text
        }
        if autoScroll && !text.isEmpty && !uiView.isDragging && !uiView.isTracking {
            uiView.layoutManager.ensureLayout(for: uiView.textContainer)
            let bottomY = max(
                -uiView.adjustedContentInset.top,
                uiView.contentSize.height - uiView.bounds.height + uiView.adjustedContentInset.bottom
            )
            uiView.setContentOffset(CGPoint(x: 0, y: bottomY), animated: false)
        } else if !autoScroll && textChanged {
            uiView.setContentOffset(previousOffset, animated: false)
        }
    }
}

/// Hold-to-repeat serial terminal button that preserves horizontal ScrollView gestures.
private struct TermRepeatKeyButton: View {
    let label: String
    let action: () -> Void

    @State private var didHandlePress: Bool = false

    var body: some View {
        Button {
            if !didHandlePress {
                action()
            }
            didHandlePress = false
        } label: {
            Text(label)
        }
        .buttonStyle(TermRepeatKeyButtonStyle(didHandlePress: $didHandlePress, action: action))
    }
}

private struct TermRepeatKeyButtonStyle: ButtonStyle {
    @Binding var didHandlePress: Bool
    let action: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        TermRepeatKeyBody(configuration: configuration, didHandlePress: $didHandlePress, action: action)
    }
}

private struct TermRepeatKeyBody: View {
    let configuration: ButtonStyle.Configuration
    @Binding var didHandlePress: Bool
    let action: () -> Void

    @State private var delayTask: DispatchWorkItem?
    @State private var repeatTimer: Timer?

    var body: some View {
        configuration.label
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.accentColor.opacity(0.35) : Color(white: 0.22))
            )
            .foregroundStyle(.primary)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    didHandlePress = true
                    action()
                    startRepeat()
                } else {
                    stopRepeat()
                }
            }
            .onDisappear {
                stopRepeat()
            }
    }

    private func startRepeat() {
        stopRepeat()
        let work = DispatchWorkItem {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.065, repeats: true) { _ in
                Task { @MainActor in
                    action()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            repeatTimer = timer
        }
        delayTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func stopRepeat() {
        delayTask?.cancel()
        delayTask = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

/// Interactive VT100/xterm-256color PL011 (`ttyAMA0`) terminal tab embedded in `SessionView`.
private struct InteractiveSerialTerminalView: View {
    let isActiveTab: Bool
    let showModifierBar: Bool
    let compactBar: Bool
    @Binding var focusKeyboard: Bool
    let onOpenLogs: () -> Void

    @AppStorage("serialTerminalFontSize") private var fontSize: Double = 10.5
    @State private var stickyCtrl: Bool = false
    @State private var stickyAlt: Bool = false
    @State private var stickyShift: Bool = false
    @State private var gridCols: Int = 80
    @State private var gridRows: Int = 24
    @State private var syncedCols: Int = 0
    @State private var syncedRows: Int = 0
    @State private var inAlternateScreen: Bool = false
    @State private var pendingCommand: SerialTerminalCommand?

    private var needsSizeSync: Bool {
        syncedCols != gridCols || syncedRows != gridRows
    }

    var body: some View {
        VStack(spacing: 0) {
            SerialTerminalRepresentable(
                isActiveTab: isActiveTab,
                focusKeyboard: $focusKeyboard,
                stickyCtrl: $stickyCtrl,
                stickyAlt: $stickyAlt,
                stickyShift: $stickyShift,
                fontSize: CGFloat(fontSize),
                pendingCommand: pendingCommand,
                onCommandConsumed: {
                    pendingCommand = nil
                },
                onGridSizeChanged: { cols, rows in
                    gridCols = cols
                    gridRows = rows
                },
                onGuestSizeSynced: { cols, rows in
                    syncedCols = cols
                    syncedRows = rows
                },
                onAltScreenChanged: { inAlt in
                    inAlternateScreen = inAlt
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            if showModifierBar {
                Divider()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: compactBar ? 6 : 8) {
                        TermRepeatKeyButton(label: "PgUp") {
                            pendingCommand = .sendSequence(UUID(), "\u{1B}[5~")
                        }
                        TermRepeatKeyButton(label: "PgDn") {
                            pendingCommand = .sendSequence(UUID(), "\u{1B}[6~")
                        }
                        TermRepeatKeyButton(label: "Home") {
                            pendingCommand = .sendSequence(UUID(), "\u{1B}[H")
                        }
                        TermRepeatKeyButton(label: "End") {
                            pendingCommand = .sendSequence(UUID(), "\u{1B}[F")
                        }
                        termSeqButton("Ins", seq: "\u{1B}[2~")
                        TermRepeatKeyButton(label: "Del") {
                            pendingCommand = .sendSequence(UUID(), "\u{1B}[3~")
                        }
                        termModifierButton("Ctrl", isOn: $stickyCtrl)
                        termModifierButton("Shift", isOn: $stickyShift)
                        termModifierButton("Alt", isOn: $stickyAlt)
                        Button("Paste") {
                            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                                pendingCommand = .paste(UUID(), clip)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(compactBar ? .mini : .small)
                        .font(.caption.monospaced())
                        termByteButton("^C", byte: 0x03)
                        termByteButton("^D", byte: 0x04)
                        termByteButton("^Z", byte: 0x1A)
                        TermRepeatKeyButton(label: "Esc") {
                            pendingCommand = .sendByte(UUID(), 0x1B)
                        }
                        TermRepeatKeyButton(label: "Tab") {
                            pendingCommand = .sendByte(UUID(), 0x09)
                        }
                        TermRepeatKeyButton(label: "Bck") {
                            pendingCommand = .sendByte(UUID(), 0x7F)
                        }
                        TermRepeatKeyButton(label: "Space") {
                            pendingCommand = .sendByte(UUID(), 0x20)
                        }
                        termArrowButton("↑", dir: "A")
                        termArrowButton("↓", dir: "B")
                        termArrowButton("←", dir: "D")
                        termArrowButton("→", dir: "C")
                        termSeqButton("F1", seq: "\u{1B}OP")
                        termSeqButton("F2", seq: "\u{1B}OQ")
                        termSeqButton("F3", seq: "\u{1B}OR")
                        termSeqButton("F4", seq: "\u{1B}OS")
                        termSeqButton("F5", seq: "\u{1B}[15~")
                        termSeqButton("F6", seq: "\u{1B}[17~")
                        termSeqButton("F7", seq: "\u{1B}[18~")
                        termSeqButton("F8", seq: "\u{1B}[19~")
                        termSeqButton("F9", seq: "\u{1B}[20~")
                        termSeqButton("F10", seq: "\u{1B}[21~")
                        termSeqButton("F11", seq: "\u{1B}[23~")
                        termSeqButton("F12", seq: "\u{1B}[24~")
                        Button("CAD") {
                            HengeVMBridge.shared.sendCtrlAltDel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(compactBar ? .mini : .small)
                        .font(.caption.monospaced())

                        Button("Fit \(gridCols)×\(gridRows)") {
                            syncedCols = gridCols
                            syncedRows = gridRows
                            pendingCommand = .sendSequence(
                                UUID(),
                                "unset LINES COLUMNS; export TERM=xterm-256color; stty rows \(gridRows) cols \(gridCols)\r"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(compactBar ? .mini : .small)
                        .font(.caption.monospaced())
                        .tint(inAlternateScreen ? .secondary : (needsSizeSync ? .orange : .green))
                        .disabled(inAlternateScreen)

                        Button("Copy") {
                            pendingCommand = .copyScreen(UUID())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(compactBar ? .mini : .small)
                        .font(.caption.monospaced())

                        Button("A-") {
                            fontSize = max(7.0, ((fontSize - 0.5) * 2.0).rounded() / 2.0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(compactBar ? .mini : .small)
                        .font(.caption.monospaced())

                        Button("A+") {
                            fontSize = min(20.0, ((fontSize + 0.5) * 2.0).rounded() / 2.0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(compactBar ? .mini : .small)
                        .font(.caption.monospaced())

                        Button("Clear") {
                            pendingCommand = .clear(UUID())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(compactBar ? .mini : .small)
                        .font(.caption.monospaced())

                        Button("Logs") {
                            onOpenLogs()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(compactBar ? .mini : .small)
                        .font(.caption.monospaced())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, compactBar ? 4 : 7)
                }
                .background(.ultraThinMaterial)
            }
        }
    }

    private func termModifierButton(_ title: String, isOn: Binding<Bool>) -> some View {
        Button(title) {
            isOn.wrappedValue.toggle()
        }
        .buttonStyle(.bordered)
        .controlSize(compactBar ? .mini : .small)
        .font(.caption.monospaced())
        .tint(isOn.wrappedValue ? .blue : .secondary)
    }

    private func termByteButton(_ title: String, byte: UInt8) -> some View {
        Button(title) {
            pendingCommand = .sendByte(UUID(), byte)
        }
        .buttonStyle(.bordered)
        .controlSize(compactBar ? .mini : .small)
        .font(.caption.monospaced())
    }

    private func termSeqButton(_ title: String, seq: String) -> some View {
        Button(title) {
            pendingCommand = .sendSequence(UUID(), seq)
        }
        .buttonStyle(.bordered)
        .controlSize(compactBar ? .mini : .small)
        .font(.caption.monospaced())
    }

    private func termArrowButton(_ title: String, dir: Character) -> some View {
        TermRepeatKeyButton(label: title) {
            pendingCommand = .sendArrow(UUID(), dir)
        }
    }
}
