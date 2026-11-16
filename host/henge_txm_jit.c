/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif

#include "henge_txm_jit.h"
#include "henge_platform.h"

#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

#if defined(__APPLE__)
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/ucontext.h>
#include <unistd.h>

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0U
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000U
#endif
#ifndef MAP_MEM_NAMED_CREATE
#define MAP_MEM_NAMED_CREATE 0x020000
#endif
#ifndef VM_LEDGER_TAG_DEFAULT
#define VM_LEDGER_TAG_DEFAULT 1
#endif
#ifndef VM_LEDGER_FLAG_NO_FOOTPRINT
#define VM_LEDGER_FLAG_NO_FOOTPRINT 1
#endif

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

extern kern_return_t mach_memory_entry_ownership(
    mem_entry_name_port_t mem_entry,
    task_t owner,
    int ledger_tag,
    int ledger_flags
);
#endif

#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

bool henge_txm_is_valid_jit_range(uintptr_t base, size_t size) {
    if (size == 0U || (size & (HENGE_HOST_PAGE_SIZE - 1ULL)) != 0U) {
        return false;
    }
    if ((base & (HENGE_HOST_PAGE_SIZE - 1ULL)) != 0U) {
        return false;
    }
    if (base < HENGE_TXM_MIN_VA) {
        return false;
    }
    uintptr_t end = base + (uintptr_t)size;
    if (end < base) {
        return false;
    }
    if (end > HENGE_TXM_MAX_VA || end >= HENGE_TXM_HARD_CEILING) {
        return false;
    }
    return true;
}

int henge_txm_stamp_blessing_markers(uint8_t *rw_base, size_t size) {
    if (rw_base == NULL || size == 0U || (size & (HENGE_HOST_PAGE_SIZE - 1ULL)) != 0U) {
        return -1;
    }
    for (size_t off = 0U; off < size; off += (size_t)HENGE_HOST_PAGE_SIZE) {
        rw_base[off] = HENGE_TXM_BLESSING_MAGIC;
    }
    return 0;
}

bool henge_txm_verify_blessing_markers(const uint8_t *base, size_t size) {
    if (base == NULL || size == 0U || (size & (HENGE_HOST_PAGE_SIZE - 1ULL)) != 0U) {
        return false;
    }
    for (size_t off = 0U; off < size; off += (size_t)HENGE_HOST_PAGE_SIZE) {
        if (base[off] != HENGE_TXM_BLESSING_MAGIC) {
            return false;
        }
    }
    return true;
}

bool henge_txm_is_ptraced(void) {
#if defined(__APPLE__)
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    size_t len = sizeof(info);
    if (sysctl(mib, 4, &info, &len, NULL, 0) != 0) {
        return false;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
#else
    return false;
#endif
}

bool henge_txm_is_cs_debugged(void) {
#if defined(__APPLE__)
    uint32_t cs_flags = 0U;
    if (csops(getpid(), CS_OPS_STATUS, &cs_flags, sizeof(cs_flags)) == 0 &&
        (cs_flags & CS_DEBUGGED) != 0U) {
        return true;
    }
    return henge_txm_is_ptraced();
#else
    return false;
#endif
}

bool henge_txm_is_debugger_attached(void) {
    return henge_txm_is_ptraced();
}

#if !defined(__aarch64__) && !defined(__arm64__)
uint64_t henge_jit26_probe(void) {
    return 0ULL;
}

uintptr_t henge_jit26_prepare_region(uintptr_t hint, size_t size) {
    (void)hint;
    (void)size;
    return 0U;
}

void henge_jit26_detach(void) {
}
#endif

static pthread_mutex_t g_pool_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_status_mutex = PTHREAD_MUTEX_INITIALIZER;
static atomic_bool g_pool_live = false;
static HengeJitPool g_active_pool = {0};
static char g_jit_status[256] = "Not initialized";

static void set_jit_status(const char *fmt, ...) {
    pthread_mutex_lock(&g_status_mutex);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_jit_status, sizeof(g_jit_status), fmt, ap);
    va_end(ap);
    pthread_mutex_unlock(&g_status_mutex);
}

