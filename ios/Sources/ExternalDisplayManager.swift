// SPDX-License-Identifier: GPL-3.0-or-later
import QuartzCore
import SwiftUI
import UIKit

/// User-selectable guest VirtIO-GPU KMS resolution targets for external monitors.
enum ExternalDisplayResolutionPreset: String, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case hd720 = "1280x720"
    case hd900 = "1600x900"
    case fhd1080 = "1920x1080"
    case qhd1440 = "2560x1440"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (Match Monitor)"
        case .hd720: return "1280 × 720 (720p)"
        case .hd900: return "1600 × 900 (900p)"
        case .fhd1080: return "1920 × 1080 (1080p)"
        case .qhd1440: return "2560 × 1440 (1440p)"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .hd720: return "720p"
        case .hd900: return "900p"
        case .fhd1080: return "1080p"
        case .qhd1440: return "1440p"
        }
    }

    func resolvedPixelSize(forNativeSize nativeSize: CGSize) -> (width: Int, height: Int) {
        switch self {
        case .hd720:
            return (1280, 720)
        case .hd900:
            return (1600, 900)
        case .fhd1080:
            return (1920, 1080)
        case .qhd1440:
            return (2560, 1440)
        case .auto:
            let rawW = max(Int(nativeSize.width.rounded()), 640)
            let rawH = max(Int(nativeSize.height.rounded()), 480)
            let landW = max(rawW, rawH)
            let landH = min(rawW, rawH)
            // Keep Auto within 1920x1200 so 2D VirtIO-GPU software blits stay
            // crisp and fluid on 4K monitors while matching exact aspect ratio.
            if landW <= 1920 && landH <= 1200 {
                return (max(landW & ~1, 640), max(landH & ~1, 480))
            }
            let scaleW = 1920.0 / Double(landW)
            let scaleH = 1200.0 / Double(landH)
            let scale = min(scaleW, scaleH)
            let w = max(Int((Double(landW) * scale).rounded()) & ~1, 640)
            let h = max(Int((Double(landH) * scale).rounded()) & ~1, 480)
            return (w, h)
        }
    }
}

/// Auto-dim timeout presets for the in-app OLED burn-in screen saver.
enum OLEDAutoDimOption: Int, CaseIterable, Identifiable, Sendable {
    case manualOnly = 0
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .manualOnly: return "Manual Only"
        case .oneMinute: return "1 Minute"
        case .threeMinutes: return "3 Minutes"
        case .fiveMinutes: return "5 Minutes"
        }
    }
}

/// Full-screen `CAMetalLayer`-backed surface rendered directly on an external
/// USB-C / HDMI / AirPlay display scene.
final class ExternalDisplaySurfaceView: UIView {
    var onGeometryChanged: ((CGSize) -> Void)?
    private var lastReportedPixelSize: CGSize = .zero

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    var metalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        backgroundColor = .black
        isOpaque = true
        if let metalLayer {
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
        }
    }

    override var bounds: CGRect {
        didSet {
            if oldValue.size != bounds.size {
                syncDrawableSize()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncDrawableSize()
    }

    func syncDrawableSize() {
        guard let metalLayer else { return }
        guard bounds.width >= 4 && bounds.height >= 4 else { return }
        let rawScale = window?.screen.scale ?? traitCollection.displayScale
        let scale = rawScale > 0 ? rawScale : 1.0
        var pxW = (bounds.width * scale).rounded()
        var pxH = (bounds.height * scale).rounded()
        // Cap Metal backing texture at 4K to avoid excess GPU VRAM on 5K/6K displays.
        if pxW > 3840 || pxH > 2160 {
            let factor = min(3840.0 / pxW, 2160.0 / pxH)
            pxW = (pxW * factor).rounded()
            pxH = (pxH * factor).rounded()
        }
        let target = CGSize(width: max(pxW, 4), height: max(pxH, 4))
        if metalLayer.contentsScale != scale || metalLayer.drawableSize != target {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = target
        }
        let nativePx = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if abs(lastReportedPixelSize.width - nativePx.width) >= 2 ||
           abs(lastReportedPixelSize.height - nativePx.height) >= 2 {
            lastReportedPixelSize = nativePx
            onGeometryChanged?(nativePx)
        }
    }
}

/// Root view controller hosted inside the external `UIWindowScene`.
final class ExternalDisplayViewController: UIViewController {
    let surfaceView = ExternalDisplaySurfaceView(frame: .zero)
    private let standbyContainer = UIView()
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        surfaceView.frame = view.bounds
        surfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(surfaceView)

        standbyContainer.frame = view.bounds
        standbyContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        standbyContainer.backgroundColor = .black
        view.addSubview(standbyContainer)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 22, weight: .medium)
        statusLabel.textColor = UIColor(white: 0.72, alpha: 1.0)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "HengeLinux · External Display Connected\nBoot a Linux VM on your iPhone"
        standbyContainer.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: standbyContainer.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: standbyContainer.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: standbyContainer.leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: standbyContainer.trailingAnchor, constant: -40),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        surfaceView.syncDrawableSize()
    }

    func updateStandbyMessage(_ message: String?) {
        // Keep `surfaceView` unhidden behind `standbyContainer` so CoreAnimation
        // keeps its `CAMetalLayer` drawable pool valid across standby transitions.
        if let message, !message.isEmpty {
            if statusLabel.text != message {
                statusLabel.text = message
            }
            standbyContainer.isHidden = false
        } else {
            standbyContainer.isHidden = true
            surfaceView.syncDrawableSize()
        }
    }
}

