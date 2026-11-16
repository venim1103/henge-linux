// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum JitActivationState: Equatable {
    case idle
    case requestingExtension
    case blessed(poolMiB: Int, ledgerExempt: Bool)
    case fallbackUntethered(reason: String)
}

enum GpuDisplayBackend: String, CaseIterable, Identifiable {
    case gop2D = "2D UEFI GOP (Metal)"
    case virgl3D = "3D VirtIO-GPU VirGL (ANGLE Metal)"

    var id: String { rawValue }
}

/// Manages in-app TXM JIT activation (`brk #0xf00d` + `0x69` page blessing)
/// and pairing record discovery (`Documents/pairing.plist`).
@MainActor
final class SelfDebugJITClient: ObservableObject {
    @Published private(set) var state: JitActivationState = .idle
    @Published var gpuBackend: GpuDisplayBackend = .gop2D

    static let defaultJitPoolMiB: Int = 384

    init() {
        henge_jit_install_trap_guard()
    }

    var pairingFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("pairing.plist")
    }

    var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: pairingFileURL.path)
    }

    func prepareSession() async {
        if case .blessed = state {
            return
        }

        state = .requestingExtension

        let poolBytes = Int(Self.defaultJitPoolMiB) * 1024 * 1024
        let result = await Task.detached(priority: .userInitiated) { () -> (Bool, Int, Bool, String) in
            var pool = HengeJitPool()
            let acquired = henge_jit_acquire_pool(poolBytes, true, &pool)
            var statusBuf = [CChar](repeating: 0, count: 256)
            henge_jit_copy_status(&statusBuf, statusBuf.count)
            let status = String(cString: statusBuf)
            return (
                acquired,
                Int(pool.size / (1024 * 1024)),
                henge_txm_is_cs_debugged(),
                status
            )
        }.value

        if result.0 {
            state = .blessed(
                poolMiB: result.1,
                ledgerExempt: result.2
            )
            return
        }

        let status = result.3
        if hasPairingFile {
            state = .fallbackUntethered(
                reason: "\(status) · pairing.plist found (attach StikDebug with henge-jit.js; in-app XPC lands in Milestone 5.4)."
            )
        } else {
            state = .fallbackUntethered(
                reason: "\(status) · Attach StikDebug (henge-jit.js) or LLDB for 384 MiB TXM JIT."
            )
        }
    }

    /// Flush translated block cache on VM stop without releasing the process-lifetime
    /// TXM dual-mapped RX/RW pool so subsequent guest reboots require zero debugger attach.
    func prepareForReboot() {
        if case .blessed = state {
            return
        }
        state = .idle
    }

    func reset() {
        state = .idle
    }
}