#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__))
/*
 * Reserve a 384 MiB + 16 KiB zero-fill block in a dedicated Mach-O section
 * below 0x7000000000 (< 64 GiB) at launch so a contiguous low-VA hole is
 * guaranteed without touching standard __DATA.__bss globals.
 */
__attribute__((used, aligned(16384), section("__DATA,__jit_hold")))
static uint8_t g_jit_low_hold[HENGE_DEFAULT_JIT_POOL_BYTES + (16U << 10)];
static bool g_jit_low_hold_released = false;

static _Thread_local volatile sig_atomic_t g_expecting_jit_trap = 0;
static struct sigaction g_prev_sigtrap;
static struct sigaction g_prev_sigbus;
static pthread_once_t g_trap_once = PTHREAD_ONCE_INIT;

static bool is_known_jit_trap_pc(uint64_t pc) {
    const uintptr_t targets[3] = {
        (uintptr_t)&henge_jit26_probe,
        (uintptr_t)&henge_jit26_prepare_region,
        (uintptr_t)&henge_jit26_detach,
    };
    for (size_t i = 0U; i < 3U; i++) {
        if ((uintptr_t)pc >= targets[i] && (uintptr_t)pc < targets[i] + 24U) {
            return true;
        }
    }
    if (pc != 0ULL && (pc & 3ULL) == 0ULL) {
        uint32_t insn = *(const uint32_t *)(uintptr_t)pc;
        if ((insn & 0xFFE0001FU) == 0xD4200000U) {
            return true;
        }
    }
    return false;
}

static void henge_jit_trap_handler(int sig, siginfo_t *info, void *ctx) {
    if (g_expecting_jit_trap != 0 && sig == SIGTRAP && ctx != NULL) {
        ucontext_t *uc = (ucontext_t *)ctx;
        if (is_known_jit_trap_pc((uint64_t)uc->uc_mcontext->__ss.__pc)) {
            uc->uc_mcontext->__ss.__pc += 4;
            uc->uc_mcontext->__ss.__x[0] = 0;
            return;
        }
    }
    struct sigaction *prev = (sig == SIGTRAP) ? &g_prev_sigtrap : &g_prev_sigbus;
    if ((prev->sa_flags & SA_SIGINFO) != 0 && prev->sa_sigaction != NULL) {
        prev->sa_sigaction(sig, info, ctx);
        return;
    }
    if (prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN && prev->sa_handler != NULL) {
        prev->sa_handler(sig);
        return;
    }
    sigaction(sig, prev, NULL);
    raise(sig);
}

static void install_trap_guard_once(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sa.sa_sigaction = henge_jit_trap_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTRAP, &sa, &g_prev_sigtrap);
    sigaction(SIGBUS, &sa, &g_prev_sigbus);
}

void henge_jit_install_trap_guard(void) {
    pthread_once(&g_trap_once, install_trap_guard_once);
}

static void release_low_va_hold(size_t bytes) {
    if (g_jit_low_hold_released || bytes > HENGE_DEFAULT_JIT_POOL_BYTES) {
        return;
    }
    vm_address_t start = ((vm_address_t)(uintptr_t)g_jit_low_hold + 16383U) & ~(vm_address_t)16383U;
    (void)vm_deallocate(mach_task_self(), start, (vm_size_t)HENGE_DEFAULT_JIT_POOL_BYTES);
    g_jit_low_hold_released = true;
}

static void restore_low_va_hold(size_t bytes) {
    if (!g_jit_low_hold_released || bytes > HENGE_DEFAULT_JIT_POOL_BYTES) {
        return;
    }
    vm_address_t start = ((vm_address_t)(uintptr_t)g_jit_low_hold + 16383U) & ~(vm_address_t)16383U;
    if (vm_allocate(mach_task_self(), &start, (vm_size_t)HENGE_DEFAULT_JIT_POOL_BYTES, VM_FLAGS_FIXED) == KERN_SUCCESS) {
        g_jit_low_hold_released = false;
    }
}