/// Coordinates dedicated external-monitor `CAMetalLayer` ownership, VirtIO-GPU
/// KMS resolution presets, and clean fallback back to the iPhone Metal surface
/// when a monitor connects, disconnects, or is toggled by the user.
@MainActor
final class ExternalDisplayManager: ObservableObject {
    static let shared = ExternalDisplayManager()

    private static let presetDefaultsKey = "externalDisplayResolutionPreset"

    @Published private(set) var isExternalDisplayConnected: Bool = false
    @Published var routeToExternalDisplay: Bool = true {
        didSet {
            guard oldValue != routeToExternalDisplay else { return }
            syncActiveDisplayLayer()
        }
    }
    @Published var resolutionPreset: ExternalDisplayResolutionPreset {
        didSet {
            guard oldValue != resolutionPreset else { return }
            UserDefaults.standard.set(resolutionPreset.rawValue, forKey: Self.presetDefaultsKey)
            if isRenderingOnExternalDisplay {
                applyExternalGuestResolution()
            }
        }
    }
    @Published private(set) var externalNativeSize: CGSize = .zero
    @Published private(set) var activeExternalGuestWidth: Int = 1920
    @Published private(set) var activeExternalGuestHeight: Int = 1080
    @Published private(set) var isVMRunning: Bool = false

