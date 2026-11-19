/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#endif

#include "henge_cidata.h"

#include <ctype.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * FAT16 geometry:
 *   - 512 bytes/sector, 1 sector/cluster
 *   - 4224 total sectors (~2.06 MiB)
 *   - 1 reserved sector, 2 FATs x 17 sectors (34), 32 root dir sectors (512 entries)
 *   - 4157 data clusters (>= 4085 -> strictly FAT16 per Microsoft FAT spec)
 */
#define CIDATA_SECTOR_SIZE     512U
#define CIDATA_TOTAL_SECTORS   4224U
#define CIDATA_RSVD_SECTORS    1U
#define CIDATA_NUM_FATS        2U
#define CIDATA_FAT_SECTORS     17U
#define CIDATA_ROOT_ENTRIES    512U
#define CIDATA_ROOT_SECTORS    32U
#define CIDATA_DATA_START_SEC  (CIDATA_RSVD_SECTORS + CIDATA_NUM_FATS * CIDATA_FAT_SECTORS + CIDATA_ROOT_SECTORS)
#define CIDATA_IMAGE_BYTES     (CIDATA_TOTAL_SECTORS * CIDATA_SECTOR_SIZE)

static void set_err(char *buf, size_t cap, const char *msg) {
    if (buf != NULL && cap > 0U) {
        snprintf(buf, cap, "%s", (msg != NULL) ? msg : "unknown error");
    }
}

static void put_le16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFFU);
    p[1] = (uint8_t)((v >> 8) & 0xFFU);
}

static void put_le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFFU);
    p[1] = (uint8_t)((v >> 8) & 0xFFU);
    p[2] = (uint8_t)((v >> 16) & 0xFFU);
    p[3] = (uint8_t)((v >> 24) & 0xFFU);
}

static uint8_t lfn_checksum(const uint8_t short_name[11]) {
    uint8_t sum = 0U;
    for (int i = 0; i < 11; i++) {
        sum = (uint8_t)(((sum & 1U) ? 0x80U : 0U) + (sum >> 1) + short_name[i]);
    }
    return sum;
}

static void write_lfn_entry(uint8_t *slot,
                            uint8_t seq,
                            const char *long_name,
                            size_t name_len,
                            size_t char_offset,
                            uint8_t checksum) {
    memset(slot, 0, 32U);
    slot[0] = seq;
    slot[11] = 0x0FU; /* ATTR_LONG_NAME */
    slot[12] = 0x00U;
    slot[13] = checksum;
    slot[26] = 0x00U;
    slot[27] = 0x00U;

    static const size_t kOffsets[13] = {1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30};
    for (size_t i = 0U; i < 13U; i++) {
        size_t idx = char_offset + i;
        uint16_t ch = 0xFFFFU;
        if (idx < name_len) {
            ch = (uint16_t)(uint8_t)long_name[idx];
        } else if (idx == name_len) {
            ch = 0x0000U;
        }
        put_le16(slot + kOffsets[i], ch);
    }
}

static void fat16_set_entry(uint8_t *img, uint16_t cluster, uint16_t value) {
    uint8_t *fat0 = img + CIDATA_RSVD_SECTORS * CIDATA_SECTOR_SIZE;
    uint8_t *fat1 = fat0 + CIDATA_FAT_SECTORS * CIDATA_SECTOR_SIZE;
    put_le16(fat0 + (size_t)cluster * 2U, value);
    put_le16(fat1 + (size_t)cluster * 2U, value);
}