static bool verify_rx_rw_selftest(uint8_t *rx, uint8_t *rw, size_t bytes) {
    /* movz w0, #42 ; ret */
    static const uint32_t kCode[2] = {0x52800540U, 0xD65F03C0U};
    static const uint32_t kZero[2] = {0U, 0U};
    if (rx == NULL || rw == NULL || bytes < (size_t)HENGE_HOST_PAGE_SIZE + 16U) {
        return false;
    }
    /* Offset +4 preserves byte-0 0x69 TXM page-blessing markers on first/last pages. */
    const size_t offsets[2] = {4U, bytes - (size_t)HENGE_HOST_PAGE_SIZE + 4U};
    for (int i = 0; i < 2; i++) {
        size_t off = offsets[i];
        memcpy(rw + off, kCode, sizeof(kCode));
        sys_icache_invalidate(rx + off, sizeof(kCode));

        uint32_t readback[2] = {0U, 0U};
        memcpy(readback, rx + off, sizeof(readback));
        if (readback[0] != kCode[0] || readback[1] != kCode[1]) {
            memcpy(rw + off, kZero, sizeof(kZero));
            sys_icache_invalidate(rx + off, sizeof(kZero));
            return false;
        }
        int (*fn)(void) = (int (*)(void))(void *)(rx + off);
        int res = fn();
        memcpy(rw + off, kZero, sizeof(kZero));
        sys_icache_invalidate(rx + off, sizeof(kZero));
        if (res != 42) {
            return false;
        }
    }
    return true;
}

