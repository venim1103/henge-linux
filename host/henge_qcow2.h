/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_QCOW2_H
#define HENGE_QCOW2_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum HengeImageFormat {
    HENGE_IMG_FORMAT_UNKNOWN  = 0,
    HENGE_IMG_FORMAT_HVSPARSE = 1,
    HENGE_IMG_FORMAT_QCOW2    = 2,
    HENGE_IMG_FORMAT_ISO9660  = 3,
    HENGE_IMG_FORMAT_RAW      = 4
} HengeImageFormat;

typedef struct HengeQcow2Info {
    uint32_t version;
    uint32_t cluster_bits;
    uint64_t virtual_size;
    uint32_t crypt_method;
    uint64_t backing_file_offset;
    uint32_t backing_file_size;
    uint64_t incompatible_features;
    uint8_t  compression_type;
    bool     extended_l2;
} HengeQcow2Info;

/*
 * Classify a guest disk or media file by magic bytes:
 *   - "HVSPARSE" at offset 0       -> HENGE_IMG_FORMAT_HVSPARSE
 *   - "QFI\xfb" at offset 0        -> HENGE_IMG_FORMAT_QCOW2
 *   - "CD001" at offset 0x8001     -> HENGE_IMG_FORMAT_ISO9660
 *   - Any other non-empty file     -> HENGE_IMG_FORMAT_RAW
 */
HengeImageFormat henge_detect_image_format(const char *path);

/*
 * Return the preferred logical block size for an attached secondary image:
 *   - 2048 for pure El Torito ISO-9660 optical images (lacking a 512-byte GPT/MBR)
 *   - 512 for isohybrid ISOs, CIDATA seeds, and standard disk images
 */
uint32_t henge_iso_preferred_block_size(const char *path);

/* Return true if this build was compiled with libzstd QCOW2 cluster support. */
bool henge_qcow2_has_zstd(void);

/*
 * Inspect and validate a QCOW2 v2/v3 header without unpacking.
 * Fails closed (-1) on encrypted, backing-file, corrupt, or unsupported images.
 */
int henge_qcow2_inspect(const char *qcow2_path,
                        HengeQcow2Info *out_info,
                        char *err_buf,
                        size_t err_cap);

/*
 * Stream-unpack a QCOW2 v2/v3 image (uncompressed, zlib-compressed, zero, and
 * Extended L2 subclusters) into an APFS/ext4 sparse raw file at `raw_path`.
 * If `min_virtual_bytes` exceeds the QCOW2 virtual size, the output sparse raw
 * file is extended to `min_virtual_bytes` via ftruncate().
 * Unlinks `raw_path` and returns -1 on any error.
 */
int henge_qcow2_unpack_to_raw(const char *qcow2_path,
                              const char *raw_path,
                              uint64_t min_virtual_bytes,
                              char *err_buf,
                              size_t err_cap);

/*
 * Create a new sparse raw disk image of `virtual_bytes` (aligned up to 4 KiB).
 */
int henge_create_sparse_raw_disk(const char *raw_path,
                                 uint64_t virtual_bytes,
                                 char *err_buf,
                                 size_t err_cap);

/*
 * Copy-on-write clone a file using APFS clonefile(2) on Darwin, falling back
 * to a sparse-preserving copy on non-APFS volumes and Linux.
 */
int henge_clone_file_apfs(const char *src_path,
                          const char *dst_path,
                          char *err_buf,
                          size_t err_cap);

/*
 * Reclaim all-zero 64 KiB blocks in a raw disk image using F_PUNCHHOLE on
 * Darwin/APFS or FALLOC_FL_PUNCH_HOLE on Linux.
 */
int henge_compact_sparse_file(const char *path,
                              uint64_t *out_bytes_reclaimed,
                              char *err_buf,
                              size_t err_cap);

#ifdef __cplusplus
}
#endif

#endif /* HENGE_QCOW2_H */