static int add_fat16_file(uint8_t *img,
                          size_t *root_slot_idx,
                          uint16_t *next_cluster,
                          const char *long_name,
                          const char short_name[11],
                          const uint8_t *data,
                          size_t len) {
    size_t name_len = strlen(long_name);
    size_t lfn_count = (name_len + 12U) / 13U;
    if (*root_slot_idx + lfn_count + 1U > CIDATA_ROOT_ENTRIES) {
        return -1;
    }

    uint16_t first_cluster = 0U;
    if (len > 0U) {
        size_t clusters_needed = (len + CIDATA_SECTOR_SIZE - 1U) / CIDATA_SECTOR_SIZE;
        if ((size_t)(*next_cluster) + clusters_needed >= (CIDATA_TOTAL_SECTORS - CIDATA_DATA_START_SEC + 2U)) {
            return -1;
        }
        first_cluster = *next_cluster;
        for (size_t c = 0U; c < clusters_needed; c++) {
            uint16_t clus = (uint16_t)(first_cluster + c);
            uint16_t next = (c + 1U < clusters_needed) ? (uint16_t)(clus + 1U) : 0xFFFFU;
            fat16_set_entry(img, clus, next);

            size_t sec = CIDATA_DATA_START_SEC + (size_t)(clus - 2U);
            size_t off = c * CIDATA_SECTOR_SIZE;
            size_t chunk = (len - off < CIDATA_SECTOR_SIZE) ? (len - off) : CIDATA_SECTOR_SIZE;
            memcpy(img + sec * CIDATA_SECTOR_SIZE, data + off, chunk);
        }
        *next_cluster = (uint16_t)(first_cluster + clusters_needed);
    }

    uint8_t *root_dir = img + (CIDATA_RSVD_SECTORS + CIDATA_NUM_FATS * CIDATA_FAT_SECTORS) * CIDATA_SECTOR_SIZE;
    uint8_t cksum = lfn_checksum((const uint8_t *)short_name);
    for (size_t i = lfn_count; i > 0U; i--) {
        uint8_t seq = (uint8_t)i;
        if (i == lfn_count) {
            seq |= 0x40U;
        }
        write_lfn_entry(root_dir + (*root_slot_idx) * 32U,
                        seq,
                        long_name,
                        name_len,
                        (i - 1U) * 13U,
                        cksum);
        (*root_slot_idx)++;
    }

    uint8_t *ent = root_dir + (*root_slot_idx) * 32U;
    memset(ent, 0, 32U);
    memcpy(ent, short_name, 11U);
    ent[11] = 0x20U; /* ATTR_ARCHIVE */
    put_le16(ent + 26, first_cluster);
    put_le32(ent + 28, (uint32_t)len);
    (*root_slot_idx)++;
    return 0;
}

static void sanitize_yaml_token(const char *src, char *dst, size_t cap, const char *fallback) {
    size_t out = 0U;
    if (src != NULL) {
        for (size_t i = 0U; src[i] != '\0' && out + 1U < cap; i++) {
            unsigned char c = (unsigned char)src[i];
            if (isalnum(c) || c == '-' || c == '_' || c == '.') {
                dst[out++] = (char)c;
            }
        }
    }
    if (out == 0U) {
        snprintf(dst, cap, "%s", fallback);
    } else {
        dst[out] = '\0';
    }
}

