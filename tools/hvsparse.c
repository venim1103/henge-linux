/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * hvsparse: Streaming zero-skipping sparse disk archive packer/unpacker
 * compatible with upstream WindowsiOS host/hvsparse.c ("HVSPARSE" v1):
 *   - 8-byte magic: "HVSPARSE"
 *   - 8-byte little-endian uint64_t virtual disk size
 *   - Sequence of [uint64_t offset, uint64_t len] (len <= 8 MiB) records
 *     followed by raw extent payload bytes
 *   - Terminated by {0ULL, 0ULL}
 */

#if !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#endif

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define HVSPARSE_MAGIC_STR      "HVSPARSE"
#define HVSPARSE_MAGIC_LEN      8U
#define HVSPARSE_SCAN_BLOCK     (64U * 1024U)
#define HVSPARSE_MAX_EXTENT     (8U * 1024U * 1024U) /* 8 MiB max record size in upstream hvsparse.c */
#define HVSPARSE_MAX_VIRT_BYTES (8ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL) /* 8 TiB */

typedef struct __attribute__((packed)) {
    char magic[8];
    uint64_t virtual_size;
} HvSparseStreamHeader;

typedef struct __attribute__((packed)) {
    uint64_t offset;
    uint64_t length;
} HvSparseExtentRecord;

static bool is_zero_block(const uint8_t *buf, size_t len) {
    size_t i = 0;
    for (; i + sizeof(uint64_t) <= len; i += sizeof(uint64_t)) {
        uint64_t word = 0ULL;
        memcpy(&word, buf + i, sizeof(word));
        if (word != 0ULL) {
            return false;
        }
    }
    for (; i < len; i++) {
        if (buf[i] != 0U) {
            return false;
        }
    }
    return true;
}

static bool flush_extent(FILE *out,
                         uint64_t extent_offset,
                         const uint8_t *extent_buf,
                         size_t extent_len) {
    if (extent_len == 0U) {
        return true;
    }
    HvSparseExtentRecord rec = {
        .offset = extent_offset,
        .length = (uint64_t)extent_len,
    };
    return fwrite(&rec, sizeof(rec), 1, out) == 1 &&
           fwrite(extent_buf, 1, extent_len, out) == extent_len;
}

