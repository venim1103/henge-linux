/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__)
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#endif

#include "henge_qcow2.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>
#if defined(HENGE_HAVE_ZSTD)
#include <zstd.h>
#endif

#if defined(__APPLE__)
#include <sys/clonefile.h>
#endif

#define QCOW2_MAGIC               0x514649FBU
#define QCOW2_MIN_CLUSTER_BITS    9U
#define QCOW2_MAX_CLUSTER_BITS    21U
#define QCOW2_INCOMPAT_DIRTY      (1ULL << 0)
#define QCOW2_INCOMPAT_CORRUPT    (1ULL << 1)
#define QCOW2_INCOMPAT_DATA_FILE  (1ULL << 2)
#define QCOW2_INCOMPAT_COMP_TYPE  (1ULL << 3)
#define QCOW2_INCOMPAT_EXT_L2     (1ULL << 4)
#define QCOW2_OFLAG_COMPRESSED    (1ULL << 62)
#define QCOW2_L2_OFFSET_MASK      0x00FFFFFFFFFFFE00ULL
#define QCOW2_L1_OFFSET_MASK      0x00FFFFFFFFFFFE00ULL
#define QCOW2_EXT_L2_SUBCLUSTERS  32U

static void set_err(char *buf, size_t cap, const char *msg) {
    if (buf != NULL && cap > 0U) {
        snprintf(buf, cap, "%s", (msg != NULL) ? msg : "unknown error");
    }
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) |
           ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |
           ((uint32_t)p[3]);
}

static uint64_t read_be64(const uint8_t *p) {
    return ((uint64_t)read_be32(p) << 32) | (uint64_t)read_be32(p + 4);
}

static bool is_all_zero(const uint8_t *buf, size_t len) {
    size_t i = 0U;
    while (i + sizeof(uint64_t) <= len) {
        uint64_t v = 0ULL;
        memcpy(&v, buf + i, sizeof(v));
        if (v != 0ULL) {
            return false;
        }
        i += sizeof(uint64_t);
    }
    while (i < len) {
        if (buf[i] != 0U) {
            return false;
        }
        i++;
    }
    return true;
}

static int pread_exact(int fd, void *buf, size_t len, uint64_t offset) {
    uint8_t *dst = (uint8_t *)buf;
    size_t done = 0U;
    while (done < len) {
        ssize_t n = pread(fd, dst + done, len - done, (off_t)(offset + done));
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            return -1;
        }
        done += (size_t)n;
    }
    return 0;
}

static int pwrite_exact(int fd, const void *buf, size_t len, uint64_t offset) {
    const uint8_t *src = (const uint8_t *)buf;
    size_t done = 0U;
    while (done < len) {
        ssize_t n = pwrite(fd, src + done, len - done, (off_t)(offset + done));
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            return -1;
        }
        done += (size_t)n;
    }
    return 0;
}

HengeImageFormat henge_detect_image_format(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return HENGE_IMG_FORMAT_UNKNOWN;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return HENGE_IMG_FORMAT_UNKNOWN;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return HENGE_IMG_FORMAT_UNKNOWN;
    }

    uint8_t hdr[8] = {0};
    ssize_t n = pread(fd, hdr, sizeof(hdr), 0);
    if (n >= 8 && memcmp(hdr, "HVSPARSE", 8) == 0) {
        close(fd);
        return HENGE_IMG_FORMAT_HVSPARSE;
    }
    if (n >= 4 && read_be32(hdr) == QCOW2_MAGIC) {
        close(fd);
        return HENGE_IMG_FORMAT_QCOW2;
    }
    if ((uint64_t)st.st_size >= 0x8006ULL) {
        uint8_t iso_sig[5] = {0};
        if (pread(fd, iso_sig, sizeof(iso_sig), 0x8001) == 5 &&
            memcmp(iso_sig, "CD001", 5) == 0) {
            close(fd);
            return HENGE_IMG_FORMAT_ISO9660;
        }
    }
    close(fd);
    return (st.st_size > 0) ? HENGE_IMG_FORMAT_RAW : HENGE_IMG_FORMAT_UNKNOWN;
}

