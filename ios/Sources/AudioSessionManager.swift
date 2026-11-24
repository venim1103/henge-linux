// SPDX-License-Identifier: GPL-3.0-or-later
import AVFAudio
import Foundation
import UIKit

/// Configures and maintains the iOS `AVAudioSession` while a Linux VM is running
/// so CoreAudio (`host/audio_mac.c`) routes to the iPhone stereo speakers by
/// default (ignoring Silent Mode), hands off cleanly to Bluetooth / AirPlay /
/// wired / HDMI audio, and recovers from phone-call or app-switcher interruptions.
@MainActor
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private var isVMAudioActive: Bool = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw)
            }
        })
        observers.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleRouteChange()
            }
        })
        observers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVMAudioActive else { return }
                self.configureAndActivateSession()
            }
        })
        observers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVMAudioActive else { return }
                self.configureAndActivateSession()
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func activate() {
        guard !isVMAudioActive else { return }
        isVMAudioActive = true
        configureAndActivateSession()
    }

    func deactivate() {
        guard isVMAudioActive else { return }
        isVMAudioActive = false
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func configureAndActivateSession() {
        let session = AVAudioSession.sharedInstance()
        let duplexOptions: AVAudioSession.CategoryOptions = [
            .defaultToSpeaker,
            .allowBluetoothA2DP,
            .allowAirPlay,
        ]
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: duplexOptions)
            try session.setPreferredSampleRate(48_000.0)
            try session.setActive(true)
            ensureBuiltInOutputUsesSpeaker(session)
        } catch {
            // Fall back to playback-only if duplex audio session setup fails
            // (e.g. restricted microphone hardware) so speaker output still works.
            do {
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
            } catch {
                // Non-fatal: VM continues without host audio session reconfiguration.
            }
        }
    }

    private func ensureBuiltInOutputUsesSpeaker(_ session: AVAudioSession) {
        let outputs = session.currentRoute.outputs
        guard !outputs.isEmpty else { return }
        let onlyBuiltInReceiver = outputs.allSatisfy { $0.portType == .builtInReceiver }
        if onlyBuiltInReceiver {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    private func handleInterruption(typeRaw: UInt?) {
        guard isVMAudioActive,
              let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }
        if type == .ended {
            configureAndActivateSession()
        }
    }

    private func handleRouteChange() {
        guard isVMAudioActive else { return }
        ensureBuiltInOutputUsesSpeaker(AVAudioSession.sharedInstance())
    }
}