int henge_cidata_write_image(const char *out_path,
                             const HengeCidataConfig *cfg,
                             char *err_buf,
                             size_t err_cap) {
    if (out_path == NULL || out_path[0] == '\0' || cfg == NULL) {
        set_err(err_buf, err_cap, "Invalid CIDATA output path or config.");
        return -1;
    }

    char inst_id[64];
    char hostname[64];
    char username[64];
    sanitize_yaml_token(cfg->instance_id, inst_id, sizeof(inst_id), "hengelinux-01");
    sanitize_yaml_token(cfg->hostname, hostname, sizeof(hostname), "hengelinux");
    sanitize_yaml_token(cfg->username, username, sizeof(username), "linux");
    const char *password = (cfg->password != NULL && cfg->password[0] != '\0') ? cfg->password : "linux";

    /* Escape single quotes in YAML single-quoted password string. */
    char escaped_pw[256];
    size_t ep = 0U;
    for (size_t i = 0U; password[i] != '\0' && ep + 3U < sizeof(escaped_pw); i++) {
        char c = password[i];
        if (c == '\r' || c == '\n') {
            continue;
        }
        if (c == '\'') {
            escaped_pw[ep++] = '\'';
            escaped_pw[ep++] = '\'';
        } else {
            escaped_pw[ep++] = c;
        }
    }
    escaped_pw[ep] = '\0';

    char meta_data[512];
    int meta_len = snprintf(meta_data, sizeof(meta_data),
                            "instance-id: %s\n"
                            "local-hostname: %s\n",
                            inst_id, hostname);

    char user_data[4096];
    int user_len = 0;
    if (cfg->ssh_authorized_key != NULL && cfg->ssh_authorized_key[0] != '\0') {
        user_len = snprintf(user_data, sizeof(user_data),
                            "#cloud-config\n"
                            "hostname: %s\n"
                            "manage_etc_hosts: true\n"
                            "users:\n"
                            "  - name: %s\n"
                            "    groups: [sudo, wheel, adm]\n"
                            "    shell: /bin/sh\n"
                            "    sudo: ALL=(ALL) NOPASSWD:ALL\n"
                            "    lock_passwd: false\n"
                            "    plain_text_passwd: '%s'\n"
                            "    ssh_authorized_keys:\n"
                            "      - %s\n"
                            "chpasswd:\n"
                            "  expire: false\n"
                            "  list: |\n"
                            "    %s:%s\n"
                            "ssh_pwauth: true\n",
                            hostname, username, escaped_pw, cfg->ssh_authorized_key, username, password);
    } else {
        user_len = snprintf(user_data, sizeof(user_data),
                            "#cloud-config\n"
                            "hostname: %s\n"
                            "manage_etc_hosts: true\n"
                            "users:\n"
                            "  - name: %s\n"
                            "    groups: [sudo, wheel, adm]\n"
                            "    shell: /bin/sh\n"
                            "    sudo: ALL=(ALL) NOPASSWD:ALL\n"
                            "    lock_passwd: false\n"
                            "    plain_text_passwd: '%s'\n"
                            "chpasswd:\n"
                            "  expire: false\n"
                            "  list: |\n"
                            "    %s:%s\n"
                            "ssh_pwauth: true\n",
                            hostname, username, escaped_pw, username, password);
    }

    static const char network_cfg[] =
        "version: 2\n"
        "ethernets:\n"
        "  id0:\n"
        "    match:\n"
        "      name: \"e*\"\n"
        "    dhcp4: true\n";

    if (meta_len <= 0 || (size_t)meta_len >= sizeof(meta_data) ||
        user_len <= 0 || (size_t)user_len >= sizeof(user_data)) {
        set_err(err_buf, err_cap, "Cloud-init seed configuration exceeded buffer limits.");
        return -1;
    }

    uint8_t *img = (uint8_t *)calloc(1U, CIDATA_IMAGE_BYTES);
    if (img == NULL) {
        set_err(err_buf, err_cap, "Out of memory allocating CIDATA FAT16 image.");
        return -1;
    }

    /* Boot sector / BIOS Parameter Block (FAT16) */
    img[0] = 0xEBU;
    img[1] = 0x3CU;
    img[2] = 0x90U;
    memcpy(img + 3, "HENGELNX", 8U);
    put_le16(img + 11, CIDATA_SECTOR_SIZE);
    img[13] = 1U; /* Sectors per cluster */
    put_le16(img + 14, CIDATA_RSVD_SECTORS);
    img[16] = CIDATA_NUM_FATS;
    put_le16(img + 17, CIDATA_ROOT_ENTRIES);
    put_le16(img + 19, CIDATA_TOTAL_SECTORS);
    img[21] = 0xF8U; /* Fixed disk media descriptor */
    put_le16(img + 22, CIDATA_FAT_SECTORS);
    put_le16(img + 24, 32U); /* Sectors per track */
    put_le16(img + 26, 64U); /* Number of heads */
    put_le32(img + 28, 0U);  /* Hidden sectors */
    put_le32(img + 32, 0U);  /* Total sectors 32 */
    img[36] = 0x80U;         /* Drive number */
    img[38] = 0x29U;         /* Extended boot signature */
    put_le32(img + 39, 0x48454E47U); /* Volume serial "HENG" */
    memcpy(img + 43, "CIDATA     ", 11U);
    memcpy(img + 54, "FAT16   ", 8U);
    img[510] = 0x55U;
    img[511] = 0xAAU;

    /* Initialize reserved FAT entries 0 and 1 */
    fat16_set_entry(img, 0U, 0xFFF8U);
    fat16_set_entry(img, 1U, 0xFFFFU);

    /* Root directory entry 0: Volume Label "CIDATA     " */
    uint8_t *root_dir = img + (CIDATA_RSVD_SECTORS + CIDATA_NUM_FATS * CIDATA_FAT_SECTORS) * CIDATA_SECTOR_SIZE;
    memcpy(root_dir, "CIDATA     ", 11U);
    root_dir[11] = 0x08U; /* ATTR_VOLUME_ID */

    size_t slot_idx = 1U;
    uint16_t next_cluster = 2U;
    if (add_fat16_file(img, &slot_idx, &next_cluster, "meta-data", "META-D~1   ",
                       (const uint8_t *)meta_data, (size_t)meta_len) != 0 ||
        add_fat16_file(img, &slot_idx, &next_cluster, "user-data", "USER-D~1   ",
                       (const uint8_t *)user_data, (size_t)user_len) != 0 ||
        add_fat16_file(img, &slot_idx, &next_cluster, "network-config", "NETWOR~1   ",
                       (const uint8_t *)network_cfg, sizeof(network_cfg) - 1U) != 0) {
        free(img);
        set_err(err_buf, err_cap, "Failed to populate CIDATA FAT16 directory entries.");
        return -1;
    }

    int fd = open(out_path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        free(img);
        set_err(err_buf, err_cap, "Failed to create CIDATA seed image file.");
        return -1;
    }

    size_t written = 0U;
    while (written < CIDATA_IMAGE_BYTES) {
        ssize_t n = write(fd, img + written, CIDATA_IMAGE_BYTES - written);
        if (n <= 0) {
            close(fd);
            free(img);
            unlink(out_path);
            set_err(err_buf, err_cap, "Write failed while creating CIDATA seed image.");
            return -1;
        }
        written += (size_t)n;
    }

    close(fd);
    free(img);
    return 0;
}