uint32_t henge_iso_preferred_block_size(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return 512U;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 512U;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || (uint64_t)st.st_size < 0x881EU) {
        close(fd);
        return 512U;
    }

    uint8_t pvd[6] = {0};
    if (pread(fd, pvd, sizeof(pvd), 0x8000) != 6 || memcmp(pvd + 1, "CD001", 5) != 0) {
        close(fd);
        return 512U;
    }

    /* Check for 512-byte GPT header ("EFI PART" at LBA 1 = offset 0x200). */
    uint8_t gpt[8] = {0};
    if (pread(fd, gpt, sizeof(gpt), 0x200) == 8 && memcmp(gpt, "EFI PART", 8) == 0) {
        close(fd);
        return 512U;
    }

    /* Check for a populated MBR partition table (isohybrid optical image). */
    uint8_t mbr[512] = {0};
    if (pread(fd, mbr, sizeof(mbr), 0) == 512 && mbr[510] == 0x55U && mbr[511] == 0xAAU) {
        for (int p = 0; p < 4; p++) {
            uint8_t ptype = mbr[446 + p * 16 + 4];
            if (ptype != 0U) {
                close(fd);
                return 512U;
            }
        }
    }

    /* Check for El Torito boot record volume descriptor at sector 17 (0x8800). */
    uint8_t bvd[32] = {0};
    if (pread(fd, bvd, sizeof(bvd), 0x8800) == 32 &&
        bvd[0] == 0x00U &&
        memcmp(bvd + 1, "CD001", 5) == 0 &&
        memcmp(bvd + 7, "EL TORITO SPECIFICATION", 23) == 0) {
        close(fd);
        return 2048U;
    }

    close(fd);
    return 512U;
}

bool henge_qcow2_has_zstd(void) {
#if defined(HENGE_HAVE_ZSTD)
    return true;
#else
    return false;
#endif
}

