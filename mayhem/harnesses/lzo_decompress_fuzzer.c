/*
 * lzo_decompress_fuzzer.c — libFuzzer harness driving LZO's SAFE decompressors on attacker bytes.
 *
 * Ported faithfully from the OSS-Fuzz `lzo` project's lzo_decompress_target.c (Apache-2.0, Google
 * Inc. 2018). The harness feeds the raw fuzz input as a compressed stream into one of LZO's
 * `*_decompress_safe` variants (the bounds-checked decompressors — the intended fuzz surface), with
 * the variant selected by `size % NUM_DECOMP` so a single corpus exercises every LZO format. The
 * output buffer is bounded to LZO's default 256KB block size; the safe decompressors must never
 * write past it. Any OOB read/write or other UB is caught by ASan/UBSan from $SANITIZER_FLAGS.
 *
 * This file is additive (lives under mayhem/) and includes only upstream public headers.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "lzo1b.h"
#include "lzo1c.h"
#include "lzo1f.h"
#include "lzo1x.h"
#include "lzo1y.h"
#include "lzo1z.h"
#include "lzo2a.h"
#include "lzoconf.h"

typedef int (*decompress_function)(const lzo_bytep, lzo_uint, lzo_bytep,
                                   lzo_uintp, lzo_voidp);

#define NUM_DECOMP 7

static decompress_function funcArr[NUM_DECOMP] = {
    &lzo1b_decompress_safe, &lzo1c_decompress_safe, &lzo1f_decompress_safe,
    &lzo1x_decompress_safe, &lzo1y_decompress_safe, &lzo1z_decompress_safe,
    &lzo2a_decompress_safe};

/* LZO (de)compresses data in blocks; the default block size is 256KB. The output
 * buffer is sized to one block — the safe decompressor must respect this bound. */
static const size_t kBufSize = 256 * 1024L;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  int r;
  lzo_uint new_len;
  if (size < 1) {
    return 0;
  }

  unsigned char *__LZO_MMODEL buf = (unsigned char *)malloc(kBufSize);
  if (!buf) {
    /* OOM here is out of scope. */
    return 0;
  }

  static bool isInit = false;
  if (!isInit) {
    if (lzo_init() != LZO_E_OK) {
      free(buf);
      return 0;
    }
    isInit = true;
  }

  /* Select a safe decompressor deterministically from the input length. */
  int idx = (int)(size % NUM_DECOMP);
  new_len = kBufSize;
  /* Work memory is not needed for decompression. */
  r = (*funcArr[idx])((const lzo_bytep)data, (lzo_uint)size, (lzo_bytep)buf,
                      &new_len, /*wrkmem=*/NULL);
  (void)r;

  free(buf);
  return 0;
}
