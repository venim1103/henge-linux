/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_PLATFORM_H
#define HENGE_PLATFORM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Darwin sockaddr_un.sun_path maximum capacity including trailing NUL byte. */
#define HENGE_DARWIN_SUN_PATH_MAX 104U

/* ARM64 16 KiB host page alignment invariant (2^14 = 16,384 bytes). */
#define HENGE_HOST_PAGE_SHIFT 14U
#define HENGE_HOST_PAGE_SIZE  (1ULL << HENGE_HOST_PAGE_SHIFT)

/* Guest RAM safety bounds (in MiB) to prevent physical Jetsam exhaustion. */
#define HENGE_MIN_GUEST_RAM_MIB 512U
#define HENGE_MAX_GUEST_RAM_MIB 10240U

/*
 * Format a deterministic AF_UNIX socket path guaranteed to fit strictly within
 * Darwin's 104-byte sockaddr_un.sun_path limit, even when iOS container paths
 * exceed 104 bytes.
 *
 * Returns 0 on success, or -1 if arguments are invalid or out_cap is too small.
 */
int henge_format_unix_socket_path(const char *container_dir,
                                  const char *socket_name,
                                  char *out_path,
                                  size_t out_cap);

/*
 * Decode VMSAv8-64 TCR_EL1.TG0 / TG1 2-bit granule field into page shift bits:
 *   TTBR0 (ttbr1 == 0): 0b00 -> 12 (4 KiB), 0b10 -> 14 (16 KiB), 0b01 -> 16 (64 KiB)
 *   TTBR1 (ttbr1 != 0): 0b10 -> 12 (4 KiB), 0b01 -> 14 (16 KiB), 0b11 -> 16 (64 KiB)
 * Returns 0 if the granule encoding is reserved/invalid.
 */
uint32_t henge_decode_granule_bits(uint32_t tg_bits, int ttbr1);

/*
 * Clamp and align a requested guest RAM allocation (in MiB) to host 16 KiB
 * page boundaries within [HENGE_MIN_GUEST_RAM_MIB, device_cap_mib].
 */
uint64_t henge_align_guest_ram_bytes(uint32_t requested_mib, uint32_t device_cap_mib);

/*
 * Thread-safe C-ABI lifecycle pause gate and render mutex called from
 * SwiftUI/UIKit on UIApplication.willResignActiveNotification /
 * didBecomeActiveNotification so in-flight Metal drawables finish before
 * UIKit revokes GPU submission privileges.
 */
void hengelinux_set_render_paused(bool paused);
bool hengelinux_is_render_paused(void);
void hengelinux_render_lock(void);
void hengelinux_render_unlock(void);

/*
 * Background-suspend virtual/physical counter (CNTVCT_EL0 / CNTPCT_EL0) offset
 * compensation (in 24 MHz host ticks). Decoupled from GPU render pause so
 * overlays (SafariSheetView, Control Center) and background audio never freeze
 * guest timers while vCPU threads remain active; compensates only when vCPU
 * execution is explicitly paused or an unscheduled host wall-clock jump occurs.
 */
void hengelinux_set_vm_clock_paused(bool paused);
uint64_t hengelinux_suspend_counter_offset(void);
const uint64_t *hengelinux_negative_counter_offset_ptr(void);
uint64_t hengelinux_compensated_counter(uint64_t raw_ticks);
void hengelinux_reset_suspend_counter(void);

/*
 * Capture POSIX stdout/stderr (including PL011 serial ttyAMA0 and HengeVM
 * engine diagnostics) into an in-memory 64 KiB circular log buffer and an
 * optional persistent log file (e.g., Documents/hengelinux-boot.log).
 */
int hengelinux_start_console_capture(const char *log_file_path);
void hengelinux_console_append_line(const char *line);
/**
 * Returns a monotonically increasing byte/event counter for captured console output.
 * Note: hengelinux_clear_console_log() increments this counter by a sentinel +1ULL
 * so SwiftUI polling observers wake immediately; callers must not treat it as an
 * exact cumulative byte count across log clears.
 */
uint64_t hengelinux_console_total_bytes(void);
size_t hengelinux_copy_console_log(char *out_buf, size_t out_cap);
void hengelinux_clear_console_log(void);

/*
 * Dedicated pure guest PL011 UART (ttyAMA0) byte stream ring (128 KiB),
 * separate from host stdout/stderr diagnostic logs, supporting incremental
 * cursor-based reads for the interactive VT100/ANSI terminal emulator.
 */
void hengelinux_serial_append_byte(uint8_t byte);
void hengelinux_serial_append_bytes(const uint8_t *data, size_t len);
uint64_t hengelinux_serial_total_bytes(void);
size_t hengelinux_serial_copy_from(uint64_t *cursor, uint8_t *out_buf, size_t out_cap);
void hengelinux_serial_clear(void);

/*
 * Guest OSC 9999 HID bridge handshake state. Flips true only after the Linux
 * guest's native henge-dual-console binary emits "HENGE_HID_READY" (V1) or
 * "HENGE_HID_READY_V2" (V2: OSC 9999;T tty1-scoped text + always-active
 * ttyAMA0 serial shell on VT2+) on ttyAMA0.
 */
bool hengelinux_is_guest_hid_bridge_ready(void);
bool hengelinux_is_guest_hid_bridge_v2(void);
void hengelinux_reset_guest_hid_bridge_ready(void);

/*
 * Latest Metal-presented guest framebuffer dimensions (packed lock-free atomic)
 * and inverse aspect-fit touch mapper matching fb_metal.m's centered quad.
 */
void hengelinux_set_presented_fb_size(uint32_t width, uint32_t height);
void hengelinux_get_presented_fb_size(uint32_t *out_width, uint32_t *out_height);
void henge_map_touch_to_guest_norm(double touch_x,
                                   double touch_y,
                                   double view_w,
                                   double view_h,
                                   uint32_t fb_w,
                                   uint32_t fb_h,
                                   double *out_nx,
                                   double *out_ny);

#ifdef __cplusplus
}
#endif

#endif /* HENGE_PLATFORM_H */