static int parse_qcow2_header(int fd,
                              uint64_t file_size,
                              HengeQcow2Info *info,
                              uint32_t *out_l1_size,
                              uint64_t *out_l1_offset,
                              char *err_buf,
                              size_t err_cap) {
    uint8_t hdr[112];
    memset(hdr, 0, sizeof(hdr));
    if (file_size < 72ULL || pread_exact(fd, hdr, 72U, 0ULL) != 0) {
        set_err(err_buf, err_cap, "File is too small to contain a valid QCOW2 header.");
        return -1;
    }

    uint32_t magic = read_be32(hdr + 0);
    if (magic != QCOW2_MAGIC) {
        set_err(err_buf, err_cap, "Invalid QCOW2 magic bytes.");
        return -1;
    }

    uint32_t version = read_be32(hdr + 4);
    if (version != 2U && version != 3U) {
        set_err(err_buf, err_cap, "Unsupported QCOW2 version (only v2 and v3 are supported).");
        return -1;
    }

    uint64_t backing_offset = read_be64(hdr + 8);
    uint32_t backing_size = read_be32(hdr + 16);
    uint32_t cluster_bits = read_be32(hdr + 20);
    uint64_t virtual_size = read_be64(hdr + 24);
    uint32_t crypt_method = read_be32(hdr + 32);
    uint32_t l1_size = read_be32(hdr + 36);
    uint64_t l1_offset = read_be64(hdr + 40);

    if (cluster_bits < QCOW2_MIN_CLUSTER_BITS || cluster_bits > QCOW2_MAX_CLUSTER_BITS) {
        set_err(err_buf, err_cap, "QCOW2 cluster_bits out of supported range [9, 21].");
        return -1;
    }
    if (crypt_method != 0U) {
        set_err(err_buf, err_cap, "Encrypted QCOW2 images are not supported.");
        return -1;
    }
    if (backing_offset != 0ULL || backing_size != 0U) {
        set_err(err_buf, err_cap, "QCOW2 images with external backing files are not supported.");
        return -1;
    }

    uint64_t incompat = 0ULL;
    uint8_t comp_type = 0U;
    if (version == 3U) {
        if (file_size < 104ULL || pread_exact(fd, hdr + 72, 32U, 72ULL) != 0) {
            set_err(err_buf, err_cap, "Truncated QCOW2 v3 header.");
            return -1;
        }
        incompat = read_be64(hdr + 72);
        uint32_t header_length = read_be32(hdr + 100);
        if (header_length < 104U) {
            set_err(err_buf, err_cap, "Invalid QCOW2 v3 header_length.");
            return -1;
        }
        if ((incompat & QCOW2_INCOMPAT_CORRUPT) != 0ULL) {
            set_err(err_buf, err_cap, "QCOW2 image is marked corrupt.");
            return -1;
        }
        if ((incompat & QCOW2_INCOMPAT_DATA_FILE) != 0ULL) {
            set_err(err_buf, err_cap, "QCOW2 external data files are not supported.");
            return -1;
        }
        uint64_t supported = QCOW2_INCOMPAT_DIRTY | QCOW2_INCOMPAT_COMP_TYPE | QCOW2_INCOMPAT_EXT_L2;
        if ((incompat & ~supported) != 0ULL) {
            set_err(err_buf, err_cap, "Unsupported QCOW2 incompatible feature bits.");
            return -1;
        }
        if ((incompat & QCOW2_INCOMPAT_COMP_TYPE) != 0ULL) {
            if (header_length >= 105U && file_size >= 105ULL) {
                if (pread_exact(fd, &comp_type, 1U, 104ULL) != 0) {
                    set_err(err_buf, err_cap, "Failed to read QCOW2 compression_type.");
                    return -1;
                }
            }
            if (comp_type != 0U && comp_type != 1U) {
                set_err(err_buf, err_cap, "Unsupported QCOW2 compression type (only zlib and zstd are supported).");
                return -1;
            }
#if !defined(HENGE_HAVE_ZSTD)
            if (comp_type == 1U) {
                set_err(err_buf, err_cap, "QCOW2 image uses zstd compression, which is not linked in this build.");
                return -1;
            }
#endif
        }
    }

    if ((incompat & QCOW2_INCOMPAT_EXT_L2) != 0ULL && cluster_bits < 14U) {
        /* 32 subclusters require at least 512-byte subclusters (16 KiB clusters). */
        set_err(err_buf, err_cap, "Extended L2 QCOW2 requires cluster_bits >= 14.");
        return -1;
    }

    if (l1_size > 0U) {
        uint64_t l1_bytes = (uint64_t)l1_size * 8ULL;
        if (l1_offset > file_size || l1_bytes > file_size - l1_offset) {
            set_err(err_buf, err_cap, "QCOW2 L1 table extends past end of file.");
            return -1;
        }
    }

    if (info != NULL) {
        info->version = version;
        info->cluster_bits = cluster_bits;
        info->virtual_size = virtual_size;
        info->crypt_method = crypt_method;
        info->backing_file_offset = backing_offset;
        info->backing_file_size = backing_size;
        info->incompatible_features = incompat;
        info->compression_type = comp_type;
        info->extended_l2 = (incompat & QCOW2_INCOMPAT_EXT_L2) != 0ULL;
    }
    if (out_l1_size != NULL) {
        *out_l1_size = l1_size;
    }
    if (out_l1_offset != NULL) {
        *out_l1_offset = l1_offset;
    }
    return 0;
}

int henge_qcow2_inspect(const char *qcow2_path,
                        HengeQcow2Info *out_info,
                        char *err_buf,
                        size_t err_cap) {
    if (qcow2_path == NULL || qcow2_path[0] == '\0') {
        set_err(err_buf, err_cap, "Invalid QCOW2 path.");
        return -1;
    }
    int fd = open(qcow2_path, O_RDONLY);
    if (fd < 0) {
        set_err(err_buf, err_cap, "Failed to open QCOW2 file.");
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        set_err(err_buf, err_cap, "QCOW2 path is not a regular file.");
        return -1;
    }
    int rc = parse_qcow2_header(fd, (uint64_t)st.st_size, out_info, NULL, NULL, err_buf, err_cap);
    close(fd);
    return rc;
}

