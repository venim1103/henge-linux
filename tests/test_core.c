/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "henge_platform.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_unix_socket_path_bounds(void) {
    char out[HENGE_DARWIN_SUN_PATH_MAX];

    /* Short path fits directly within Darwin's 104-byte sockaddr_un.sun_path. */
    int rc = henge_format_unix_socket_path("/var/tmp/henge", "share.sock", out, sizeof(out));
    assert(rc == 0);
    assert(strcmp(out, "/var/tmp/henge/share.sock") == 0);
    assert(strlen(out) < HENGE_DARWIN_SUN_PATH_MAX);

    /* Deep iOS sandbox path (>104 bytes) falls back cleanly to deterministic /tmp/hl-<hash>. */
    const char *deep_ios_sandbox =
        "/var/mobile/Containers/Data/Application/12345678-90AB-CDEF-1234-567890ABCDEF/Documents/Machines/ArchLinux";
    assert(strlen(deep_ios_sandbox) >= HENGE_DARWIN_SUN_PATH_MAX);

    rc = henge_format_unix_socket_path(deep_ios_sandbox, "share.sock", out, sizeof(out));
    assert(rc == 0);
    assert(strlen(out) < HENGE_DARWIN_SUN_PATH_MAX);
    assert(strncmp(out, "/tmp/hl-", 8) == 0);
}

static void test_mmu_granule_decoding(void) {
    /* TTBR0 encodings */
    assert(henge_decode_granule_bits(0x0U, 0) == 12U); /* 4 KiB */
    assert(henge_decode_granule_bits(0x2U, 0) == 14U); /* 16 KiB */
    assert(henge_decode_granule_bits(0x1U, 0) == 16U); /* 64 KiB */
    assert(henge_decode_granule_bits(0x3U, 0) == 0U);  /* Reserved */

    /* TTBR1 encodings */
    assert(henge_decode_granule_bits(0x2U, 1) == 12U); /* 4 KiB */
    assert(henge_decode_granule_bits(0x1U, 1) == 14U); /* 16 KiB */
    assert(henge_decode_granule_bits(0x3U, 1) == 16U); /* 64 KiB */
    assert(henge_decode_granule_bits(0x0U, 1) == 0U);  /* Reserved */
}

static void test_guest_ram_alignment(void) {
    /* iPhone 16 Pro (8 GB device cap -> 4096 MiB ceiling, 2560 MiB requested). */
    uint64_t bytes = henge_align_guest_ram_bytes(2560U, 4096U);
    assert(bytes == (2560ULL * 1024ULL * 1024ULL));
    assert((bytes & (HENGE_HOST_PAGE_SIZE - 1ULL)) == 0ULL);

    /* Clamping above device cap. */
    uint64_t clamped = henge_align_guest_ram_bytes(6144U, 3072U);
    assert(clamped == (3072ULL * 1024ULL * 1024ULL));

    /* Clamping below minimum floor. */
    uint64_t floored = henge_align_guest_ram_bytes(128U, 4096U);
    assert(floored == (512ULL * 1024ULL * 1024ULL));
}

static void test_render_pause_lifecycle_gate(void) {
    assert(hengelinux_is_render_paused() == false);
    hengelinux_set_render_paused(true);
    assert(hengelinux_is_render_paused() == true);
    hengelinux_set_render_paused(false);
    assert(hengelinux_is_render_paused() == false);
}

int main(void) {
    test_unix_socket_path_bounds();
    test_mmu_granule_decoding();
    test_guest_ram_alignment();
    test_render_pause_lifecycle_gate();
    printf("[PASS] test_core: all platform, MMU granule, RAM alignment, and lifecycle checks passed.\n");
    return 0;
}
