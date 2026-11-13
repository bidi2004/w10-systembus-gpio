#ifndef KWT_NICE_H
#define KWT_NICE_H
#include <stdint.h>
/* ABI v5 (verify5), RV32 little endian, 4-byte aligned buffers visible to the NICE ICB master.
 * LOAD_X: 99x64 int16 input (3168 words) into accelerator X SRAM.
 * RUN:    5634 words: [Mmax, shift] + 4 x [64 bias, 64 M, 64 rows x 20 packed W10 words]
 *         streamed during compute; 99x256 int16 output written to y (12672 words).
 * v5b: the 32-bit word at (x - 4) / (params - 4) counts the words already written by the
 *      producer; the engine polls it and never reads unpublished words. A producer that has
 *      finished before the call simply stores the full count (3168 / 5634).
 *      Each input/parameter buffer reserves one writable progress word at base-4. */
#define KWT_X_WORDS 3168u
#define KWT_P_WORDS 5634u
#define KWT_Y_WORDS 12672u
#if defined(__riscv) && __riscv_xlen == 32
static inline void kwt_fence(void) { __asm__ volatile("fence rw,rw" ::: "memory"); }
static inline uint32_t kwt_load_x(const void *x) {
    uint32_t r;
    __asm__ volatile(".insn r 0x7b, 7, 1, %0, %1, %2" : "=r"(r)
                     : "r"((uintptr_t)x), "r"(KWT_X_WORDS) : "memory");
    return r;
}
static inline uint32_t kwt_run(const void *params, void *y) {
    uint32_t r;
    __asm__ volatile(".insn r 0x7b, 7, 3, %0, %1, %2" : "=r"(r)
                     : "r"((uintptr_t)params), "r"((uintptr_t)y) : "memory");
    return r;
}
static inline int kwt_ffn1(const int16_t *x, const uint32_t *params, int16_t *y) {
    if (((uintptr_t)x | (uintptr_t)params | (uintptr_t)y) & 3u) return -1;
    kwt_fence();
    if (kwt_load_x(x) || kwt_run(params, y)) return -2;
    kwt_fence();
    return 0;
}
/* Call only AFTER the platform has completed all X/parameter writes and made
 * them visible to the CPU/NICE master. No magic address or host progress
 * protocol is needed by this entry point. Buffers must not overlap. */
static inline int kwt_ffn1_preloaded(const int16_t *x, const uint32_t *params, int16_t *y) {
    if (((uintptr_t)x | (uintptr_t)params | (uintptr_t)y) & 3u) return -1;
    if ((uintptr_t)x < 4u || (uintptr_t)params < 4u) return -1;
    kwt_fence();
    ((volatile uint32_t *)x)[-1] = KWT_X_WORDS;
    ((volatile uint32_t *)params)[-1] = KWT_P_WORDS;
    kwt_fence();
    return kwt_ffn1(x, params, y);
}
#endif
#endif
