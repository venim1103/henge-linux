/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_CIDATA_H
#define HENGE_CIDATA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HengeCidataConfig {
    const char *instance_id;
    const char *hostname;
    const char *username;
    const char *password;
    const char *ssh_authorized_key; /* Optional; may be NULL or empty */
} HengeCidataConfig;

/*
 * Synthesize a FAT16 NoCloud cloud-init seed image labeled "CIDATA" containing
 * /meta-data, /user-data, and /network-config (with VFAT LFN + 8.3 entries).
 * Returns 0 on success, -1 on error.
 */
int henge_cidata_write_image(const char *out_path,
                             const HengeCidataConfig *cfg,
                             char *err_buf,
                             size_t err_cap);

#ifdef __cplusplus
}
#endif

#endif /* HENGE_CIDATA_H */
