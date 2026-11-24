// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

/// Visual stacked memory bar breaking down Guest RAM + JIT Pool + GPU VRAM Reserve + Free Margin
/// against the live iOS Jetsam ceiling (`os_proc_available_memory()`).
struct JetsamMemoryBreakdownBar: View {
    let guestRamMiB: Int
    let jitPoolMiB: Int
    let gpuBackendMode: Int
    let refreshToken: Int

    private var liveAvailMiB: Int {
        _ = refreshToken
        let bytes = henge_available_memory_bytes()
        if bytes > 0 {
            return Int(bytes / (1024 * 1024))
        }
        return 3350
    }

    private var isEntitled: Bool {
        _ = refreshToken
        return henge_is_entitled_high_memory()
    }

    private var isJitAlreadyAllocated: Bool {
        _ = refreshToken
        return henge_jit_current_pool(nil)
    }

    private var pendingJitMiB: Int {
        isJitAlreadyAllocated ? 0 : jitPoolMiB
    }

    private var gpuReserveMiB: Int {
        Int(henge_gpu_ram_reserve_mib(Int32(gpuBackendMode), henge_available_memory_bytes()))
    }

    private var ceilingMiB: Int {
        max(liveAvailMiB, guestRamMiB + pendingJitMiB + gpuReserveMiB)
    }

    private var freeMarginMiB: Int {
        max(0, liveAvailMiB - guestRamMiB - pendingJitMiB - gpuReserveMiB)
    }

