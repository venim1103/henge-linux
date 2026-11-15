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

#ifdef __cplusplus
}
#endif

#endif /* HENGE_PLATFORM_H */
