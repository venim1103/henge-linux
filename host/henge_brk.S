/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * ARM64 debugserver handshake traps for iOS 26/27 TXM page blessing
 * (StikDebug / universal.js / LLDB protocol: brk #0xf00d -> 0xa0013ed4).
 */

#if defined(__aarch64__) || defined(__arm64__)

.text
.align 4

#if defined(__APPLE__)
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
#else
.globl henge_jit26_prepare_region
.type henge_jit26_prepare_region, %function
henge_jit26_prepare_region:
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x16, #1
    brk     #0xf00d
    ret
    .cfi_endproc

.globl henge_jit26_detach
.type henge_jit26_detach, %function
henge_jit26_detach:
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x16, #0
    brk     #0xf00d
    ret
    .cfi_endproc

.section .note.GNU-stack,"",%progbits
#endif

#endif /* __aarch64__ || __arm64__ */
