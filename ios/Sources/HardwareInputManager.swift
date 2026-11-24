// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GameController
import UIKit

/// Bridges physical USB / Bluetooth keyboards (`GCKeyboard`) and mice (`GCMouse`)
/// directly to the Linux guest HID pipeline so hardware peripherals work immediately
/// without enabling the on-screen software keyboard or relying on UIKit focus.
@MainActor
final class HardwareInputManager: ObservableObject {
    static let shared = HardwareInputManager()

    @Published private(set) var isHardwareKeyboardConnected: Bool = false
    @Published private(set) var isHardwareMouseConnected: Bool = false

    /// True while the VM Display tab is active and no modal/screen-saver owns input.
    var isDisplaySessionActive: Bool = false {
        didSet {
            if !isDisplaySessionActive && oldValue {
                releaseAllHardwareInputs()
            }
        }
    }

    var onActivity: (() -> Void)?
    var onRelativePointerMove: ((Double, Double) -> Void)?
    var onHardwareMouseButtonsChanged: ((UInt8) -> Void)?
    var onHardwareMouseWheel: ((Int8) -> Void)?
    var onHardwareKeyTyped: (() -> Void)?

    private var pressedKeyUsages: Set<UInt8> = []
    private var hardwareButtonMask: UInt8 = 0
    private var scrollResidualY: Double = 0.0
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// Returns true when `GCKeyboard` is actively capturing Display keystrokes,
    /// allowing `MetalDisplaySurfaceView` to suppress duplicate UIKit `pressesBegan`.
    var isCapturingDisplayKeyboard: Bool {
        isDisplaySessionActive && isHardwareKeyboardConnected
    }

    /// Returns true when `GCMouse` is actively capturing Display mouse input,
    /// avoiding duplicate UIKit hover/scroll events.
    var isCapturingDisplayMouse: Bool {
        isDisplaySessionActive && isHardwareMouseConnected
    }

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshConnectedDevices()
            }
        })
        observers.append(nc.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseHeldKeys()
                self?.refreshConnectedDevices()
            }
        })
        observers.append(nc.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshConnectedDevices()
            }
        })
        observers.append(nc.addObserver(
            forName: .GCMouseDidBecomeCurrent,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshConnectedDevices()
            }
        })
        observers.append(nc.addObserver(
            forName: .GCMouseDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseHeldMouseButtons()
                self?.refreshConnectedDevices()
            }
        })
        refreshConnectedDevices()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refreshConnectedDevices() {
        if let keyboard = GCKeyboard.coalesced {
            keyboard.handlerQueue = .main
            if !isHardwareKeyboardConnected {
                isHardwareKeyboardConnected = true
            }
            keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
                let raw = keyCode.rawValue
                MainActor.assumeIsolated {
                    self?.handleKeyChanged(rawUsage: raw, pressed: pressed)
                }
            }
        } else if isHardwareKeyboardConnected {
            isHardwareKeyboardConnected = false
        }

        var mice = GCMouse.mice()
        if let current = GCMouse.current, !mice.contains(where: { $0 === current }) {
            mice.append(current)
        }
        let hasMouse = !mice.isEmpty
        if isHardwareMouseConnected != hasMouse {
            isHardwareMouseConnected = hasMouse
        }
        for mouse in mice {
            mouse.handlerQueue = .main
            guard let mouseInput = mouse.mouseInput else { continue }
            mouseInput.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
                MainActor.assumeIsolated {
                    self?.handleMouseMoved(deltaX: deltaX, deltaY: deltaY)
                }
            }
            mouseInput.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    self?.handleMouseButton(mask: 1, pressed: pressed)
                }
            }
            mouseInput.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    self?.handleMouseButton(mask: 2, pressed: pressed)
                }
            }
            mouseInput.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    self?.handleMouseButton(mask: 4, pressed: pressed)
                }
            }
            mouseInput.scroll.valueChangedHandler = { [weak self] _, _, yValue in
                MainActor.assumeIsolated {
                    self?.handleScroll(deltaY: yValue)
                }
            }
        }
    }

    func releaseAllHardwareInputs() {
        releaseHeldKeys()
        releaseHeldMouseButtons()
        scrollResidualY = 0.0
    }

    private func releaseHeldKeys() {
        guard !pressedKeyUsages.isEmpty else { return }
        let held = pressedKeyUsages
        pressedKeyUsages.removeAll()
        for usage in held {
            HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: false)
        }
    }

    private func releaseHeldMouseButtons() {
        guard hardwareButtonMask != 0 else { return }
        hardwareButtonMask = 0
        onHardwareMouseButtonsChanged?(0)
    }

    private func handleKeyChanged(rawUsage: Int, pressed: Bool) {
        guard isDisplaySessionActive else { return }
        guard rawUsage >= 0x04 && rawUsage <= 0xE7 else { return }
        let usage = UInt8(rawUsage)
        onActivity?()
        if pressed {
            pressedKeyUsages.insert(usage)
            HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: true)
            if usage < 0xE0 {
                onHardwareKeyTyped?()
            }
        } else {
            pressedKeyUsages.remove(usage)
            HengeVMBridge.shared.sendHidKeyUsage(usage, pressed: false)
        }
    }

    private func handleMouseMoved(deltaX: Float, deltaY: Float) {
        guard isDisplaySessionActive else { return }
        if deltaX == 0 && deltaY == 0 { return }
        onActivity?()
        var fbW: UInt32 = 0
        var fbH: UInt32 = 0
        hengelinux_get_presented_fb_size(&fbW, &fbH)
        let w = Double(fbW >= 4 ? fbW : 1024)
        let h = Double(fbH >= 4 ? fbH : 768)
        // GCMouse uses Cartesian Y (+up); guest display normalized Y increases downward.
        let dx = Double(deltaX) / w
        let dy = -Double(deltaY) / h
        onRelativePointerMove?(dx, dy)
    }

    private func handleMouseButton(mask: UInt8, pressed: Bool) {
        guard isDisplaySessionActive else { return }
        onActivity?()
        let nextMask: UInt8 = pressed ? (hardwareButtonMask | mask) : (hardwareButtonMask & ~mask)
        guard nextMask != hardwareButtonMask else { return }
        hardwareButtonMask = nextMask
        onHardwareMouseButtonsChanged?(nextMask)
    }

    private func handleScroll(deltaY: Float) {
        guard isDisplaySessionActive else { return }
        let dy = Double(deltaY)
        guard abs(dy) >= 0.05 else { return }
        onActivity?()
        scrollResidualY += dy
        var step = Int(scrollResidualY.rounded(.towardZero))
        if step == 0 && abs(dy) >= 0.25 {
            step = dy > 0 ? 1 : -1
            scrollResidualY = 0.0
        } else {
            scrollResidualY -= Double(step)
        }
        let clamped = Int8(max(-5, min(5, step)))
        if clamped != 0 {
            onHardwareMouseWheel?(clamped)
        }
    }
}