    private var isOverBudget: Bool {
        (guestRamMiB + pendingJitMiB + gpuReserveMiB + 256) > liveAvailMiB
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    isEntitled ? "Entitled Jetsam Tier" : "Standard SideStore Ledger",
                    systemImage: isEntitled ? "memorychip.fill" : "memorychip"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(isEntitled ? .green : .secondary)
                Spacer()
                Text("Avail ~\(liveAvailMiB) MiB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let denom = Double(max(ceilingMiB, 1))
                let guestW = w * min(1.0, Double(guestRamMiB) / denom)
                let jitW = w * min(1.0, Double(pendingJitMiB) / denom)
                let gpuW = w * min(1.0, Double(gpuReserveMiB) / denom)

                HStack(spacing: 1) {
                    Rectangle()
                        .fill(isOverBudget ? Color.orange : Color.blue)
                        .frame(width: max(2, guestW))
                    if pendingJitMiB > 0 {
                        Rectangle()
                            .fill(Color.purple)
                            .frame(width: max(2, jitW))
                    }
                    if gpuReserveMiB > 0 {
                        Rectangle()
                            .fill(Color.teal)
                            .frame(width: max(2, gpuW))
                    }
                    Rectangle()
                        .fill(Color.green.opacity(0.28))
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 12)

            HStack(spacing: 10) {
                legendDot(color: isOverBudget ? .orange : .blue, text: "Guest \(guestRamMiB)M")
                legendDot(color: .purple, text: isJitAlreadyAllocated ? "JIT Live" : "JIT \(jitPoolMiB)M")
                if gpuReserveMiB > 0 {
                    legendDot(color: .teal, text: "GPU \(gpuReserveMiB)M")
                }
                Spacer()
                Text("Free \(freeMarginMiB)M")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isOverBudget ? .orange : .green)
            }

            if !isEntitled {
                Text("Tip: Free SideStore installs cap RAM at ~3.35 GiB. Enabling increased-memory-limit (GetMoreRam / paid Dev ID) unlocks ~5+ GiB for 3D VirGL desktops.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Dedicated per-VM Graphics & Display sheet for HengeLinux v0.3.0.
struct GraphicsDisplayConfigSheet: View {
    let vmName: String
    let distroTag: String
    @Binding var gpuBackend: GpuDisplayBackend
    @Binding var vramCapMiB: Int
    @Binding var refreshRateHz: Int
    @Binding var dualScanoutEnabled: Bool
    @ObservedObject var externalDisplay: ExternalDisplayManager
    @Binding var oledAutoDimSeconds: Int
    @Environment(\.dismiss) private var dismiss

    @State private var shaderCacheBytes: UInt64 = HengeVMBridge.shared.shaderCacheSizeBytes()
    @State private var cacheClearedNotice: Bool = false

    private let vramOptions: [(mib: Int, label: String)] = [
        (0, "Auto (Jetsam-Aware)"),
        (256, "256 MiB (Standard Ledger)"),
        (512, "512 MiB (Entitled 8 GB)"),
        (1024, "1,024 MiB (12–16 GB)")
    ]

    private let refreshOptions: [(hz: Int, label: String)] = [
        (30, "30 Hz (Battery / Thermal Saver)"),
        (60, "60 Hz (Recommended)"),
        (120, "120 Hz (ProMotion Opt-In)")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Display Adapter (\(vmName))") {
                    ForEach(GpuDisplayBackend.allCases) { backend in
                        Button {
                            gpuBackend = backend
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: backend))
                                    .font(.title3)
                                    .foregroundStyle(gpuBackend == backend ? .blue : .secondary)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(backend.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(subtitle(for: backend))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if gpuBackend == backend {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                    if distroTag == "ubuntu" && gpuBackend != .gop2D {
                        Text("Ubuntu Cloud omits virtio-gpu.ko by default. Run Guest Tools install.sh inside Ubuntu before using VirtIO-GPU KMS/3D.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Section("GPU Budget & Refresh Cadence") {
                    Picker("VRAM Ceiling", selection: $vramCapMiB) {
                        ForEach(vramOptions, id: \.mib) { opt in
                            Text(opt.label).tag(opt.mib)
                        }
                    }
                    Picker("Target Refresh Rate", selection: $refreshRateHz) {
                        ForEach(refreshOptions, id: \.hz) { opt in
                            Text(opt.label).tag(opt.hz)
                        }
                    }
                    if refreshRateHz >= 120 {
                        Text("ProMotion 120 Hz writes 120 Hz into the guest EDID. Best suited for smooth Wayland compositors; thermal throttling automatically steps down to 40/30 Hz under sustained load.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("External USB-C / HDMI Display") {
                    LabeledContent("Monitor Status", value: externalDisplay.statusLabel)
                    Picker("External Resolution", selection: $externalDisplay.resolutionPreset) {
                        ForEach(ExternalDisplayResolutionPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    Toggle("Advertise Dual Scanout (Extended Mode)", isOn: $dualScanoutEnabled)
                    Picker("OLED Screen Saver Auto-Dim", selection: $oledAutoDimSeconds) {
                        ForEach(OLEDAutoDimOption.allCases) { opt in
                            Text(opt.label).tag(opt.rawValue)
                        }
                    }
                }

                Section("Metal Shader Cache (Library/Caches/HengeShaders)") {
                    LabeledContent("Cached Shaders", value: formattedBytes(shaderCacheBytes))
                    Button(role: .destructive) {
                        _ = HengeVMBridge.shared.clearShaderCache()
                        shaderCacheBytes = HengeVMBridge.shared.shaderCacheSizeBytes()
                        cacheClearedNotice = true
                    } label: {
                        Label(
                            cacheClearedNotice ? "Shader Cache Cleared" : "Clear Shader Cache",
                            systemImage: cacheClearedNotice ? "checkmark.circle.fill" : "trash"
                        )
                    }
                }
            }
            .navigationTitle("Graphics & Display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                shaderCacheBytes = HengeVMBridge.shared.shaderCacheSizeBytes()
                cacheClearedNotice = false
            }
        }
    }

    private func icon(for backend: GpuDisplayBackend) -> String {
        switch backend {
        case .gop2D: return "rectangle.on.rectangle"
        case .virtioGpu2D: return "display"
        case .virgl3D: return "cube.transparent.fill"
        }
    }

    private func subtitle(for backend: GpuDisplayBackend) -> String {
        switch backend {
        case .gop2D:
            return "Universal UEFI simpledrm/efifb · Lowest RAM overhead"
        case .virtioGpu2D:
            return "Dirty-rect Metal uploads + hardware cursor · Dynamic EDID"
        case .virgl3D:
            return henge_virtio_gpu_has_virglrenderer()
                ? "Async VirGL 3D (ANGLE Metal + IOSurface) · GLES 3.0 Wayland"
                : "VirGL 3D staged · Falls back seamlessly to Enhanced 2D KMS"
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KiB", Double(bytes) / 1024.0) }
        return String(format: "%.2f MiB", Double(bytes) / (1024.0 * 1024.0))
    }
}

/// Auto-recovery banner surfaced when the 3D crash sentinel detects a prior startup crash
/// and automatically falls back the VM to Enhanced 2D VirtIO-GPU KMS.
struct GpuRecoveryDiagnosticBanner: View {
    let vmName: String
    let onRetry3D: () -> Void
    let onViewLogs: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("3D Graphics Auto-Recovery")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("\(vmName) terminated unexpectedly during 3D VirGL initialization and was safely switched to Enhanced 2D VirtIO-GPU KMS.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("View Boot Logs") {
                    onViewLogs()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                Button("Retry VirGL 3D") {
                    onRetry3D()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Compact opt-in Live Performance HUD Pill overlaid on the active VM session canvas.
/// Reads lock-free C atomics (`henge_gpu_telemetry_get_snapshot`) with zero vCPU lock contention.
struct LivePerformanceHUDPill: View {
    let onRequestScreenSaver: () -> Void

    @State private var snap = HengeGpuTelemetrySnapshot()
    @State private var lastObservedFrames: UInt64 = 0
    @State private var idleTickCount: Int = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var fpsText: String {
        let effectiveTenths: UInt32 = (idleTickCount >= 2) ? 0 : snap.fps_tenths
        return String(format: "%.0f FPS", Double(effectiveTenths) / 10.0)
    }

    private var backendLabel: String {
        switch snap.active_backend {
        case 1:
            return HengeVMBridge.shared.isVirgl3DActive ? "VirGL 3D" : "2D KMS"
        case 2:
            return "2D KMS"
        default:
            return "2D GOP"
        }
    }

    private var vramMiBText: String {
        let bytes = max(snap.metal_allocated_bytes, snap.vram_tracked_bytes)
        let mib = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0fM", mib)
    }

    private var thermalColor: Color {
        switch snap.thermal_state {
        case UInt32(HENGE_THERMAL_SERIOUS.rawValue): return .orange
        case UInt32(HENGE_THERMAL_CRITICAL.rawValue): return .red
        default: return .green
        }
    }

    private var thermalLabel: String {
        switch snap.thermal_state {
        case UInt32(HENGE_THERMAL_SERIOUS.rawValue): return "Warm (\(snap.effective_refresh_hz)Hz)"
        case UInt32(HENGE_THERMAL_CRITICAL.rawValue): return "Hot (\(snap.effective_refresh_hz)Hz)"
        default: return "\(snap.effective_refresh_hz)Hz"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(thermalColor)
                .frame(width: 7, height: 7)
            Text(backendLabel)
                .font(.caption2.weight(.semibold))
            Text(fpsText)
                .font(.caption2.monospacedDigit())
            Text("GPU \(vramMiBText)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(thermalLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(thermalColor)

            if snap.thermal_state >= UInt32(HENGE_THERMAL_CRITICAL.rawValue) {
                Button {
                    onRequestScreenSaver()
                } label: {
                    Image(systemName: "moon.stars.fill")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
                .accessibilityLabel("Enable OLED Screen Saver to cool device")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(thermalColor.opacity(0.45), lineWidth: 0.75)
        )
        .onAppear {
            henge_gpu_telemetry_get_snapshot(&snap)
            lastObservedFrames = snap.total_frames_presented
            idleTickCount = 0
        }
        .onReceive(timer) { _ in
            henge_gpu_telemetry_get_snapshot(&snap)
            if snap.total_frames_presented == lastObservedFrames {
                idleTickCount = min(idleTickCount + 1, 10)
            } else {
                lastObservedFrames = snap.total_frames_presented
                idleTickCount = 0
            }
        }
    }
}
