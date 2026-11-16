/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * ARM64 debugserver handshake traps for iOS 26/27 TXM page blessing
 * (StikDebug / universal.js / LLDB protocol: brk #0xf00d -> 0xd43e01a0, LE bytes a0013ed4).
 */

#if defined(__aarch64__) || defined(__arm64__)

.text
.p2align 4

#if defined(__APPLE__)
.globl _henge_jit26_probe
_henge_jit26_probe:
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x0, #0
    mov     x16, #0
    brk     #0x69
    ret
    .cfi_endproc

.globl _henge_jit26_prepare_region
_henge_jit26_prepare_region:
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x16, #1
    brk     #0xf00d
    ret
    .cfi_endproc

.globl _henge_jit26_detach
_henge_jit26_detach:
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x16, #0
    brk     #0xf00d
    ret
    .cfi_endproc

.subsections_via_symbols
#else
.globl henge_jit26_probe
.type henge_jit26_probe, %function
henge_jit26_probe:
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x0, #0
    mov     x16, #0
    brk     #0x69
    ret
    .cfi_endproc
.size henge_jit26_probe, .-henge_jit26_probe

.globl henge_jit26_prepare_region
.type henge_jit26_prepare_region, %function
henge_jit26_prepare_region:
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x16, #1
    brk     #0xf00d
    ret
    .cfi_endproc
.size henge_jit26_prepare_region, .-henge_jit26_prepare_region

.globl henge_jit26_detach
.type henge_jit26_detach, %function
henge_jit26_detach:
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x16, #0
    brk     #0xf00d
    ret
    .cfi_endproc
.size henge_jit26_detach, .-henge_jit26_detach
#endif

#endif /* __aarch64__ || __arm64__ */

#if defined(__linux__)
.section .note.GNU-stack,"",%progbits
#endif
