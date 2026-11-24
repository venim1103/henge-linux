/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_TXM_JIT_H
#define HENGE_TXM_JIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* TXM safe low virtual address window: [4 GiB, 64 GiB), strictly < 0x7000000000. */
#define HENGE_TXM_MIN_VA       0x0100000000ULL
#define HENGE_TXM_MAX_VA       0x1000000000ULL
#define HENGE_TXM_HARD_CEILING 0x7000000000ULL

/* Default and adaptive dual-mapped RX/RW JIT code cache sizes. */
#define HENGE_DEFAULT_JIT_POOL_BYTES (384ULL * 1024ULL * 1024ULL)
#define HENGE_MIN_JIT_POOL_BYTES     (192ULL * 1024ULL * 1024ULL)
#define HENGE_MID_JIT_POOL_BYTES     (256ULL * 1024ULL * 1024ULL)

/* Byte-0 page blessing magic inspected by iOS 26/27 TXM on 16 KiB boundaries. */
#define HENGE_TXM_BLESSING_MAGIC 0x69U

typedef enum {
    HENGE_JIT_MODE_CLASSIC    = 0,
    HENGE_JIT_MODE_TXM_BROKER = 1,
} HengeJitMode;

typedef enum {
    HENGE_JIT_POLICY_AUTO          = 0,
    HENGE_JIT_POLICY_FORCE_CLASSIC = 1,
    HENGE_JIT_POLICY_FORCE_TXM     = 2,
} HengeJitPolicy;

typedef struct {
    uintptr_t    rx_base;
    uintptr_t    rw_base;
    size_t       size;
    bool         blessed;
    bool         dual_mapped;
    HengeJitMode mode;
} HengeJitPool;

/* Runtime OS / TXM detection and dual-mode JIT strategy selection (iOS 18.0–27+). */
void henge_jit_set_policy(HengeJitPolicy policy);
HengeJitPolicy henge_jit_get_policy(void);
int henge_ios_major_version(void);
bool henge_device_has_txm(void);
HengeJitMode henge_jit_detect_mode(void);
bool henge_jit_requires_txm_low_va(void);

/* Live Jetsam-aware memory and adaptive JIT pool sizing (os_proc_available_memory). */
size_t henge_recommended_jit_pool_bytes(void);
uint64_t henge_available_memory_bytes(void);
bool henge_is_entitled_high_memory(void);
uint32_t henge_recommended_guest_ram_mib(size_t jit_pool_bytes);
uint32_t henge_recommended_guest_ram_mib_for_gpu(size_t jit_pool_bytes, int gpu_backend_mode);
uint32_t henge_gpu_ram_reserve_mib(int gpu_backend_mode, uint64_t avail_memory_bytes);

/* Return true iff [base, base + size) lies within TXM's safe low-VA bounds. */
bool henge_txm_is_valid_jit_range(uintptr_t base, size_t size);

/*
 * Stamp and verify byte-0 0x69 blessing markers on every 16 KiB page of a
 * writable JIT staging buffer.
 */
int henge_txm_stamp_blessing_markers(uint8_t *rw_base, size_t size);
bool henge_txm_verify_blessing_markers(const uint8_t *base, size_t size);

/*
 * Query debugger / code-signing debug state:
 *   - henge_txm_is_ptraced(): true only while a debugger is actively attached
 *     (P_TRACED); required before executing brk #0xf00d traps.
 *   - henge_txm_is_cs_debugged(): true when XNU CS_DEBUGGED (0x10000000) is
 *     set on the process, which persists after debugserver detachment and
 *     authorizes LEDGER_NO_FOOTPRINT memory entries.
 */
bool henge_txm_is_ptraced(void);
bool henge_txm_is_cs_debugged(void);
bool henge_txm_is_debugger_attached(void);

/*
 * Low-level ARM64 breakpoint primitives matching StikDebug / universal.js:
 *   brk #0x69             -> probe active JIT debugger (returns 0xE0000069 in x0)
 *   x16 = 1; brk #0xf00d  -> prepare & bless RX JIT region of `size` bytes
 *   x16 = 0; brk #0xf00d  -> detach debugserver cleanly
 */
uint64_t henge_jit26_probe(void);
uintptr_t henge_jit26_prepare_region(uintptr_t hint, size_t size);
void henge_jit26_detach(void);

/*
 * Install SIGTRAP/SIGBUS guard so untethered brk #0x69 / #0xf00d probes never
 * terminate the process, and acquire/cache the process-lifetime dual-mapped
 * RX/RW TXM JIT pool (< 0x7000000000).
 */
void henge_jit_install_trap_guard(void);
bool henge_jit_acquire_pool(size_t bytes, bool detach_after, HengeJitPool *out_pool);
bool henge_jit_current_pool(HengeJitPool *out_pool);
__attribute__((deprecated("Use henge_jit_copy_status() instead")))
const char *henge_jit_status_message(void);
void henge_jit_copy_status(char *buf, size_t cap);

/*
 * Allocate and release guest physical RAM using Darwin LEDGER_NO_FOOTPRINT
 * when CS_DEBUGGED is active, falling back to standard page-aligned mmap.
 */
void *henge_alloc_ledger_exempt_ram(size_t size, bool *out_ledger_exempt);
void henge_free_ledger_exempt_ram(void *ptr, size_t size);

#ifdef __cplusplus
}
#endif

#endif /* HENGE_TXM_JIT_H */