    private weak var externalViewController: ExternalDisplayViewController?
    private weak var localDisplayLayer: CAMetalLayer?

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.presetDefaultsKey) ?? ""
        self.resolutionPreset = ExternalDisplayResolutionPreset(rawValue: saved) ?? .auto
    }

    var isRenderingOnExternalDisplay: Bool {
        isExternalDisplayConnected && routeToExternalDisplay
    }

    var activeResolutionLabel: String {
        "\(activeExternalGuestWidth)×\(activeExternalGuestHeight)"
    }

    var statusLabel: String {
        if isExternalDisplayConnected {
            let nw = Int(externalNativeSize.width.rounded())
            let nh = Int(externalNativeSize.height.rounded())
            if nw > 0 && nh > 0 {
                return "Connected (\(nw)×\(nh))"
            }
            return "Connected"
        }
        return "Not Connected"
    }

    func setVMRunning(_ running: Bool) {
        if isVMRunning != running {
            isVMRunning = running
        }
        syncActiveDisplayLayer()
    }

    func registerLocalDisplayLayer(_ layer: CAMetalLayer?) {
        guard localDisplayLayer !== layer else { return }
        localDisplayLayer = layer
        syncActiveDisplayLayer()
    }

    func unregisterLocalDisplayLayer(_ layer: CAMetalLayer?) {
        if layer == nil || localDisplayLayer === layer {
            localDisplayLayer = nil
        }
        if !isRenderingOnExternalDisplay {
            HengeVMBridge.shared.detachDisplayLayer(ifMatching: layer)
        }
    }

    func attachExternalViewController(_ vc: ExternalDisplayViewController, nativePixelSize: CGSize) {
        externalViewController = vc
        externalNativeSize = nativePixelSize
        isExternalDisplayConnected = true
        vc.surfaceView.onGeometryChanged = { [weak self] pxSize in
            Task { @MainActor [weak self] in
                self?.handleExternalGeometryUpdate(pxSize)
            }
        }
        syncActiveDisplayLayer()
    }

    func detachExternalViewController(_ vc: ExternalDisplayViewController) {
        guard externalViewController === vc else { return }
        let extLayer = vc.surfaceView.metalLayer
        vc.surfaceView.onGeometryChanged = nil
        externalViewController = nil
        if let local = localDisplayLayer {
            HengeVMBridge.shared.attachDisplayLayer(local)
        } else {
            HengeVMBridge.shared.detachDisplayLayer(ifMatching: extLayer)
        }
        externalNativeSize = .zero
        isExternalDisplayConnected = false
    }

    private func handleExternalGeometryUpdate(_ pixelSize: CGSize) {
        guard pixelSize.width >= 320 && pixelSize.height >= 240 else { return }
        let changed = abs(externalNativeSize.width - pixelSize.width) >= 2 ||
                      abs(externalNativeSize.height - pixelSize.height) >= 2
        if changed {
            externalNativeSize = pixelSize
            if isRenderingOnExternalDisplay {
                applyExternalGuestResolution()
            }
        }
    }

    func applyExternalGuestResolution() {
        guard isRenderingOnExternalDisplay else { return }
        let target = resolutionPreset.resolvedPixelSize(forNativeSize: externalNativeSize)
        if activeExternalGuestWidth != target.width {
            activeExternalGuestWidth = target.width
        }
        if activeExternalGuestHeight != target.height {
            activeExternalGuestHeight = target.height
        }
        HengeVMBridge.shared.updateDisplaySize(
            width: UInt32(target.width),
            height: UInt32(target.height)
        )
    }

    func syncActiveDisplayLayer() {
        if isRenderingOnExternalDisplay, let extVC = externalViewController {
            let target = resolutionPreset.resolvedPixelSize(forNativeSize: externalNativeSize)
            if activeExternalGuestWidth != target.width {
                activeExternalGuestWidth = target.width
            }
            if activeExternalGuestHeight != target.height {
                activeExternalGuestHeight = target.height
            }
            if isVMRunning {
                extVC.updateStandbyMessage(nil)
                if let extLayer = extVC.surfaceView.metalLayer {
                    HengeVMBridge.shared.attachDisplayLayer(extLayer)
                }
                HengeVMBridge.shared.updateDisplaySize(
                    width: UInt32(target.width),
                    height: UInt32(target.height)
                )
            } else {
                extVC.updateStandbyMessage(
                    "HengeLinux · External Display Ready (\(target.width)×\(target.height))\nBoot a Linux VM on your iPhone"
                )
                HengeVMBridge.shared.detachDisplayLayer(ifMatching: extVC.surfaceView.metalLayer)
            }
        } else {
            if let extVC = externalViewController {
                extVC.updateStandbyMessage(
                    isVMRunning
                        ? "HengeLinux · Video routed to iPhone\nTap the monitor icon on iPhone to switch back"
                        : "HengeLinux · External Display Connected\nBoot a Linux VM on your iPhone"
                )
            }
            if let local = localDisplayLayer {
                HengeVMBridge.shared.attachDisplayLayer(local)
            } else if let extLayer = externalViewController?.surfaceView.metalLayer {
                HengeVMBridge.shared.detachDisplayLayer(ifMatching: extLayer)
            }
        }
    }

    /// Returns the primary iPhone/iPad application `UIScreen` (excluding any
    /// connected external monitor scene) for safe brightness/keyboard queries.
    static func mainApplicationScreen() -> UIScreen? {
        let appScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let active = appScenes.first(where: { $0.activationState == .foregroundActive }) ?? appScenes.first
        return active?.screen
    }
}

/// UIKit scene delegate instantiated automatically by iOS for
/// `UIWindowSceneSessionRoleExternalDisplayNonInteractive` (USB-C / HDMI / AirPlay).
@MainActor
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var displayViewController: ExternalDisplayViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let win = UIWindow(windowScene: windowScene)
        win.backgroundColor = .black

        let vc = ExternalDisplayViewController()
        win.rootViewController = vc
        win.isHidden = false

        self.window = win
        self.displayViewController = vc

        let bounds = windowScene.screen.bounds
        let scale = windowScene.screen.scale > 0 ? windowScene.screen.scale : 1.0
        let pixelSize = CGSize(
            width: (bounds.width * scale).rounded(),
            height: (bounds.height * scale).rounded()
        )
        ExternalDisplayManager.shared.attachExternalViewController(vc, nativePixelSize: pixelSize)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let vc = displayViewController {
            ExternalDisplayManager.shared.detachExternalViewController(vc)
        }
        displayViewController = nil
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
    }
}