static int cmd_pack(const char *raw_path, const char *sparse_path) {
    FILE *in = fopen(raw_path, "rb");
    if (in == NULL) {
        fprintf(stderr, "hvsparse: cannot open input '%s': %s\n", raw_path, strerror(errno));
        return 1;
    }

    if (fseeko(in, 0, SEEK_END) != 0) {
        fclose(in);
        return 1;
    }
    off_t end_off = ftello(in);
    if (end_off < 0) {
        fclose(in);
        return 1;
    }
    uint64_t virtual_size = (uint64_t)end_off;
    if (virtual_size > HVSPARSE_MAX_VIRT_BYTES ||
        virtual_size > (uint64_t)INT64_MAX - HVSPARSE_MAX_EXTENT) {
        fprintf(stderr, "hvsparse: input size out of safe range (%llu)\n",
                (unsigned long long)virtual_size);
        fclose(in);
        return 1;
    }
    rewind(in);

    uint8_t *scan_buf = malloc(HVSPARSE_SCAN_BLOCK);
    uint8_t *extent_buf = malloc(HVSPARSE_MAX_EXTENT);
    if (scan_buf == NULL || extent_buf == NULL) {
        free(scan_buf);
        free(extent_buf);
        fclose(in);
        return 1;
    }

    FILE *out = fopen(sparse_path, "wb");
    if (out == NULL) {
        fprintf(stderr, "hvsparse: cannot open output '%s': %s\n", sparse_path, strerror(errno));
        free(scan_buf);
        free(extent_buf);
        fclose(in);
        return 1;
    }

    HvSparseStreamHeader hdr;
    memcpy(hdr.magic, HVSPARSE_MAGIC_STR, HVSPARSE_MAGIC_LEN);
    hdr.virtual_size = virtual_size;
    if (fwrite(&hdr, sizeof(hdr), 1, out) != 1) {
        fclose(out);
        unlink(sparse_path);
        free(scan_buf);
        free(extent_buf);
        fclose(in);
        return 1;
    }

    uint64_t cursor = 0ULL;
    uint64_t extent_offset = 0ULL;
    size_t extent_len = 0U;
    uint64_t non_zero_bytes = 0ULL;
    uint64_t extent_count = 0ULL;

    while (cursor < virtual_size) {
        uint64_t rem = virtual_size - cursor;
        size_t chunk_len = rem < HVSPARSE_SCAN_BLOCK ? (size_t)rem : HVSPARSE_SCAN_BLOCK;
        size_t total_read = 0U;
        while (total_read < chunk_len) {
            size_t n = fread(scan_buf + total_read, 1, chunk_len - total_read, in);
            if (n == 0U) {
                break;
            }
            total_read += n;
        }
        if (total_read != chunk_len) {
            fprintf(stderr, "hvsparse: short read at offset %llu in '%s'\n",
                    (unsigned long long)cursor, raw_path);
            fclose(out);
            unlink(sparse_path);
            free(scan_buf);
            free(extent_buf);
            fclose(in);
            return 1;
        }

        if (is_zero_block(scan_buf, chunk_len)) {
            if (extent_len > 0U) {
                if (!flush_extent(out, extent_offset, extent_buf, extent_len)) {
                    fclose(out);
                    unlink(sparse_path);
                    free(scan_buf);
                    free(extent_buf);
                    fclose(in);
                    return 1;
                }
                extent_count++;
                extent_len = 0U;
            }
        } else {
            if (extent_len > 0U && extent_len + chunk_len > HVSPARSE_MAX_EXTENT) {
                if (!flush_extent(out, extent_offset, extent_buf, extent_len)) {
                    fclose(out);
                    unlink(sparse_path);
                    free(scan_buf);
                    free(extent_buf);
                    fclose(in);
                    return 1;
                }
                extent_count++;
                extent_len = 0U;
            }
            if (extent_len == 0U) {
                extent_offset = cursor;
            }
            memcpy(extent_buf + extent_len, scan_buf, chunk_len);
            extent_len += chunk_len;
            non_zero_bytes += (uint64_t)chunk_len;
        }

        cursor += (uint64_t)chunk_len;
    }

    if (extent_len > 0U) {
        if (!flush_extent(out, extent_offset, extent_buf, extent_len)) {
            fclose(out);
            unlink(sparse_path);
            free(scan_buf);
            free(extent_buf);
            fclose(in);
            return 1;
        }
        extent_count++;
    }

    HvSparseExtentRecord eof_rec = {0ULL, 0ULL};
    if (fwrite(&eof_rec, sizeof(eof_rec), 1, out) != 1 || fflush(out) != 0) {
        fclose(out);
        unlink(sparse_path);
        free(scan_buf);
        free(extent_buf);
        fclose(in);
        return 1;
    }

    off_t out_end = ftello(out);
    uint64_t on_disk_bytes = out_end > 0 ? (uint64_t)out_end : 0ULL;

    if (fclose(out) != 0) {
        unlink(sparse_path);
        free(scan_buf);
        free(extent_buf);
        fclose(in);
        return 1;
    }
    free(scan_buf);
    free(extent_buf);
    fclose(in);

    printf("[hvsparse] packed %llu bytes -> %llu extents (%llu non-zero bytes, %llu bytes on disk)\n",
           (unsigned long long)virtual_size,
           (unsigned long long)extent_count,
           (unsigned long long)non_zero_bytes,
           (unsigned long long)on_disk_bytes);
    return 0;
}