bool henge_jit_acquire_pool(size_t bytes, bool detach_after, HengeJitPool *out_pool) {
    if (bytes == 0U) {
        bytes = (size_t)HENGE_DEFAULT_JIT_POOL_BYTES;
    }
    bytes = (bytes + ((size_t)HENGE_HOST_PAGE_SIZE - 1U)) & ~((size_t)HENGE_HOST_PAGE_SIZE - 1U);

    pthread_mutex_lock(&g_pool_mutex);
    if (atomic_load_explicit(&g_pool_live, memory_order_acquire)) {
        if (out_pool != NULL) {
            *out_pool = g_active_pool;
        }
        pthread_mutex_unlock(&g_pool_mutex);
        return true;
    }

    henge_jit_install_trap_guard();

    if (!henge_txm_is_ptraced()) {
        set_jit_status("Waiting for active debugger (P_TRACED)");
        pthread_mutex_unlock(&g_pool_mutex);
        return false;
    }

    g_expecting_jit_trap = 1;
    atomic_signal_fence(memory_order_seq_cst);
    uint64_t probe = henge_jit26_probe();
    atomic_signal_fence(memory_order_seq_cst);
    g_expecting_jit_trap = 0;

    if ((probe & 0xFFFFFFFFULL) != 0xE0000069ULL) {
        set_jit_status("Debugger attached; waiting for brk #0x69 trap handler");
        pthread_mutex_unlock(&g_pool_mutex);
        return false;
    }

    release_low_va_hold(bytes);

    uintptr_t rx = 0U;
    for (int attempt = 0; attempt < 3; attempt++) {
        g_expecting_jit_trap = 1;
        atomic_signal_fence(memory_order_seq_cst);
        rx = henge_jit26_prepare_region(0U, bytes);
        atomic_signal_fence(memory_order_seq_cst);
        g_expecting_jit_trap = 0;
        if (rx != 0U) {
            break;
        }
        struct timespec ts = {0, 50000000L};
        nanosleep(&ts, NULL);
    }

    if (rx == 0U) {
        restore_low_va_hold(bytes);
        set_jit_status("Failed: debugger returned NULL RX region");
        pthread_mutex_unlock(&g_pool_mutex);
        return false;
    }
    if (!henge_txm_is_valid_jit_range(rx, bytes)) {
        vm_deallocate(mach_task_self(), (vm_address_t)rx, (vm_size_t)bytes);
        restore_low_va_hold(bytes);
        set_jit_status("Failed: RX range outside TXM low-VA bounds (< 64 GiB)");
        pthread_mutex_unlock(&g_pool_mutex);
        return false;
    }

    vm_address_t rw = 0;
    vm_prot_t cur_prot = VM_PROT_NONE;
    vm_prot_t max_prot = VM_PROT_NONE;
    kern_return_t kr = KERN_NO_SPACE;
    const uintptr_t step = 16ULL << 20;
    const uintptr_t reach = 2ULL << 30;
    for (uintptr_t off = 0; off <= reach && kr != KERN_SUCCESS; off += step) {
        for (int side = 0; side < 2 && kr != KERN_SUCCESS; side++) {
            if (side == 1 && rx < HENGE_TXM_MIN_VA + bytes + off + step) {
                continue;
            }
            uintptr_t want = (side == 0) ? (rx + bytes + off) : (rx - bytes - off);
            rw = (vm_address_t)want;
            kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes, 0, VM_FLAGS_FIXED,
                          mach_task_self(), (vm_address_t)rx, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
        }
    }
    if (kr != KERN_SUCCESS) {
        rw = 0;
        kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes, 0, VM_FLAGS_ANYWHERE,
                      mach_task_self(), (vm_address_t)rx, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
        if (kr == KERN_SUCCESS && (uintptr_t)rw == rx) {
            vm_deallocate(mach_task_self(), rw, (vm_size_t)bytes);
            kr = KERN_INVALID_ADDRESS;
        }
    }
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), (vm_address_t)rx, (vm_size_t)bytes);
        restore_low_va_hold(bytes);
        set_jit_status("Failed: vm_remap RW alias (%s)", mach_error_string(kr));
        pthread_mutex_unlock(&g_pool_mutex);
        return false;
    }

    kr = vm_protect(mach_task_self(), rw, (vm_size_t)bytes, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), rw, (vm_size_t)bytes);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, (vm_size_t)bytes);
        restore_low_va_hold(bytes);
        set_jit_status("Failed: vm_protect RW (%s, cur=0x%x max=0x%x)",
                       mach_error_string(kr), (unsigned int)cur_prot, (unsigned int)max_prot);
        pthread_mutex_unlock(&g_pool_mutex);
        return false;
    }

    if (!verify_rx_rw_selftest((uint8_t *)(uintptr_t)rx, (uint8_t *)(uintptr_t)rw, bytes)) {
        vm_deallocate(mach_task_self(), rw, (vm_size_t)bytes);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, (vm_size_t)bytes);
        restore_low_va_hold(bytes);
        set_jit_status("Failed: TXM selftest rejected RX execution");
        pthread_mutex_unlock(&g_pool_mutex);
        return false;
    }

    g_active_pool.rx_base = rx;
    g_active_pool.rw_base = (uintptr_t)rw;
    g_active_pool.size = bytes;
    g_active_pool.blessed = true;
    g_active_pool.dual_mapped = true;
    atomic_store_explicit(&g_pool_live, true, memory_order_release);

    if (detach_after && henge_txm_is_ptraced()) {
        g_expecting_jit_trap = 1;
        atomic_signal_fence(memory_order_seq_cst);
        henge_jit26_detach();
        atomic_signal_fence(memory_order_seq_cst);
        g_expecting_jit_trap = 0;
    }

    set_jit_status("Blessed (%zu MiB TXM RX/RW)", bytes >> 20);
    if (out_pool != NULL) {
        *out_pool = g_active_pool;
    }
    pthread_mutex_unlock(&g_pool_mutex);
    return true;
}
#else
void henge_jit_install_trap_guard(void) {
}

bool henge_jit_acquire_pool(size_t bytes, bool detach_after, HengeJitPool *out_pool) {
    (void)bytes;
    (void)detach_after;
    (void)out_pool;
    set_jit_status("TXM breakpoint JIT unavailable on this host");
    return false;
}
#endif