static int inflate_raw_cluster(const uint8_t *in_buf,
                               size_t in_len,
                               uint8_t *out_buf,
                               size_t out_len) {
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    zs.next_in = (Bytef *)(uintptr_t)in_buf;
    zs.avail_in = (uInt)in_len;
    zs.next_out = (Bytef *)out_buf;
    zs.avail_out = (uInt)out_len;

    if (inflateInit2(&zs, -15) != Z_OK) {
        return -1;
    }
    int zrc = inflate(&zs, Z_FINISH);
    size_t produced = out_len - (size_t)zs.avail_out;
    inflateEnd(&zs);

    /* QCOW2 compressed clusters may fill the entire cluster before Z_STREAM_END. */
    if (zrc != Z_STREAM_END && !(zrc == Z_BUF_ERROR && produced == out_len) &&
        !(zrc == Z_OK && produced == out_len)) {
        return -1;
    }
    if (produced < out_len) {
        memset(out_buf + produced, 0, out_len - produced);
    }
    return 0;
}

#if defined(HENGE_HAVE_ZSTD)
static int decompress_zstd_cluster(ZSTD_DCtx *dctx,
                                   const uint8_t *in_buf,
                                   size_t in_len,
                                   uint8_t *out_buf,
                                   size_t out_len) {
    if (dctx == NULL) {
        return -1;
    }
    ZSTD_DCtx_reset(dctx, ZSTD_reset_session_only);
    ZSTD_inBuffer zin = {in_buf, in_len, 0U};
    ZSTD_outBuffer zout = {out_buf, out_len, 0U};
    while (zin.pos < zin.size && zout.pos < zout.size) {
        size_t ret = ZSTD_decompressStream(dctx, &zout, &zin);
        if (ZSTD_isError(ret)) {
            return -1;
        }
        if (ret == 0U) {
            break;
        }
    }
    if (zout.pos == 0U && in_len > 0U) {
        return -1;
    }
    if (zout.pos < out_len) {
        memset(out_buf + zout.pos, 0, out_len - zout.pos);
    }
    return 0;
}
#endif