static int cmd_unpack(const char *sparse_path, const char *raw_path) {
    FILE *in = fopen(sparse_path, "rb");
    if (in == NULL) {
        fprintf(stderr, "hvsparse: cannot open sparse '%s': %s\n", sparse_path, strerror(errno));
        return 1;
    }

    if (fseeko(in, 0, SEEK_END) != 0) {
        fclose(in);
        return 1;
    }
    off_t sparse_end = ftello(in);
    if (sparse_end < (off_t)sizeof(HvSparseStreamHeader)) {
        fprintf(stderr, "hvsparse: truncated header in '%s'\n", sparse_path);
        fclose(in);
        return 1;
    }
    rewind(in);

    HvSparseStreamHeader hdr;
    if (fread(&hdr, sizeof(hdr), 1, in) != 1 ||
        memcmp(hdr.magic, HVSPARSE_MAGIC_STR, HVSPARSE_MAGIC_LEN) != 0) {
        fprintf(stderr, "hvsparse: invalid HVSPARSE magic in '%s'\n", sparse_path);
        fclose(in);
        return 1;
    }

    if (hdr.virtual_size > HVSPARSE_MAX_VIRT_BYTES ||
        hdr.virtual_size > (uint64_t)INT64_MAX - HVSPARSE_MAX_EXTENT) {
        fprintf(stderr, "hvsparse: virtual_size out of safe range in '%s'\n", sparse_path);
        fclose(in);
        return 1;
    }

    uint8_t *buf = malloc(HVSPARSE_MAX_EXTENT);
    if (buf == NULL) {
        fclose(in);
        return 1;
    }

    FILE *out = fopen(raw_path, "wb");
    if (out == NULL) {
        fprintf(stderr, "hvsparse: cannot open output '%s': %s\n", raw_path, strerror(errno));
        free(buf);
        fclose(in);
        return 1;
    }

    if (ftruncate(fileno(out), (off_t)hdr.virtual_size) != 0) {
        fprintf(stderr, "hvsparse: ftruncate failed on '%s': %s\n", raw_path, strerror(errno));
        fclose(out);
        unlink(raw_path);
        free(buf);
        fclose(in);
        return 1;
    }

    bool saw_terminator = false;
    while (true) {
        HvSparseExtentRecord rec;
        size_t nrec = fread(&rec, sizeof(rec), 1, in);
        if (nrec == 0U && feof(in)) {
            break;
        }
        if (nrec != 1U) {
            fprintf(stderr, "hvsparse: truncated extent header in '%s'\n", sparse_path);
            fclose(out);
            unlink(raw_path);
            free(buf);
            fclose(in);
            return 1;
        }
        if (rec.offset == 0ULL && rec.length == 0ULL) {
            saw_terminator = true;
            break;
        }
        if (rec.length == 0ULL ||
            rec.length > (uint64_t)HVSPARSE_MAX_EXTENT ||
            rec.offset > hdr.virtual_size ||
            rec.length > hdr.virtual_size - rec.offset) {
            fprintf(stderr, "hvsparse: invalid extent [offset=%llu, len=%llu] for size %llu in '%s'\n",
                    (unsigned long long)rec.offset,
                    (unsigned long long)rec.length,
                    (unsigned long long)hdr.virtual_size,
                    sparse_path);
            fclose(out);
            unlink(raw_path);
            free(buf);
            fclose(in);
            return 1;
        }

        size_t len = (size_t)rec.length;
        size_t got = 0U;
        while (got < len) {
            size_t n = fread(buf + got, 1, len - got, in);
            if (n == 0U) {
                break;
            }
            got += n;
        }
        if (got != len ||
            fseeko(out, (off_t)rec.offset, SEEK_SET) != 0 ||
            fwrite(buf, 1, len, out) != len) {
            fprintf(stderr, "hvsparse: failed writing extent at %llu in '%s'\n",
                    (unsigned long long)rec.offset, raw_path);
            fclose(out);
            unlink(raw_path);
            free(buf);
            fclose(in);
            return 1;
        }
    }

    if (!saw_terminator && hdr.virtual_size > 0ULL) {
        fprintf(stderr, "hvsparse: warning: missing {0,0} terminator in '%s'\n", sparse_path);
    }

    if (fflush(out) != 0 || ftruncate(fileno(out), (off_t)hdr.virtual_size) != 0 || fclose(out) != 0) {
        unlink(raw_path);
        free(buf);
        fclose(in);
        return 1;
    }
    free(buf);
    fclose(in);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <pack|unpack> <input> <output>\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "pack") == 0) {
        return cmd_pack(argv[2], argv[3]);
    }
    if (strcmp(argv[1], "unpack") == 0) {
        return cmd_unpack(argv[2], argv[3]);
    }
    fprintf(stderr, "hvsparse: unknown subcommand '%s'\n", argv[1]);
    return 2;
}
