// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import QuartzCore
import UIKit

/// Coordinates CAMetalLayer drawable presentation and audio queue state across
/// iOS app-switcher transitions (`willResignActive` / `didBecomeActive`),
/// preventing `gpus_ReturnNotPermittedKillClient` aborts when iOS reclaims drawables.
@MainActor
final class MetalLifecycleGuard: ObservableObject {
    @Published private(set) var isPaused: Bool = false
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activeObserver: NSObjectProtocol?

    init() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pauseRendering()
            }
        }

        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeRendering()
            }
        }
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    func pauseRendering() {
        guard !isPaused else { return }
        isPaused = true
        hengelinux_set_render_paused(true)
    }

    func resumeRendering() {
        guard isPaused else { return }
        isPaused = false
        hengelinux_set_render_paused(false)
    }

    /// Serializes Metal drawable acquisition/commit against `willResignActive`
    /// so no in-flight GPU command buffer straddles UIKit suspension.
    nonisolated func withRenderLock(_ body: () -> Void) {
        hengelinux_render_lock()
        defer { hengelinux_render_unlock() }
        guard !hengelinux_is_render_paused() else { return }
        body()
    }

    /// Safe wrapper around `CAMetalLayer.nextDrawable()` that refuses drawable
    /// acquisition while the scene is resigning active or backgrounded.
    func acquireDrawable(from layer: CAMetalLayer) -> CAMetalDrawable? {
        guard !isPaused, !hengelinux_is_render_paused() else {
            return nil
        }
        return layer.nextDrawable()
    }
}