bool henge_jit_current_pool(HengeJitPool *out_pool) {
    if (!atomic_load_explicit(&g_pool_live, memory_order_acquire)) {
        return false;
    }
    pthread_mutex_lock(&g_pool_mutex);
    bool live = atomic_load_explicit(&g_pool_live, memory_order_acquire);
    if (live && out_pool != NULL) {
        *out_pool = g_active_pool;
    }
    pthread_mutex_unlock(&g_pool_mutex);
    return live;
}

const char *henge_jit_status_message(void) {
    return g_jit_status;
}

void henge_jit_copy_status(char *buf, size_t cap) {
    if (buf == NULL || cap == 0U) {
        return;
    }
    pthread_mutex_lock(&g_status_mutex);
    snprintf(buf, cap, "%s", g_jit_status);
    pthread_mutex_unlock(&g_status_mutex);
}

void *henge_alloc_ledger_exempt_ram(size_t size, bool *out_ledger_exempt) {
    if (out_ledger_exempt != NULL) {
        *out_ledger_exempt = false;
    }
    if (size == 0U || (size & (HENGE_HOST_PAGE_SIZE - 1ULL)) != 0U) {
        return NULL;
    }

#if defined(__APPLE__)
    /*
     * Allocate via MAP_MEM_NAMED_CREATE + mach_memory_entry_ownership(...,
     * VM_LEDGER_FLAG_NO_FOOTPRINT) + vm_map() so every lazily faulted guest
     * RAM page charges the ledger-exempt VM object even after PT_DETACH.
     */
    memory_object_size_t entry_size = (memory_object_size_t)size;
    mach_port_t mem_entry = MACH_PORT_NULL;
    kern_return_t kr = mach_make_memory_entry_64(
        mach_task_self(),
        &entry_size,
        0,
        MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE,
        &mem_entry,
        MACH_PORT_NULL
    );
    if (kr == KERN_SUCCESS && mem_entry != MACH_PORT_NULL) {
        bool exempt = false;
        if (henge_txm_is_cs_debugged()) {
            kern_return_t own_kr = mach_memory_entry_ownership(
                mem_entry,
                mach_task_self(),
                VM_LEDGER_TAG_DEFAULT,
                VM_LEDGER_FLAG_NO_FOOTPRINT
            );
            exempt = (own_kr == KERN_SUCCESS);
        }

        vm_address_t mapped_addr = 0;
        vm_address_t align_mask = ((size & ((2ULL * 1024ULL * 1024ULL) - 1ULL)) == 0U)
            ? (vm_address_t)((2ULL * 1024ULL * 1024ULL) - 1ULL)
            : (vm_address_t)(HENGE_HOST_PAGE_SIZE - 1ULL);
        kern_return_t map_kr = vm_map(
            mach_task_self(),
            &mapped_addr,
            (vm_size_t)size,
            align_mask,
            VM_FLAGS_ANYWHERE,
            mem_entry,
            0,
            FALSE,
            VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE,
            VM_INHERIT_NONE
        );
        mach_port_deallocate(mach_task_self(), mem_entry);
        if (map_kr == KERN_SUCCESS && mapped_addr != 0) {
            if (out_ledger_exempt != NULL) {
                *out_ledger_exempt = exempt;
            }
            return (void *)(uintptr_t)mapped_addr;
        }
    }

    vm_address_t fallback_addr = 0;
    if (vm_allocate(mach_task_self(), &fallback_addr, (vm_size_t)size, VM_FLAGS_ANYWHERE) == KERN_SUCCESS &&
        fallback_addr != 0) {
        return (void *)(uintptr_t)fallback_addr;
    }
    return NULL;
#else
    void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ptr == MAP_FAILED) {
        return NULL;
    }
    return ptr;
#endif
}

void henge_free_ledger_exempt_ram(void *ptr, size_t size) {
    if (ptr == NULL || size == 0U || (size & (HENGE_HOST_PAGE_SIZE - 1ULL)) != 0U) {
        return;
    }
#if defined(__APPLE__)
    vm_deallocate(mach_task_self(), (vm_address_t)(uintptr_t)ptr, (vm_size_t)size);
#else
    munmap(ptr, size);
#endif
}
