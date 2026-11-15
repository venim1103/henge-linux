/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * hvsparse: Zero-skipping sparse disk image container for henge-linux.
 * Compresses raw UEFI/GPT disk images by eliding all-zero 64 KiB chunks
 * so multi-gigabyte Arch Linux images fit comfortably in iOS app containers.
 */

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HVSPARSE_MAGIC      0x50535648U /* "HVSP" little-endian */
#define HVSPARSE_VERSION    1U
#define HVSPARSE_BLOCK_SIZE (64U * 1024U)

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t version;
    uint32_t block_size;
    uint32_t block_count;
    uint64_t virtual_size;
    uint64_t data_offset;
} HvSparseHeader;

static bool is_zero_block(const uint8_t *buf, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (buf[i] != 0U) {
            return false;
        }
    }
    return true;
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
    rewind(in);

    uint32_t block_count = (uint32_t)((virtual_size + HVSPARSE_BLOCK_SIZE - 1ULL) / HVSPARSE_BLOCK_SIZE);
    uint64_t table_bytes = (uint64_t)block_count * sizeof(uint64_t);
    uint64_t data_offset = sizeof(HvSparseHeader) + table_bytes;

    uint64_t *offsets = calloc(block_count > 0 ? block_count : 1U, sizeof(uint64_t));
    uint8_t *buf = malloc(HVSPARSE_BLOCK_SIZE);
    if (offsets == NULL || buf == NULL) {
        free(offsets);
        free(buf);
        fclose(in);
        return 1;
    }

    FILE *out = fopen(sparse_path, "wb");
    if (out == NULL) {
        fprintf(stderr, "hvsparse: cannot open output '%s': %s\n", sparse_path, strerror(errno));
        free(offsets);
        free(buf);
        fclose(in);
        return 1;
    }

    HvSparseHeader hdr = {
        .magic = HVSPARSE_MAGIC,
        .version = HVSPARSE_VERSION,
        .block_size = HVSPARSE_BLOCK_SIZE,
        .block_count = block_count,
        .virtual_size = virtual_size,
        .data_offset = data_offset,
    };

    if (fwrite(&hdr, sizeof(hdr), 1, out) != 1 ||
        (block_count > 0 && fwrite(offsets, sizeof(uint64_t), block_count, out) != block_count)) {
        fclose(out);
        free(offsets);
        free(buf);
        fclose(in);
        return 1;
    }

    uint64_t cursor = data_offset;
    uint32_t non_zero_blocks = 0U;

    for (uint32_t i = 0; i < block_count; i++) {
        memset(buf, 0, HVSPARSE_BLOCK_SIZE);
        size_t n = fread(buf, 1, HVSPARSE_BLOCK_SIZE, in);
        if (n == 0 && ferror(in)) {
            fclose(out);
            free(offsets);
            free(buf);
            fclose(in);
            return 1;
        }
        if (!is_zero_block(buf, HVSPARSE_BLOCK_SIZE)) {
            if (fwrite(buf, 1, HVSPARSE_BLOCK_SIZE, out) != HVSPARSE_BLOCK_SIZE) {
                fclose(out);
                free(offsets);
                free(buf);
                fclose(in);
                return 1;
            }
            offsets[i] = cursor;
            cursor += HVSPARSE_BLOCK_SIZE;
            non_zero_blocks++;
        }
    }

    if (fseeko(out, (off_t)sizeof(HvSparseHeader), SEEK_SET) != 0 ||
        (block_count > 0 && fwrite(offsets, sizeof(uint64_t), block_count, out) != block_count)) {
        fclose(out);
        free(offsets);
        free(buf);
        fclose(in);
        return 1;
    }

    fclose(out);
    free(offsets);
    free(buf);
    fclose(in);

    printf("[hvsparse] packed %llu bytes -> %u/%u non-zero blocks (%llu bytes on disk)\n",
           (unsigned long long)virtual_size,
           non_zero_blocks,
           block_count,
           (unsigned long long)cursor);
    return 0;
}

static int cmd_unpack(const char *sparse_path, const char *raw_path) {
    FILE *in = fopen(sparse_path, "rb");
    if (in == NULL) {
        fprintf(stderr, "hvsparse: cannot open sparse '%s': %s\n", sparse_path, strerror(errno));
        return 1;
    }

    HvSparseHeader hdr;
    if (fread(&hdr, sizeof(hdr), 1, in) != 1 ||
        hdr.magic != HVSPARSE_MAGIC ||
        hdr.version != HVSPARSE_VERSION ||
        hdr.block_size != HVSPARSE_BLOCK_SIZE) {
        fprintf(stderr, "hvsparse: invalid header in '%s'\n", sparse_path);
        fclose(in);
        return 1;
    }

    uint64_t *offsets = calloc(hdr.block_count > 0 ? hdr.block_count : 1U, sizeof(uint64_t));
    uint8_t *buf = malloc(HVSPARSE_BLOCK_SIZE);
    if (offsets == NULL || buf == NULL) {
        free(offsets);
        free(buf);
        fclose(in);
        return 1;
    }

    if (hdr.block_count > 0 &&
        fread(offsets, sizeof(uint64_t), hdr.block_count, in) != hdr.block_count) {
        free(offsets);
        free(buf);
        fclose(in);
        return 1;
    }

    FILE *out = fopen(raw_path, "wb");
    if (out == NULL) {
        fprintf(stderr, "hvsparse: cannot open output '%s': %s\n", raw_path, strerror(errno));
        free(offsets);
        free(buf);
        fclose(in);
        return 1;
    }

    uint64_t remaining = hdr.virtual_size;
    for (uint32_t i = 0; i < hdr.block_count; i++) {
        size_t to_write = remaining < HVSPARSE_BLOCK_SIZE ? (size_t)remaining : HVSPARSE_BLOCK_SIZE;
        if (offsets[i] == 0ULL) {
            memset(buf, 0, to_write);
        } else {
            if (fseeko(in, (off_t)offsets[i], SEEK_SET) != 0 ||
                fread(buf, 1, HVSPARSE_BLOCK_SIZE, in) != HVSPARSE_BLOCK_SIZE) {
                fclose(out);
                free(offsets);
                free(buf);
                fclose(in);
                return 1;
            }
        }
        if (fwrite(buf, 1, to_write, out) != to_write) {
            fclose(out);
            free(offsets);
            free(buf);
            fclose(in);
            return 1;
        }
        remaining -= to_write;
    }

    fclose(out);
    free(offsets);
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
