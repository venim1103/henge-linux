// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Helper NSExtension (`com.apple.ar.viewer` extension point) modeled after
/// PlayportJIT.appex. Receives the device pairing record and target PID over
/// NSExtensionContext to drive StikJIT / idevice `brk #0xf00d` page blessing
/// without leaving the HengeLinux app.
final class JITExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        var responseInfo: [String: Any] = [
            "status": "ready",
            "protocol": "brk-0xf00d-0x69",
            "vpnLoopback": "10.7.0.1"
        ]

        if let inputItem = context.inputItems.first as? NSExtensionItem,
           let userInfo = inputItem.userInfo {
            let targetPID = userInfo["targetPID"] as? Int32 ?? 0
            let poolBytes = userInfo["poolBytes"] as? UInt64 ?? (384 * 1024 * 1024)
            let hasPairing = (userInfo["pairingData"] as? Data)?.isEmpty == false

            responseInfo["targetPID"] = targetPID
            responseInfo["poolBytes"] = poolBytes
            responseInfo["pairingPresent"] = hasPairing
            responseInfo["status"] = (targetPID > 0 && hasPairing) ? "blessing_armed" : "awaiting_pairing"
        }

        let outputItem = NSExtensionItem()
        outputItem.userInfo = responseInfo
        context.completeRequest(returningItems: [outputItem], completionHandler: nil)
    }
}