int henge_qcow2_unpack_to_raw(const char *qcow2_path,
                              const char *raw_path,
                              uint64_t min_virtual_bytes,
                              char *err_buf,
                              size_t err_cap) {
    if (qcow2_path == NULL || raw_path == NULL || qcow2_path[0] == '\0' || raw_path[0] == '\0') {
        set_err(err_buf, err_cap, "Invalid source or destination path.");
        return -1;
    }

    int in_fd = open(qcow2_path, O_RDONLY);
    if (in_fd < 0) {
        set_err(err_buf, err_cap, "Failed to open QCOW2 file.");
        return -1;
    }
    struct stat st;
    if (fstat(in_fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(in_fd);
        set_err(err_buf, err_cap, "QCOW2 source is not a regular file.");
        return -1;
    }
    uint64_t file_size = (uint64_t)st.st_size;

    HengeQcow2Info info;
    uint32_t l1_size = 0U;
    uint64_t l1_offset = 0ULL;
    if (parse_qcow2_header(in_fd, file_size, &info, &l1_size, &l1_offset, err_buf, err_cap) != 0) {
        close(in_fd);
        return -1;
    }

    uint64_t target_size = info.virtual_size;
    if (min_virtual_bytes > target_size) {
        target_size = min_virtual_bytes;
    }

    int out_fd = open(raw_path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        close(in_fd);
        set_err(err_buf, err_cap, "Failed to create destination raw disk file.");
        return -1;
    }
    if (ftruncate(out_fd, (off_t)target_size) != 0) {
        close(out_fd);
        close(in_fd);
        unlink(raw_path);
        set_err(err_buf, err_cap, "Failed to size sparse raw disk image.");
        return -1;
    }

    if (info.virtual_size == 0ULL || l1_size == 0U) {
        close(out_fd);
        close(in_fd);
        return 0;
    }

    size_t cluster_size = (size_t)1U << info.cluster_bits;
    size_t l2_entry_bytes = info.extended_l2 ? 16U : 8U;
    size_t l2_entries = cluster_size / l2_entry_bytes;

    uint8_t *l1_buf = (uint8_t *)malloc((size_t)l1_size * 8U);
    uint8_t *l2_buf = (uint8_t *)malloc(cluster_size);
    uint8_t *cluster_buf = (uint8_t *)malloc(cluster_size);
    uint8_t *comp_buf = NULL;
    size_t comp_buf_cap = 0U;

    if (l1_buf == NULL || l2_buf == NULL || cluster_buf == NULL) {
        free(l1_buf);
        free(l2_buf);
        free(cluster_buf);
        close(out_fd);
        close(in_fd);
        unlink(raw_path);
        set_err(err_buf, err_cap, "Out of memory allocating QCOW2 buffers.");
        return -1;
    }

#if defined(HENGE_HAVE_ZSTD)
    ZSTD_DCtx *zstd_ctx = (info.compression_type == 1U) ? ZSTD_createDCtx() : NULL;
#endif

    int rc = 0;
    if (pread_exact(in_fd, l1_buf, (size_t)l1_size * 8U, l1_offset) != 0) {
        set_err(err_buf, err_cap, "Failed to read QCOW2 L1 table.");
        rc = -1;
        goto cleanup;
    }

    uint32_t csize_shift = 62U - (info.cluster_bits - 8U);
    uint64_t csize_mask = (1ULL << (info.cluster_bits - 8U)) - 1ULL;
    uint64_t coffset_mask = (1ULL << csize_shift) - 1ULL;

    for (uint32_t l1_idx = 0U; l1_idx < l1_size; l1_idx++) {
        uint64_t l1_entry = read_be64(l1_buf + (size_t)l1_idx * 8U);
        uint64_t l2_offset = l1_entry & QCOW2_L1_OFFSET_MASK;
        if (l2_offset == 0ULL) {
            continue;
        }
        if (l2_offset > file_size || (uint64_t)cluster_size > file_size - l2_offset) {
            set_err(err_buf, err_cap, "QCOW2 L2 table extends past end of file.");
            rc = -1;
            goto cleanup;
        }
        if (pread_exact(in_fd, l2_buf, cluster_size, l2_offset) != 0) {
            set_err(err_buf, err_cap, "Failed to read QCOW2 L2 table.");
            rc = -1;
            goto cleanup;
        }

        for (size_t l2_idx = 0U; l2_idx < l2_entries; l2_idx++) {
            uint64_t guest_cluster = ((uint64_t)l1_idx * (uint64_t)l2_entries) + (uint64_t)l2_idx;
            uint64_t guest_off = guest_cluster << info.cluster_bits;
            if (guest_off >= info.virtual_size) {
                break;
            }
            size_t write_len = cluster_size;
            if (info.virtual_size - guest_off < (uint64_t)write_len) {
                write_len = (size_t)(info.virtual_size - guest_off);
            }

            const uint8_t *ent_ptr = l2_buf + l2_idx * l2_entry_bytes;
            uint64_t l2_entry = read_be64(ent_ptr);
            if (l2_entry == 0ULL) {
                continue;
            }

            if ((l2_entry & QCOW2_OFLAG_COMPRESSED) != 0ULL) {
                uint64_t coffset = l2_entry & coffset_mask;
                uint64_t nb_csectors = ((l2_entry >> csize_shift) & csize_mask) + 1ULL;
                uint64_t comp_bytes = nb_csectors * 512ULL - (coffset & 511ULL);
                if (coffset >= file_size) {
                    set_err(err_buf, err_cap, "QCOW2 compressed cluster offset out of range.");
                    rc = -1;
                    goto cleanup;
                }
                if (comp_bytes > file_size - coffset) {
                    comp_bytes = file_size - coffset;
                }
                if (comp_bytes == 0ULL || comp_bytes > (64ULL << 20)) {
                    set_err(err_buf, err_cap, "Invalid QCOW2 compressed cluster size.");
                    rc = -1;
                    goto cleanup;
                }
                if ((size_t)comp_bytes > comp_buf_cap) {
                    uint8_t *grown = (uint8_t *)realloc(comp_buf, (size_t)comp_bytes);
                    if (grown == NULL) {
                        set_err(err_buf, err_cap, "Out of memory growing compressed buffer.");
                        rc = -1;
                        goto cleanup;
                    }
                    comp_buf = grown;
                    comp_buf_cap = (size_t)comp_bytes;
                }
                if (pread_exact(in_fd, comp_buf, (size_t)comp_bytes, coffset) != 0) {
                    set_err(err_buf, err_cap, "Failed to read QCOW2 compressed cluster.");
                    rc = -1;
                    goto cleanup;
                }
                if (info.compression_type == 1U) {
#if defined(HENGE_HAVE_ZSTD)
                    if (decompress_zstd_cluster(zstd_ctx, comp_buf, (size_t)comp_bytes, cluster_buf, cluster_size) != 0) {
                        set_err(err_buf, err_cap, "Failed to decompress zstd-compressed QCOW2 cluster.");
                        rc = -1;
                        goto cleanup;
                    }
#else
                    set_err(err_buf, err_cap, "QCOW2 image uses zstd compression, which is not linked in this build.");
                    rc = -1;
                    goto cleanup;
#endif
                } else if (inflate_raw_cluster(comp_buf, (size_t)comp_bytes, cluster_buf, cluster_size) != 0) {
                    set_err(err_buf, err_cap, "Failed to inflate zlib-compressed QCOW2 cluster.");
                    rc = -1;
                    goto cleanup;
                }
                if (!is_all_zero(cluster_buf, write_len)) {
                    if (pwrite_exact(out_fd, cluster_buf, write_len, guest_off) != 0) {
                        set_err(err_buf, err_cap, "Failed to write unpacked compressed cluster.");
                        rc = -1;
                        goto cleanup;
                    }
                }
            } else if (info.extended_l2) {
                uint64_t host_off = l2_entry & QCOW2_L2_OFFSET_MASK;
                uint64_t sub_bitmap = read_be64(ent_ptr + 8);
                uint32_t alloc_mask = (uint32_t)(sub_bitmap & 0xFFFFFFFFULL);
                uint32_t zero_mask = (uint32_t)(sub_bitmap >> 32);
                uint32_t active_mask = alloc_mask & ~zero_mask;
                if (host_off == 0ULL || active_mask == 0U) {
                    continue;
                }
                size_t sub_size = cluster_size / QCOW2_EXT_L2_SUBCLUSTERS;
                for (uint32_t s = 0U; s < QCOW2_EXT_L2_SUBCLUSTERS; s++) {
                    if ((active_mask & (1U << s)) == 0U) {
                        continue;
                    }
                    uint64_t sub_guest_off = guest_off + (uint64_t)s * (uint64_t)sub_size;
                    if (sub_guest_off >= info.virtual_size) {
                        break;
                    }
                    size_t sub_write = sub_size;
                    if (info.virtual_size - sub_guest_off < (uint64_t)sub_write) {
                        sub_write = (size_t)(info.virtual_size - sub_guest_off);
                    }
                    uint64_t sub_host_off = host_off + (uint64_t)s * (uint64_t)sub_size;
                    if (sub_host_off > file_size || (uint64_t)sub_write > file_size - sub_host_off) {
                        set_err(err_buf, err_cap, "QCOW2 extended-L2 subcluster out of range.");
                        rc = -1;
                        goto cleanup;
                    }
                    if (pread_exact(in_fd, cluster_buf, sub_write, sub_host_off) != 0) {
                        set_err(err_buf, err_cap, "Failed to read QCOW2 extended-L2 subcluster.");
                        rc = -1;
                        goto cleanup;
                    }
                    if (!is_all_zero(cluster_buf, sub_write)) {
                        if (pwrite_exact(out_fd, cluster_buf, sub_write, sub_guest_off) != 0) {
                            set_err(err_buf, err_cap, "Failed to write QCOW2 extended-L2 subcluster.");
                            rc = -1;
                            goto cleanup;
                        }
                    }
                }
            } else {
                /* Standard uncompressed L2 cluster: bit 0 is zero-cluster flag. */
                if ((l2_entry & 1ULL) != 0ULL) {
                    continue;
                }
                uint64_t host_off = l2_entry & QCOW2_L2_OFFSET_MASK;
                if (host_off == 0ULL) {
                    continue;
                }
                if (host_off > file_size || (uint64_t)write_len > file_size - host_off) {
                    set_err(err_buf, err_cap, "QCOW2 data cluster extends past end of file.");
                    rc = -1;
                    goto cleanup;
                }
                if (pread_exact(in_fd, cluster_buf, write_len, host_off) != 0) {
                    set_err(err_buf, err_cap, "Failed to read QCOW2 data cluster.");
                    rc = -1;
                    goto cleanup;
                }
                if (!is_all_zero(cluster_buf, write_len)) {
                    if (pwrite_exact(out_fd, cluster_buf, write_len, guest_off) != 0) {
                        set_err(err_buf, err_cap, "Failed to write unpacked QCOW2 cluster.");
                        rc = -1;
                        goto cleanup;
                    }
                }
            }
        }
    }

cleanup:
#if defined(HENGE_HAVE_ZSTD)
    if (zstd_ctx != NULL) {
        ZSTD_freeDCtx(zstd_ctx);
    }
#endif
    free(comp_buf);
    free(cluster_buf);
    free(l2_buf);
    free(l1_buf);
    close(out_fd);
    close(in_fd);
    if (rc != 0) {
        unlink(raw_path);
    }
    return rc;
}

int henge_create_sparse_raw_disk(const char *raw_path,
                                 uint64_t virtual_bytes,
                                 char *err_buf,
                                 size_t err_cap) {
    if (raw_path == NULL || raw_path[0] == '\0' || virtual_bytes < 4096ULL) {
        set_err(err_buf, err_cap, "Invalid sparse raw disk parameters.");
        return -1;
    }
    uint64_t aligned = (virtual_bytes + 4095ULL) & ~4095ULL;
    int fd = open(raw_path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        set_err(err_buf, err_cap, "Failed to create sparse raw disk file.");
        return -1;
    }
    if (ftruncate(fd, (off_t)aligned) != 0) {
        close(fd);
        unlink(raw_path);
        set_err(err_buf, err_cap, "Failed to allocate sparse disk size.");
        return -1;
    }
    close(fd);
    return 0;
}

int henge_expand_sparse_raw_disk(const char *raw_path,
                                 uint64_t new_virtual_bytes,
                                 uint64_t *out_final_bytes,
                                 char *err_buf,
                                 size_t err_cap) {
    if (out_final_bytes != NULL) {
        *out_final_bytes = 0ULL;
    }
    if (raw_path == NULL || raw_path[0] == '\0' || new_virtual_bytes < 4096ULL ||
        new_virtual_bytes > ((uint64_t)INT64_MAX - 4095ULL)) {
        set_err(err_buf, err_cap, "Invalid disk expansion parameters.");
        return -1;
    }
    uint64_t aligned = (new_virtual_bytes + 4095ULL) & ~4095ULL;
    int fd = open(raw_path, O_RDWR);
    if (fd < 0) {
        set_err(err_buf, err_cap, "Failed to open raw disk image for expansion.");
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        set_err(err_buf, err_cap, "Disk expansion target is not a regular file.");
        return -1;
    }
    uint64_t current = (st.st_size > 0) ? (uint64_t)st.st_size : 0ULL;
    if (aligned <= current) {
        close(fd);
        if (out_final_bytes != NULL) {
            *out_final_bytes = current;
        }
        return 0;
    }
    if (ftruncate(fd, (off_t)aligned) != 0) {
        close(fd);
        set_err(err_buf, err_cap, "Failed to extend sparse raw disk image via ftruncate.");
        return -1;
    }
    close(fd);
    if (out_final_bytes != NULL) {
        *out_final_bytes = aligned;
    }
    return 0;
}

int henge_clone_file_apfs(const char *src_path,
                          const char *dst_path,
                          char *err_buf,
                          size_t err_cap) {
    if (src_path == NULL || dst_path == NULL || src_path[0] == '\0' || dst_path[0] == '\0') {
        set_err(err_buf, err_cap, "Invalid clone source or destination path.");
        return -1;
    }

    unlink(dst_path);
#if defined(__APPLE__)
    if (clonefile(src_path, dst_path, 0) == 0) {
        return 0;
    }
#endif

    int in_fd = open(src_path, O_RDONLY);
    if (in_fd < 0) {
        set_err(err_buf, err_cap, "Failed to open source file for cloning.");
        return -1;
    }
    struct stat st;
    if (fstat(in_fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(in_fd);
        set_err(err_buf, err_cap, "Clone source is not a regular file.");
        return -1;
    }
    int out_fd = open(dst_path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        close(in_fd);
        set_err(err_buf, err_cap, "Failed to create destination clone file.");
        return -1;
    }
    if (ftruncate(out_fd, st.st_size) != 0) {
        close(out_fd);
        close(in_fd);
        unlink(dst_path);
        set_err(err_buf, err_cap, "Failed to size destination clone file.");
        return -1;
    }

    const size_t chunk = 65536U;
    uint8_t *buf = (uint8_t *)malloc(chunk);
    if (buf == NULL) {
        close(out_fd);
        close(in_fd);
        unlink(dst_path);
        set_err(err_buf, err_cap, "Out of memory during file clone.");
        return -1;
    }

    uint64_t off = 0ULL;
    uint64_t total = (uint64_t)st.st_size;
    int rc = 0;
    while (off < total) {
        size_t to_read = ((total - off) < (uint64_t)chunk) ? (size_t)(total - off) : chunk;
        if (pread_exact(in_fd, buf, to_read, off) != 0) {
            set_err(err_buf, err_cap, "Read error during sparse file clone.");
            rc = -1;
            break;
        }
        if (!is_all_zero(buf, to_read)) {
            if (pwrite_exact(out_fd, buf, to_read, off) != 0) {
                set_err(err_buf, err_cap, "Write error during sparse file clone.");
                rc = -1;
                break;
            }
        }
        off += (uint64_t)to_read;
    }

    free(buf);
    close(out_fd);
    close(in_fd);
    if (rc != 0) {
        unlink(dst_path);
    }
    return rc;
}

int henge_compact_sparse_file(const char *path,
                              uint64_t *out_bytes_reclaimed,
                              char *err_buf,
                              size_t err_cap) {
    if (out_bytes_reclaimed != NULL) {
        *out_bytes_reclaimed = 0ULL;
    }
    if (path == NULL || path[0] == '\0') {
        set_err(err_buf, err_cap, "Invalid file path for disk compaction.");
        return -1;
    }

    int fd = open(path, O_RDWR);
    if (fd < 0) {
        set_err(err_buf, err_cap, "Failed to open disk image for compaction.");
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        set_err(err_buf, err_cap, "Compaction target is not a regular file.");
        return -1;
    }

    const size_t block_size = 65536U;
    uint8_t *buf = (uint8_t *)malloc(block_size);
    if (buf == NULL) {
        close(fd);
        set_err(err_buf, err_cap, "Out of memory during disk compaction.");
        return -1;
    }

    uint64_t total = (uint64_t)st.st_size;
    uint64_t reclaimed = 0ULL;
    for (uint64_t off = 0ULL; off + (uint64_t)block_size <= total; off += (uint64_t)block_size) {
        if (pread_exact(fd, buf, block_size, off) != 0) {
            break;
        }
        if (!is_all_zero(buf, block_size)) {
            continue;
        }
#if defined(__APPLE__)
        struct fpunchhole fp;
        memset(&fp, 0, sizeof(fp));
        fp.fp_offset = (off_t)off;
        fp.fp_length = (off_t)block_size;
        if (fcntl(fd, F_PUNCHHOLE, &fp) == 0) {
            reclaimed += (uint64_t)block_size;
        }
#elif defined(__linux__)
        if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, (off_t)off, (off_t)block_size) == 0) {
            reclaimed += (uint64_t)block_size;
        }
#endif
    }

    free(buf);
    close(fd);
    if (out_bytes_reclaimed != NULL) {
        *out_bytes_reclaimed = reclaimed;
    }
    return 0;
}
