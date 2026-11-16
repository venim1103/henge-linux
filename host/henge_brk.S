/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * ARM64 debugserver handshake traps for iOS 26/27 TXM page blessing
 * (StikDebug / universal.js / LLDB protocol: brk #0xf00d -> 0xd43e01a0, LE bytes a0013ed4).
 */

#if defined(__aarch64__) || defined(__arm64__)

#if defined(__APPLE__)
#define HENGE_ASM_GLUE(a, b) a##b
#define HENGE_ASM_SYM(name) HENGE_ASM_GLUE(_, name)
#define HENGE_ASM_FUNC(name) \
    .globl HENGE_ASM_SYM(name) ; \
    HENGE_ASM_SYM(name):
#define HENGE_ASM_END(name)
#else
#define HENGE_ASM_FUNC(name) \
    .globl name ; \
    .type name, %function ; \
    name:
#define HENGE_ASM_END(name) \
    .size name, .-name
#endif

.text
.p2align 4

HENGE_ASM_FUNC(henge_jit26_probe)
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x0, #0
    brk     #0x69
    ret
    .cfi_endproc
HENGE_ASM_END(henge_jit26_probe)

HENGE_ASM_FUNC(henge_jit26_prepare_region)
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x16, #1
    brk     #0xf00d
    ret
    .cfi_endproc
HENGE_ASM_END(henge_jit26_prepare_region)

HENGE_ASM_FUNC(henge_jit26_detach)
    .cfi_startproc
    hint    #34             /* bti c */
    mov     x16, #0
    brk     #0xf00d
    ret
    .cfi_endproc
HENGE_ASM_END(henge_jit26_detach)

#endif /* __aarch64__ || __arm64__ */

#if defined(__linux__)
.section .note.GNU-stack,"",%progbits
#endif
