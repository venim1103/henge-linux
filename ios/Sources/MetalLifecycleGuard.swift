// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import QuartzCore

/// Coordinates CAMetalLayer drawable presentation and audio queue state across
/// iOS app-switcher transitions (`willResignActive` / `didBecomeActive`),
/// preventing `gpus_ReturnNotPermittedKillClient` aborts when iOS reclaims drawables.
@MainActor
final class MetalLifecycleGuard: ObservableObject {
    @Published private(set) var isPaused: Bool = false

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

    /// Safe wrapper around `CAMetalLayer.nextDrawable()` that refuses drawable
    /// acquisition while the scene is resigning active or backgrounded.
    func acquireDrawable(from layer: CAMetalLayer) -> CAMetalDrawable? {
        guard !isPaused, !hengelinux_is_render_paused() else {
            return nil
        }
        return layer.nextDrawable()
    }
}
