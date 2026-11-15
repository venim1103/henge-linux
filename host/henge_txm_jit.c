/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif

#include "henge_txm_jit.h"
#include "henge_platform.h"

#include <sys/mman.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/types.h>
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
uintptr_t henge_jit26_prepare_region(uintptr_t hint, size_t size) {
    (void)hint;
    (void)size;
    return 0U;
}

void henge_jit26_detach(void) {
}
#endif

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
        kern_return_t map_kr = vm_map(
            mach_task_self(),
            &mapped_addr,
            (vm_size_t)size,
            (vm_address_t)(HENGE_HOST_PAGE_SIZE - 1ULL),
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
#endif

    void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ptr == MAP_FAILED) {
        return NULL;
    }
    return ptr;
}

void henge_free_ledger_exempt_ram(void *ptr, size_t size) {
    if (ptr == NULL || size == 0U) {
        return;
    }
#if defined(__APPLE__)
    vm_deallocate(mach_task_self(), (vm_address_t)(uintptr_t)ptr, (vm_size_t)size);
#else
    munmap(ptr, size);
#endif
}
