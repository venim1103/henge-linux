/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "henge_virgl_worker.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <time.h>

#if defined(__has_include)
#if __has_include(<virglrenderer.h>)
#include <virglrenderer.h>
#define HENGE_WORKER_HAS_VIRGL 1
/* virglrenderer.h forward-declares struct virgl_box; define its standard 6x u32 layout. */
struct virgl_box {
    uint32_t x, y, z;
    uint32_t w, h, d;
};
#endif
#if __has_include(<EGL/egl.h>) && __has_include(<EGL/eglext.h>) && __has_include(<GLES3/gl3.h>)
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#define HENGE_WORKER_HAS_ANGLE_EGL 1
#endif
#endif

#ifndef HENGE_WORKER_HAS_VIRGL
#define HENGE_WORKER_HAS_VIRGL 0
#endif
#ifndef HENGE_WORKER_HAS_ANGLE_EGL
#define HENGE_WORKER_HAS_ANGLE_EGL 0
#endif

#if HENGE_WORKER_HAS_ANGLE_EGL
#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
#ifndef EGL_IOSURFACE_ANGLE
#define EGL_IOSURFACE_ANGLE 0x3454
#endif
#ifndef EGL_IOSURFACE_PLANE_ANGLE
#define EGL_IOSURFACE_PLANE_ANGLE 0x345A
#endif
#ifndef EGL_TEXTURE_INTERNAL_FORMAT_ANGLE
#define EGL_TEXTURE_INTERNAL_FORMAT_ANGLE 0x345D
#endif
#ifndef EGL_TEXTURE_TYPE_ANGLE
#define EGL_TEXTURE_TYPE_ANGLE 0x345C
#endif
#ifndef EGL_SYNC_METAL_SHARED_EVENT_ANGLE
#define EGL_SYNC_METAL_SHARED_EVENT_ANGLE 0x34D8
#endif
#ifndef EGL_SYNC_METAL_SHARED_EVENT_SIGNALED_VALUE_LO_ANGLE
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNALED_VALUE_LO_ANGLE 0x34DB
#endif
#ifndef EGL_SYNC_METAL_SHARED_EVENT_SIGNALED_VALUE_HI_ANGLE
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNALED_VALUE_HI_ANGLE 0x34DC
#endif
#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif
typedef void (*HengeEglSetBlobCacheFuncsFn)(EGLDisplay dpy,
                                            EGLSetBlobFuncANDROID set,
                                            EGLGetBlobFuncANDROID get);
typedef void *(*HengeEglCopyMetalSharedEventFn)(EGLDisplay dpy, EGLSync sync);

typedef struct {
    void      *iosurface_ref;
    EGLSurface pbuffer;
    GLuint     tex_id;
    GLuint     fbo_id;
    uint32_t   width;
    uint32_t   height;
} HengeAngleSurfaceBinding;
#endif

#define HENGE_VIRGL_MAX_QUEUE_DEPTH 4096U
#define HENGE_VIRGL_MAX_PAYLOAD_LEN (16U * 1024U * 1024U)
#define HENGE_VIRGL_MAX_BACKING     16384U
#define HENGE_VIRGL_THREAD_STACK_SZ (8U * 1024U * 1024U)

typedef enum {
    HENGE_WORK_CMD    = 0,
    HENGE_WORK_RESET  = 1,
    HENGE_WORK_DRAIN  = 2,
    HENGE_WORK_MEMPR  = 3
} HengeWorkKind;

typedef struct HengeWorkNode {
    struct HengeWorkNode *next;
    HengeWorkKind         kind;
    uint32_t              queue_index;
    uint32_t              cmd_type;
    uint32_t              flags;
    uint64_t              fence_id;
    uint32_t              ctx_id;
    uint8_t               ring_idx;
    uint64_t              generation;
    void                 *cmd_tag;
    uint8_t              *payload;
    size_t                payload_len;
    HengeGpuBackingEntry *backing;
    uint32_t              backing_count;
} HengeWorkNode;

typedef struct HengePendingFence {
    struct HengePendingFence *next;
    uint64_t                  fence_id;
    uint64_t                  generation;
    void                     *cmd_tag;
    uint8_t                  *resp_bytes;
    size_t                    resp_len;
} HengePendingFence;

#if HENGE_WORKER_HAS_VIRGL
typedef struct HengeVirglIovEntry {
    struct HengeVirglIovEntry *next;
    uint32_t                   resource_id;
    struct iovec              *iovs;
    int                        num_iovs;
} HengeVirglIovEntry;
#endif

struct HengeVirglWorker {
    pthread_mutex_t          mu;
    pthread_cond_t           cv;
    pthread_cond_t           drain_cv;
    pthread_t                thread;
    bool                     thread_started;
    bool                     init_done;
    bool                     stop;
    bool                     enable_virgl;
    bool                     virgl_initialized;
    uint32_t                 vram_mib;
    HengeVirtioGpuDevice    *gpu;
    void                    *callback_opaque;
    HengeVirglCompleteFn     on_complete;
    HengeVirglDisplayEventFn on_display_event;

    HengeWorkNode           *q_head;
    HengeWorkNode           *q_tail;
    uint32_t                 q_depth;
    uint64_t                 drain_epoch_req;
    uint64_t                 drain_epoch_done;
    uint64_t                 active_generation;

    /* Pending async fences waiting for virglrenderer write_fence callback. */
    pthread_mutex_t          fence_mu;
    HengePendingFence       *fence_head;
    HengePendingFence       *fence_tail;
    uint32_t                 fence_count;
    uint64_t                 last_signaled_fence;

    /* Telemetry counters (protected by mu). */
    uint64_t                 cmds_enqueued;
    uint64_t                 cmds_completed;
    uint64_t                 fences_retired;
    uint64_t                 resets_processed;
    uint64_t                 flushes_3d;

    /* Per-worker diagnostic log rate limits (reset cleanly on each VM boot). */
    uint32_t                 logged_c3d;
    uint32_t                 logged_sub;
    uint32_t                 logged_fbo;
    uint32_t                 logged_blit;
    uint32_t                 logged_sanitized;

    /* Zero-copy double-buffered IOSurface swapchains per scanout. */
    HengeGpuSwapchain       *swapchains[HENGE_VIRTIO_GPU_MAX_SCANOUTS];
    uint64_t                 swapchain_signal_seq;

#if HENGE_WORKER_HAS_VIRGL
    HengeVirglIovEntry             *iov_head;
    struct virgl_renderer_callbacks virgl_cbs;
#endif
#if HENGE_WORKER_HAS_VIRGL && HENGE_WORKER_HAS_ANGLE_EGL
    EGLDisplay               egl_dpy;
    EGLConfig                egl_cfg;
    EGLContext               egl_root_ctx;
    EGLSurface               egl_dummy_surf;
    GLuint                   blit_src_fbo;
    bool                     egl_supports_border_clamp;
    bool                     egl_supports_mirror_clamp;
    HengeEglCopyMetalSharedEventFn egl_copy_shared_event;
    HengeAngleSurfaceBinding surface_bindings[HENGE_VIRTIO_GPU_MAX_SCANOUTS][HENGE_GPU_SWAPCHAIN_SLOTS];
#endif
};

static pthread_mutex_t g_active_worker_mu = PTHREAD_MUTEX_INITIALIZER;
static HengeVirglWorker *g_active_worker = NULL;

static void free_work_node(HengeWorkNode *node) {
    if (node == NULL) {
        return;
    }
    free(node->payload);
    free(node->backing);
    free(node);
}

static void free_pending_fence(HengePendingFence *pf) {
    if (pf == NULL) {
        return;
    }
    free(pf->resp_bytes);
    free(pf);
}

static uint32_t read_le32(const uint8_t *p) {
    uint32_t v = 0U;
    memcpy(&v, p, sizeof(v));
    return v;
}

static uint64_t read_le64(const uint8_t *p) {
    uint64_t v = 0ULL;
    memcpy(&v, p, sizeof(v));
    return v;
}

static void write_ctrl_hdr(uint8_t out[24],
                           uint32_t resp_type,
                           uint32_t flags,
                           uint64_t fence_id,
                           uint32_t ctx_id,
                           uint8_t ring_idx) {
    memset(out, 0, 24U);
    uint32_t rflags = flags & HENGE_VIRTIO_GPU_FLAG_FENCE;
    memcpy(out + 0U, &resp_type, 4U);
    memcpy(out + 4U, &rflags, 4U);
    memcpy(out + 8U, &fence_id, 8U);
    memcpy(out + 16U, &ctx_id, 4U);
    out[20] = ring_idx;
}

#if HENGE_WORKER_HAS_VIRGL
static void virgl_iov_replace(HengeVirglWorker *w,
                              uint32_t resource_id,
                              struct iovec *iovs,
                              int num_iovs) {
    HengeVirglIovEntry **pp = &w->iov_head;
    while (*pp != NULL) {
        if ((*pp)->resource_id == resource_id) {
            HengeVirglIovEntry *old = *pp;
            free(old->iovs);
            if (iovs == NULL || num_iovs <= 0) {
                *pp = old->next;
                free(old);
            } else {
                old->iovs = iovs;
                old->num_iovs = num_iovs;
            }
            return;
        }
        pp = &(*pp)->next;
    }
    if (iovs != NULL && num_iovs > 0) {
        HengeVirglIovEntry *ent = calloc(1U, sizeof(*ent));
        if (ent != NULL) {
            ent->resource_id = resource_id;
            ent->iovs = iovs;
            ent->num_iovs = num_iovs;
            ent->next = w->iov_head;
            w->iov_head = ent;
        } else {
            free(iovs);
        }
    }
}

static void virgl_iov_clear_all(HengeVirglWorker *w) {
    HengeVirglIovEntry *cur = w->iov_head;
    w->iov_head = NULL;
    while (cur != NULL) {
        HengeVirglIovEntry *next = cur->next;
        free(cur->iovs);
        free(cur);
        cur = next;
    }
}

static void virgl_cb_write_fence(void *cookie, uint32_t fence) {
    HengeVirglWorker *w = (HengeVirglWorker *)cookie;
    if (w == NULL) {
        return;
    }

    HengePendingFence *ready_head = NULL;
    HengePendingFence *ready_tail = NULL;
    uint64_t retired = 0ULL;

    pthread_mutex_lock(&w->fence_mu);
    if ((uint64_t)fence > w->last_signaled_fence) {
        w->last_signaled_fence = (uint64_t)fence;
    }
    HengePendingFence **pp = &w->fence_head;
    HengePendingFence *prev = NULL;
    while (*pp != NULL) {
        HengePendingFence *cur = *pp;
        if (cur->fence_id <= (uint64_t)fence) {
            *pp = cur->next;
            if (w->fence_tail == cur) {
                w->fence_tail = prev;
            }
            if (w->fence_count > 0U) {
                w->fence_count--;
            }
            cur->next = NULL;
            if (ready_tail == NULL) {
                ready_head = cur;
                ready_tail = cur;
            } else {
                ready_tail->next = cur;
                ready_tail = cur;
            }
            retired++;
        } else {
            prev = cur;
            pp = &cur->next;
        }
    }
    pthread_mutex_unlock(&w->fence_mu);

    if (retired > 0ULL) {
        pthread_mutex_lock(&w->mu);
        w->fences_retired += retired;
        w->cmds_completed += retired;
        pthread_mutex_unlock(&w->mu);
    }

    while (ready_head != NULL) {
        HengePendingFence *pf = ready_head;
        ready_head = pf->next;
        if (w->on_complete != NULL) {
            w->on_complete(w->callback_opaque, pf->cmd_tag, pf->generation,
                           pf->resp_bytes, pf->resp_len);
        }
        free_pending_fence(pf);
    }
}

#if HENGE_WORKER_HAS_ANGLE_EGL
static void henge_egl_blob_set(const void *key, EGLsizeiANDROID key_size,
                               const void *value, EGLsizeiANDROID value_size) {
    if (key != NULL && key_size > 0 && value != NULL && value_size > 0) {
        (void)henge_shader_cache_put(key, (size_t)key_size, value, (size_t)value_size);
    }
}

static EGLsizeiANDROID henge_egl_blob_get(const void *key, EGLsizeiANDROID key_size,
                                          void *value, EGLsizeiANDROID value_size) {
    if (key == NULL || key_size <= 0) {
        return 0;
    }
    return (EGLsizeiANDROID)henge_shader_cache_get(
        key, (size_t)key_size, value, (value_size > 0) ? (size_t)value_size : 0U);
}

static void angle_release_surface_binding(HengeVirglWorker *w, HengeAngleSurfaceBinding *b) {
    if (w == NULL || b == NULL) {
        return;
    }
    if (b->fbo_id != 0U) {
        glDeleteFramebuffers(1, &b->fbo_id);
        b->fbo_id = 0U;
    }
    if (b->pbuffer != EGL_NO_SURFACE && w->egl_dpy != EGL_NO_DISPLAY) {
        eglReleaseTexImage(w->egl_dpy, b->pbuffer, EGL_BACK_BUFFER);
        eglDestroySurface(w->egl_dpy, b->pbuffer);
        b->pbuffer = EGL_NO_SURFACE;
    }
    if (b->tex_id != 0U) {
        glDeleteTextures(1, &b->tex_id);
        b->tex_id = 0U;
    }
    b->iosurface_ref = NULL;
    b->width = 0U;
    b->height = 0U;
}

static void angle_release_all_bindings(HengeVirglWorker *w) {
    if (w == NULL || w->egl_dpy == EGL_NO_DISPLAY) {
        return;
    }
    if (w->egl_root_ctx != EGL_NO_CONTEXT) {
        eglMakeCurrent(w->egl_dpy, w->egl_dummy_surf, w->egl_dummy_surf, w->egl_root_ctx);
    }
    for (uint32_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
        for (uint32_t i = 0U; i < HENGE_GPU_SWAPCHAIN_SLOTS; i++) {
            angle_release_surface_binding(w, &w->surface_bindings[s][i]);
        }
    }
}

static bool angle_init_metal_egl(HengeVirglWorker *w) {
    const EGLAttrib disp_attrs[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE
    };
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
                                           (void *)(uintptr_t)EGL_DEFAULT_DISPLAY,
                                           disp_attrs);
    if (dpy == EGL_NO_DISPLAY) {
        dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    }
    if (dpy == EGL_NO_DISPLAY) {
        return false;
    }
    EGLint major = 0, minor = 0;
    if (!eglInitialize(dpy, &major, &minor)) {
        return false;
    }
    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        eglTerminate(dpy);
        return false;
    }
    /* Wire EGL_ANDROID_blob_cache to bounded 64 MiB LRU shader disk cache (Pitfall #2). */
    HengeEglSetBlobCacheFuncsFn set_blob =
        (HengeEglSetBlobCacheFuncsFn)eglGetProcAddress("eglSetBlobCacheFuncsANDROID");
    if (set_blob != NULL && henge_shader_cache_is_ready()) {
        set_blob(dpy, henge_egl_blob_set, henge_egl_blob_get);
    }

    const EGLint cfg_attrs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig cfg = NULL;
    EGLint num_cfg = 0;
    if (!eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &num_cfg) || num_cfg < 1) {
        eglTerminate(dpy);
        return false;
    }
    const EGLint pbuf_attrs[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
    EGLSurface dummy = eglCreatePbufferSurface(dpy, cfg, pbuf_attrs);
    const EGLint ctx_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLContext root_ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
    if (root_ctx == EGL_NO_CONTEXT) {
        if (dummy != EGL_NO_SURFACE) eglDestroySurface(dpy, dummy);
        eglTerminate(dpy);
        return false;
    }
    if (!eglMakeCurrent(dpy, dummy, dummy, root_ctx)) {
        eglDestroyContext(dpy, root_ctx);
        if (dummy != EGL_NO_SURFACE) eglDestroySurface(dpy, dummy);
        eglTerminate(dpy);
        return false;
    }
    w->egl_dpy = dpy;
    w->egl_cfg = cfg;
    w->egl_root_ctx = root_ctx;
    w->egl_dummy_surf = dummy;
    w->egl_copy_shared_event =
        (HengeEglCopyMetalSharedEventFn)eglGetProcAddress("eglCopyMetalSharedEventANGLE");
    glGenFramebuffers(1, &w->blit_src_fbo);

    /* Empirically probe ANGLE ES 3.0 sampler wrap-mode support so virgl_renderer_submit_cmd()
     * never triggers GL_INVALID_ENUM (1280) on PIPE_TEX_WRAP_CLAMP_TO_BORDER / MIRROR_CLAMP. */
    GLuint probe_sampler = 0U;
    glGenSamplers(1, &probe_sampler);
    while (glGetError() != GL_NO_ERROR) {}
    glSamplerParameteri(probe_sampler, GL_TEXTURE_WRAP_S, 0x812D /* GL_CLAMP_TO_BORDER */);
    GLenum err_border_wrap = glGetError();
    const GLfloat zero_border[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    glSamplerParameterfv(probe_sampler, 0x1004 /* GL_TEXTURE_BORDER_COLOR */, zero_border);
    GLenum err_border_col = glGetError();
    w->egl_supports_border_clamp = (err_border_wrap == GL_NO_ERROR && err_border_col == GL_NO_ERROR);
    glSamplerParameteri(probe_sampler, GL_TEXTURE_WRAP_S, 0x8743 /* GL_MIRROR_CLAMP_TO_EDGE */);
    w->egl_supports_mirror_clamp = (glGetError() == GL_NO_ERROR);
    while (glGetError() != GL_NO_ERROR) {}
    glDeleteSamplers(1, &probe_sampler);

    const char *gl_ver = (const char *)glGetString(GL_VERSION);
    const char *gl_ren = (const char *)glGetString(GL_RENDERER);
    fprintf(stderr, "virgl-worker: ANGLE EGL %d.%d ready: GL_VERSION='%s' GL_RENDERER='%s' (border_clamp=%d mirror_clamp=%d)\n",
            (int)major, (int)minor, gl_ver ? gl_ver : "?", gl_ren ? gl_ren : "?",
            w->egl_supports_border_clamp ? 1 : 0, w->egl_supports_mirror_clamp ? 1 : 0);
    return true;
}

static void angle_teardown_metal_egl(HengeVirglWorker *w) {
    if (w == NULL || w->egl_dpy == EGL_NO_DISPLAY) {
        return;
    }
    angle_release_all_bindings(w);
    if (w->blit_src_fbo != 0U) {
        glDeleteFramebuffers(1, &w->blit_src_fbo);
        w->blit_src_fbo = 0U;
    }
    eglMakeCurrent(w->egl_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (w->egl_root_ctx != EGL_NO_CONTEXT) {
        eglDestroyContext(w->egl_dpy, w->egl_root_ctx);
        w->egl_root_ctx = EGL_NO_CONTEXT;
    }
    if (w->egl_dummy_surf != EGL_NO_SURFACE) {
        eglDestroySurface(w->egl_dpy, w->egl_dummy_surf);
        w->egl_dummy_surf = EGL_NO_SURFACE;
    }
    eglTerminate(w->egl_dpy);
    w->egl_dpy = EGL_NO_DISPLAY;
}

static virgl_renderer_gl_context virgl_cb_create_gl_context(void *cookie,
                                                            int scanout_idx,
                                                            struct virgl_renderer_gl_ctx_param *param) {
    HengeVirglWorker *w = (HengeVirglWorker *)cookie;
    (void)scanout_idx;
    if (w == NULL || w->egl_dpy == EGL_NO_DISPLAY) {
        return NULL;
    }
    EGLint major = (param != NULL && param->major_ver >= 2) ? param->major_ver : 3;
    EGLint minor = (param != NULL && param->minor_ver >= 0) ? param->minor_ver : 0;
    if (major > 3) {
        major = 3;
        minor = 0;
    }
    const EGLint attrs[] = {
        EGL_CONTEXT_MAJOR_VERSION, major,
        EGL_CONTEXT_MINOR_VERSION, minor,
        EGL_NONE
    };
    EGLContext ctx = eglCreateContext(w->egl_dpy, w->egl_cfg, w->egl_root_ctx, attrs);
    if (ctx == EGL_NO_CONTEXT) {
        const EGLint fallback[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        ctx = eglCreateContext(w->egl_dpy, w->egl_cfg, w->egl_root_ctx, fallback);
    }
    return (virgl_renderer_gl_context)ctx;
}

static void virgl_cb_destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx) {
    HengeVirglWorker *w = (HengeVirglWorker *)cookie;
    if (w != NULL && w->egl_dpy != EGL_NO_DISPLAY && ctx != NULL) {
        eglDestroyContext(w->egl_dpy, (EGLContext)ctx);
    }
}

static int virgl_cb_make_current(void *cookie, int scanout_idx, virgl_renderer_gl_context ctx) {
    HengeVirglWorker *w = (HengeVirglWorker *)cookie;
    (void)scanout_idx;
    if (w == NULL || w->egl_dpy == EGL_NO_DISPLAY) {
        return -1;
    }
    EGLContext egl_ctx = (ctx != NULL) ? (EGLContext)ctx : w->egl_root_ctx;
    EGLSurface surf = (egl_ctx != EGL_NO_CONTEXT) ? w->egl_dummy_surf : EGL_NO_SURFACE;
    return eglMakeCurrent(w->egl_dpy, surf, surf, egl_ctx) ? 0 : -1;
}

static bool angle_blit_scanout_to_iosurface(HengeVirglWorker *w,
                                            uint32_t scanout_id,
                                            uint32_t slot_idx,
                                            uint32_t res_id,
                                            const HengeGpuSwapchainSlot *slot,
                                            void **out_shared_event,
                                            uint64_t *out_signal_value) {
    if (out_shared_event != NULL) *out_shared_event = NULL;
    if (out_signal_value != NULL) *out_signal_value = 0ULL;
    if (w == NULL || w->egl_dpy == EGL_NO_DISPLAY || slot == NULL || slot->iosurface == NULL ||
        scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS || slot_idx >= HENGE_GPU_SWAPCHAIN_SLOTS) {
        return false;
    }
    struct virgl_renderer_resource_info rinfo;
    memset(&rinfo, 0, sizeof(rinfo));
    if (virgl_renderer_resource_get_info((int)res_id, &rinfo) != 0 || rinfo.tex_id == 0U) {
        return false;
    }

    if (!eglMakeCurrent(w->egl_dpy, w->egl_dummy_surf, w->egl_dummy_surf, w->egl_root_ctx)) {
        return false;
    }

    HengeAngleSurfaceBinding *b = &w->surface_bindings[scanout_id][slot_idx];
    if (b->iosurface_ref != slot->iosurface || b->width != slot->width || b->height != slot->height) {
        angle_release_surface_binding(w, b);
        const EGLint surf_attrs[] = {
            EGL_WIDTH, (EGLint)slot->width,
            EGL_HEIGHT, (EGLint)slot->height,
            EGL_IOSURFACE_PLANE_ANGLE, 0,
            EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
            EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
            EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
            EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
            EGL_NONE
        };
        EGLSurface pbuf = eglCreatePbufferFromClientBuffer(
            w->egl_dpy, EGL_IOSURFACE_ANGLE, slot->iosurface, w->egl_cfg, surf_attrs);
        if (pbuf == EGL_NO_SURFACE) {
            fprintf(stderr, "virgl-worker: eglCreatePbufferFromClientBuffer failed (err=0x%x, %ux%u)\n",
                    (unsigned)eglGetError(), slot->width, slot->height);
            virgl_renderer_force_ctx_0();
            return false;
        }
        GLuint dst_tex = 0U;
        glGenTextures(1, &dst_tex);
        glBindTexture(GL_TEXTURE_2D, dst_tex);
        if (!eglBindTexImage(w->egl_dpy, pbuf, EGL_BACK_BUFFER)) {
            fprintf(stderr, "virgl-worker: eglBindTexImage failed (err=0x%x)\n", (unsigned)eglGetError());
            glDeleteTextures(1, &dst_tex);
            eglDestroySurface(w->egl_dpy, pbuf);
            virgl_renderer_force_ctx_0();
            return false;
        }
        GLuint dst_fbo = 0U;
        glGenFramebuffers(1, &dst_fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, dst_fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, dst_tex, 0);
        b->iosurface_ref = slot->iosurface;
        b->pbuffer = pbuf;
        b->tex_id = dst_tex;
        b->fbo_id = dst_fbo;
        b->width = slot->width;
        b->height = slot->height;
    }

    glBindFramebuffer(GL_READ_FRAMEBUFFER, w->blit_src_fbo);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rinfo.tex_id, 0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, b->fbo_id);

    GLenum read_status = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER);
    GLenum draw_status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
    if (read_status != GL_FRAMEBUFFER_COMPLETE || draw_status != GL_FRAMEBUFFER_COMPLETE) {
        if (w->logged_fbo < 4U) {
            w->logged_fbo++;
            fprintf(stderr, "virgl-worker: incomplete blit FBO (read=0x%x draw=0x%x res=%u tex=%u)\n",
                    (unsigned)read_status, (unsigned)draw_status, res_id, rinfo.tex_id);
        }
        glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        virgl_renderer_force_ctx_0();
        return false;
    }

    GLint sw = (rinfo.width > 0U) ? (GLint)rinfo.width : (GLint)slot->width;
    GLint sh = (rinfo.height > 0U) ? (GLint)rinfo.height : (GLint)slot->height;
    glBlitFramebuffer(0, 0, sw, sh,
                      0, 0, (GLint)slot->width, (GLint)slot->height,
                      GL_COLOR_BUFFER_BIT, GL_LINEAR);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);

    /* Guarantee IOSurface backing store completion before Metal consumer samples it,
     * then restore virglrenderer's ctx0 so subsequent Gallium commands stay current. */
    glFinish();
    virgl_renderer_force_ctx_0();

    uint64_t next_sig = ++w->swapchain_signal_seq;
    if (out_shared_event != NULL) *out_shared_event = NULL;
    if (out_signal_value != NULL) *out_signal_value = next_sig;
    return true;
}
#endif /* HENGE_WORKER_HAS_ANGLE_EGL */
#endif /* HENGE_WORKER_HAS_VIRGL */

static void flush_stale_fences(HengeVirglWorker *w, uint64_t min_generation, bool drop_all) {
    HengePendingFence *drop_head = NULL;
    pthread_mutex_lock(&w->fence_mu);
    HengePendingFence **pp = &w->fence_head;
    HengePendingFence *prev = NULL;
    while (*pp != NULL) {
        HengePendingFence *cur = *pp;
        if (drop_all || cur->generation < min_generation) {
            *pp = cur->next;
            if (w->fence_tail == cur) {
                w->fence_tail = prev;
            }
            if (w->fence_count > 0U) {
                w->fence_count--;
            }
            cur->next = drop_head;
            drop_head = cur;
        } else {
            prev = cur;
            pp = &cur->next;
        }
    }
    pthread_mutex_unlock(&w->fence_mu);

    while (drop_head != NULL) {
        HengePendingFence *pf = drop_head;
        drop_head = pf->next;
        if (w->on_complete != NULL) {
            w->on_complete(w->callback_opaque, pf->cmd_tag, pf->generation, NULL, 0U);
        }
        free_pending_fence(pf);
    }
}

static void complete_or_fence_cmd(HengeVirglWorker *w,
                                  const HengeWorkNode *node,
                                  const uint8_t *resp_bytes,
                                  size_t resp_len,
                                  uint32_t resp_type) {
    bool is_fenced = ((node->flags & HENGE_VIRTIO_GPU_FLAG_FENCE) != 0U) &&
                     (resp_type < 0x1200U);

#if HENGE_WORKER_HAS_VIRGL
    if (is_fenced && w->virgl_initialized) {
        HengePendingFence *pf = calloc(1U, sizeof(*pf));
        if (pf != NULL) {
            pf->fence_id = node->fence_id;
            pf->generation = node->generation;
            pf->cmd_tag = node->cmd_tag;
            pf->resp_len = resp_len;
            if (resp_len > 0U) {
                pf->resp_bytes = malloc(resp_len);
                if (pf->resp_bytes != NULL) {
                    memcpy(pf->resp_bytes, resp_bytes, resp_len);
                } else {
                    free(pf);
                    pf = NULL;
                }
            }
        }
        if (pf != NULL) {
            pthread_mutex_lock(&w->fence_mu);
            if (w->fence_tail == NULL) {
                w->fence_head = pf;
                w->fence_tail = pf;
            } else {
                w->fence_tail->next = pf;
                w->fence_tail = pf;
            }
            w->fence_count++;
            pthread_mutex_unlock(&w->fence_mu);

            if (virgl_renderer_create_fence((int)node->fence_id, node->ctx_id) == 0) {
                virgl_renderer_poll();
                return;
            }
            /* Fallback: virgl_renderer_create_fence rejected -> retire immediately. */
            virgl_cb_write_fence(w, (uint32_t)node->fence_id);
            return;
        }
    }
#endif

    pthread_mutex_lock(&w->mu);
    w->cmds_completed++;
    if (is_fenced) {
        w->fences_retired++;
    }
    pthread_mutex_unlock(&w->mu);

    if (w->on_complete != NULL) {
        w->on_complete(w->callback_opaque, node->cmd_tag, node->generation,
                       resp_bytes, resp_len);
    }
}

static void execute_work_cmd(HengeVirglWorker *w, HengeWorkNode *node) {
    uint8_t stack_resp[24];
    uint8_t *heap_resp = NULL;
    const uint8_t *resp_ptr = stack_resp;
    size_t resp_len = 24U;
    uint32_t resp_type = HENGE_VIRTIO_GPU_RESP_OK_NODATA;

    if (w->gpu == NULL) {
        resp_type = HENGE_VIRTIO_GPU_RESP_ERR_UNSPEC;
        write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
        complete_or_fence_cmd(w, node, resp_ptr, resp_len, resp_type);
        return;
    }

    if (node->queue_index == 1U) {
        /* cursorq: UPDATE_CURSOR / MOVE_CURSOR */
        if (node->payload != NULL && node->payload_len >= 28U) {
            uint32_t scanout_id = read_le32(node->payload + 0U);
            uint32_t cx = read_le32(node->payload + 4U);
            uint32_t cy = read_le32(node->payload + 8U);
            uint32_t res_id = read_le32(node->payload + 16U);
            uint32_t hot_x = read_le32(node->payload + 20U);
            uint32_t hot_y = read_le32(node->payload + 24U);
            bool move_only = (node->cmd_type == HENGE_VIRTIO_GPU_CMD_MOVE_CURSOR);
            henge_virtio_gpu_update_cursor(w->gpu, scanout_id, res_id, cx, cy, hot_x, hot_y, move_only);
            if (scanout_id == 0U && w->on_display_event != NULL) {
                w->on_display_event(w->callback_opaque, 0U, true, false);
            }
        }
        write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
        complete_or_fence_cmd(w, node, resp_ptr, resp_len, resp_type);
        return;
    }

    switch ((HengeVirtioGpuCmdType)node->cmd_type) {
        case HENGE_VIRTIO_GPU_CMD_GET_DISPLAY_INFO: {
            heap_resp = calloc(1U, 24U + 16U * 24U);
            if (heap_resp == NULL) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
                break;
            }
            resp_type = HENGE_VIRTIO_GPU_RESP_OK_DISPLAY_INFO;
            write_ctrl_hdr(heap_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            for (uint32_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
                uint32_t dw = 0U, dh = 0U;
                bool den = false;
                if (henge_virtio_gpu_get_display_info(w->gpu, s, &dw, &dh, &den) == 0) {
                    size_t off = 24U + (size_t)s * 24U;
                    memcpy(heap_resp + off + 8U, &dw, 4U);
                    memcpy(heap_resp + off + 12U, &dh, 4U);
                    uint32_t en32 = den ? 1U : 0U;
                    memcpy(heap_resp + off + 16U, &en32, 4U);
                }
            }
            resp_ptr = heap_resp;
            resp_len = 24U + 16U * 24U;
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_GET_EDID: {
            heap_resp = calloc(1U, 24U + 8U + 1024U);
            if (heap_resp == NULL) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
                break;
            }
            uint32_t scanout = (node->payload != NULL && node->payload_len >= 4U)
                ? read_le32(node->payload)
                : 0U;
            if (henge_virtio_gpu_get_edid(w->gpu, scanout, heap_resp + 32U) == 0) {
                resp_type = HENGE_VIRTIO_GPU_RESP_OK_EDID;
                uint32_t edid_sz = 128U;
                memcpy(heap_resp + 24U, &edid_sz, 4U);
            } else {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT;
            }
            write_ctrl_hdr(heap_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            resp_ptr = heap_resp;
            resp_len = 24U + 8U + 1024U;
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_GET_CAPSET_INFO: {
            uint32_t cap_index = (node->payload != NULL && node->payload_len >= 4U)
                ? read_le32(node->payload)
                : 0U;
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                w->gpu, node->cmd_type, node->ctx_id, 0U, 0U, 0U, 0U, 0U, NULL, 0U);
            if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_CAPSET_INFO && cap_index < 2U) {
                uint32_t capset_id = (cap_index == 0U)
                    ? HENGE_VIRTIO_GPU_CAPSET_VIRGL
                    : HENGE_VIRTIO_GPU_CAPSET_VIRGL2;
                uint32_t max_ver = 0U;
                uint32_t max_size = 0U;
#if HENGE_WORKER_HAS_VIRGL
                if (w->virgl_initialized) {
                    virgl_renderer_get_cap_set(capset_id, &max_ver, &max_size);
                } else {
                    max_ver = (capset_id == HENGE_VIRTIO_GPU_CAPSET_VIRGL2) ? 2U : 1U;
                    max_size = 64U;
                }
#else
                max_ver = (capset_id == HENGE_VIRTIO_GPU_CAPSET_VIRGL2) ? 2U : 1U;
                max_size = 64U;
#endif
                heap_resp = calloc(1U, 24U + 16U);
                if (heap_resp != NULL) {
                    write_ctrl_hdr(heap_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
                    memcpy(heap_resp + 24U, &capset_id, 4U);
                    memcpy(heap_resp + 28U, &max_ver, 4U);
                    memcpy(heap_resp + 32U, &max_size, 4U);
                    resp_ptr = heap_resp;
                    resp_len = 24U + 16U;
                } else {
                    resp_type = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                    write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
                }
            } else {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
                write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            }
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_GET_CAPSET: {
            uint32_t capset_id = (node->payload != NULL && node->payload_len >= 8U)
                ? read_le32(node->payload + 0U)
                : 0U;
            uint32_t capset_ver = (node->payload != NULL && node->payload_len >= 8U)
                ? read_le32(node->payload + 4U)
                : 0U;
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                w->gpu, node->cmd_type, node->ctx_id, 0U, 0U, 0U, 0U, 0U, NULL, 0U);
            if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_CAPSET &&
                (capset_id == HENGE_VIRTIO_GPU_CAPSET_VIRGL ||
                 capset_id == HENGE_VIRTIO_GPU_CAPSET_VIRGL2)) {
                uint32_t max_ver = 0U;
                uint32_t max_size = 64U;
#if HENGE_WORKER_HAS_VIRGL
                if (w->virgl_initialized) {
                    virgl_renderer_get_cap_set(capset_id, &max_ver, &max_size);
                }
#else
                (void)max_ver;
#endif
                if (max_size > 65536U) {
                    max_size = 65536U;
                }
                heap_resp = calloc(1U, 24U + (size_t)max_size);
                if (heap_resp != NULL) {
                    write_ctrl_hdr(heap_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
#if HENGE_WORKER_HAS_VIRGL
                    if (w->virgl_initialized && max_size > 0U) {
                        virgl_renderer_fill_caps(capset_id, capset_ver, heap_resp + 24U);
                    }
#else
                    (void)capset_ver;
#endif
                    resp_ptr = heap_resp;
                    resp_len = 24U + (size_t)max_size;
                } else {
                    resp_type = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                    write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
                }
            } else {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
                write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            }
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_CTX_CREATE: {
            uint32_t nlen = (node->payload != NULL && node->payload_len >= 4U)
                ? read_le32(node->payload + 0U)
                : 0U;
            char debug_name[65];
            memset(debug_name, 0, sizeof(debug_name));
            if (nlen > 64U) {
                nlen = 64U;
            }
            if (node->payload != NULL && node->payload_len >= 8U + (size_t)nlen && nlen > 0U) {
                memcpy(debug_name, node->payload + 8U, nlen);
            } else {
                snprintf(debug_name, sizeof(debug_name), "henge-ctx-%u", node->ctx_id);
                nlen = (uint32_t)strlen(debug_name);
            }
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                w->gpu, node->cmd_type, node->ctx_id, 0U, 0U, 0U, 0U, 0U, NULL, 0U);
#if HENGE_WORKER_HAS_VIRGL
            if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->virgl_initialized) {
                if (virgl_renderer_context_create(node->ctx_id, nlen, debug_name) != 0) {
                    (void)henge_virtio_gpu_process_ctrl(
                        w->gpu, HENGE_VIRTIO_GPU_CMD_CTX_DESTROY, node->ctx_id, 0U, 0U, 0U, 0U, 0U, NULL, 0U);
                    resp_type = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                }
            }
#endif
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_CTX_DESTROY: {
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                w->gpu, node->cmd_type, node->ctx_id, 0U, 0U, 0U, 0U, 0U, NULL, 0U);
#if HENGE_WORKER_HAS_VIRGL
            if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->virgl_initialized) {
                virgl_renderer_context_destroy(node->ctx_id);
            }
#endif
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE:
        case HENGE_VIRTIO_GPU_CMD_CTX_DETACH_RESOURCE: {
            uint32_t res_id = (node->payload != NULL && node->payload_len >= 4U)
                ? read_le32(node->payload)
                : 0U;
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                w->gpu, node->cmd_type, node->ctx_id, res_id, 0U, 0U, 0U, 0U, NULL, 0U);
#if HENGE_WORKER_HAS_VIRGL
            if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->virgl_initialized) {
                if (node->cmd_type == HENGE_VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE) {
                    virgl_renderer_ctx_attach_resource((int)node->ctx_id, (int)res_id);
                } else {
                    virgl_renderer_ctx_detach_resource((int)node->ctx_id, (int)res_id);
                }
            }
#endif
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_2D: {
            if (node->payload == NULL || node->payload_len < 16U) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
            } else {
                uint32_t res_id = read_le32(node->payload + 0U);
                uint32_t fmt = read_le32(node->payload + 4U);
                uint32_t rw = read_le32(node->payload + 8U);
                uint32_t rh = read_le32(node->payload + 12U);
                resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                    w->gpu, node->cmd_type, node->ctx_id, res_id, 0U, rw, rh, fmt, NULL, 0U);
#if HENGE_WORKER_HAS_VIRGL
                if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->virgl_initialized) {
                    struct virgl_renderer_resource_create_args args;
                    memset(&args, 0, sizeof(args));
                    args.handle = res_id;
                    args.target = 2U; /* PIPE_TEXTURE_2D */
                    args.format = fmt;
                    args.bind = (1U << 1) | (1U << 3); /* VIRGL_BIND_RENDER_TARGET | VIRGL_BIND_SAMPLER_VIEW */
                    args.width = rw;
                    args.height = rh;
                    args.depth = 1U;
                    args.array_size = 1U;
                    args.last_level = 0U;
                    args.nr_samples = 0U;
                    args.flags = 0U;
                    (void)virgl_renderer_resource_create(&args, NULL, 0);
                }
#endif
            }
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D: {
            if (node->payload == NULL || node->payload_len < 44U) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
            } else {
                uint32_t res_id = read_le32(node->payload + 0U);
                uint32_t target = read_le32(node->payload + 4U);
                uint32_t fmt = read_le32(node->payload + 8U);
                uint32_t bind = read_le32(node->payload + 12U);
                uint32_t rw = read_le32(node->payload + 16U);
                uint32_t rh = read_le32(node->payload + 20U);
                uint32_t depth = read_le32(node->payload + 24U);
                uint32_t array_sz = read_le32(node->payload + 28U);
                uint32_t last_lvl = read_le32(node->payload + 32U);
                uint32_t nr_samples = read_le32(node->payload + 36U);
                uint32_t rflags = read_le32(node->payload + 40U);
                (void)target; (void)bind; (void)depth; (void)array_sz; (void)last_lvl; (void)nr_samples; (void)rflags;
                resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                    w->gpu, node->cmd_type, node->ctx_id, res_id, 0U, rw, rh, fmt, NULL, 0U);
#if HENGE_WORKER_HAS_VIRGL
                if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->virgl_initialized) {
                    struct virgl_renderer_resource_create_args args;
                    memset(&args, 0, sizeof(args));
                    args.handle = res_id;
                    args.target = target;
                    args.format = fmt;
                    args.bind = bind;
                    args.width = rw;
                    args.height = rh;
                    args.depth = depth;
                    args.array_size = array_sz;
                    args.last_level = last_lvl;
                    args.nr_samples = nr_samples;
                    args.flags = rflags;
                    int rc_c3d = virgl_renderer_resource_create(&args, NULL, 0);
                    if (rc_c3d != 0) {
                        if (w->logged_c3d < 8U) {
                            w->logged_c3d++;
                            fprintf(stderr, "virgl-worker: create_3d failed (res=%u target=%u fmt=%u %ux%ux%u rc=%d)\n",
                                    res_id, target, fmt, rw, rh, depth, rc_c3d);
                        }
                        (void)henge_virtio_gpu_process_ctrl(
                            w->gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_UNREF, 0U, res_id, 0U, 0U, 0U, 0U, NULL, 0U);
                        resp_type = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                    }
                }
#endif
            }
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_UNREF: {
            uint32_t res_id = (node->payload != NULL && node->payload_len >= 4U)
                ? read_le32(node->payload)
                : 0U;
            bool was_scanout0 = (res_id != 0U &&
                                 res_id == henge_virtio_gpu_scanout_resource(w->gpu, 0U));
            HengeGpuCursorState cur_st;
            bool was_cursor0 = (res_id != 0U &&
                                henge_virtio_gpu_get_cursor_state(w->gpu, 0U, &cur_st) == 0 &&
                                cur_st.resource_id == res_id);
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                w->gpu, node->cmd_type, node->ctx_id, res_id, 0U, 0U, 0U, 0U, NULL, 0U);
#if HENGE_WORKER_HAS_VIRGL
            if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->virgl_initialized) {
                struct iovec *detached = NULL;
                int detached_n = 0;
                virgl_renderer_resource_detach_iov((int)res_id, &detached, &detached_n);
                virgl_iov_replace(w, res_id, NULL, 0);
                virgl_renderer_resource_unref(res_id);
            }
#endif
            if (was_scanout0 && w->on_display_event != NULL) {
                w->on_display_event(w->callback_opaque, 0U, false, true);
            }
            if (was_cursor0 && w->on_display_event != NULL) {
                w->on_display_event(w->callback_opaque, 0U, true, false);
            }
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING: {
            uint32_t res_id = (node->payload != NULL && node->payload_len >= 4U)
                ? read_le32(node->payload)
                : 0U;
            if (henge_virtio_gpu_attach_backing(w->gpu, res_id, node->backing, node->backing_count) == 0) {
                resp_type = HENGE_VIRTIO_GPU_RESP_OK_NODATA;
#if HENGE_WORKER_HAS_VIRGL
                if (w->virgl_initialized && node->backing_count > 0U && node->backing != NULL) {
                    struct iovec *iovs = calloc((size_t)node->backing_count, sizeof(*iovs));
                    if (iovs != NULL) {
                        int valid_iovs = 0;
                        for (uint32_t i = 0U; i < node->backing_count; i++) {
                            if (node->backing[i].host_ptr != NULL && node->backing[i].length > 0U) {
                                iovs[valid_iovs].iov_base = (void *)(uintptr_t)node->backing[i].host_ptr;
                                iovs[valid_iovs].iov_len = (size_t)node->backing[i].length;
                                valid_iovs++;
                            }
                        }
                        if (valid_iovs > 0 &&
                            virgl_renderer_resource_attach_iov((int)res_id, iovs, valid_iovs) == 0) {
                            virgl_iov_replace(w, res_id, iovs, valid_iovs);
                        } else {
                            free(iovs);
                        }
                    }
                }
#endif
            } else {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
            }
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING: {
            uint32_t res_id = (node->payload != NULL && node->payload_len >= 4U)
                ? read_le32(node->payload)
                : 0U;
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                w->gpu, node->cmd_type, node->ctx_id, res_id, 0U, 0U, 0U, 0U, NULL, 0U);
#if HENGE_WORKER_HAS_VIRGL
            if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->virgl_initialized) {
                struct iovec *detached = NULL;
                int detached_n = 0;
                virgl_renderer_resource_detach_iov((int)res_id, &detached, &detached_n);
                virgl_iov_replace(w, res_id, NULL, 0);
            }
#endif
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D: {
            if (node->payload == NULL || node->payload_len < 28U) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
            } else {
                uint32_t rx = read_le32(node->payload + 0U);
                uint32_t ry = read_le32(node->payload + 4U);
                uint32_t rw = read_le32(node->payload + 8U);
                uint32_t rh = read_le32(node->payload + 12U);
                uint64_t off = read_le64(node->payload + 16U);
                uint32_t res_id = read_le32(node->payload + 24U);
                resp_type = (henge_virtio_gpu_transfer_to_host_2d(w->gpu, res_id, rx, ry, rw, rh, off) == 0)
                    ? HENGE_VIRTIO_GPU_RESP_OK_NODATA
                    : HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
#if HENGE_WORKER_HAS_VIRGL
                if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->virgl_initialized) {
                    struct virgl_box box = { .x = rx, .y = ry, .z = 0U, .w = rw, .h = rh, .d = 1U };
                    (void)virgl_renderer_transfer_write_iov(
                        res_id, 0U, 0, 0U, 0U, &box, off, NULL, 0U);
                }
#endif
                if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->on_display_event != NULL) {
                    HengeGpuCursorState cur_st;
                    if (henge_virtio_gpu_get_cursor_state(w->gpu, 0U, &cur_st) == 0 &&
                        cur_st.resource_id == res_id && cur_st.visible) {
                        w->on_display_event(w->callback_opaque, 0U, true, false);
                    }
                }
            }
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D:
        case HENGE_VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D: {
            if (node->payload == NULL || node->payload_len < 48U) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
            } else {
                uint32_t bx = read_le32(node->payload + 0U);
                uint32_t by = read_le32(node->payload + 4U);
                uint32_t bz = read_le32(node->payload + 8U);
                uint32_t bw = read_le32(node->payload + 12U);
                uint32_t bh = read_le32(node->payload + 16U);
                uint32_t bd = read_le32(node->payload + 20U);
                uint64_t off = read_le64(node->payload + 24U);
                uint32_t res_id = read_le32(node->payload + 32U);
                uint32_t level = read_le32(node->payload + 36U);
                uint32_t stride = read_le32(node->payload + 40U);
                uint32_t layer_stride = read_le32(node->payload + 44U);
                (void)bx; (void)by; (void)bz; (void)bw; (void)bh; (void)bd;
                (void)off; (void)level; (void)stride; (void)layer_stride;
                resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                    w->gpu, node->cmd_type, node->ctx_id, res_id, 0U, bw, bh, 0U, NULL, 0U);
#if HENGE_WORKER_HAS_VIRGL
                if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && w->virgl_initialized) {
                    struct virgl_box box = { .x = bx, .y = by, .z = bz, .w = bw, .h = bh, .d = bd };
                    int rc = (node->cmd_type == HENGE_VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D)
                        ? virgl_renderer_transfer_write_iov(
                              res_id, node->ctx_id, (int)level, stride, layer_stride, &box, off, NULL, 0U)
                        : virgl_renderer_transfer_read_iov(
                              res_id, node->ctx_id, level, stride, layer_stride, &box, off, NULL, 0);
                    if (rc != 0) {
                        resp_type = HENGE_VIRTIO_GPU_RESP_ERR_UNSPEC;
                    }
                }
#endif
            }
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_SUBMIT_3D: {
            if (node->payload == NULL || node->payload_len < 4U) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
            } else {
                uint32_t cmd_bytes = read_le32(node->payload + 0U);
                if ((cmd_bytes & 3U) != 0U || (size_t)cmd_bytes > node->payload_len - 4U) {
                    resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
                } else {
                    const uint8_t *cmd_buf = node->payload + 4U;
                    resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                        w->gpu, node->cmd_type, node->ctx_id, 0U, 0U, 0U, 0U, 0U, cmd_buf, (size_t)cmd_bytes);
#if HENGE_WORKER_HAS_VIRGL
                    if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA &&
                        w->virgl_initialized && cmd_bytes > 0U) {
                        uint32_t *aligned_cmd = malloc(cmd_bytes);
                        if (aligned_cmd == NULL) {
                            resp_type = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                        } else {
                            memcpy(aligned_cmd, cmd_buf, cmd_bytes);
#if HENGE_WORKER_HAS_ANGLE_EGL
                            uint32_t sanitized = henge_virgl_sanitize_cmd_stream(
                                aligned_cmd, (size_t)(cmd_bytes / 4U),
                                w->egl_supports_border_clamp, w->egl_supports_mirror_clamp);
                            if (sanitized > 0U && w->logged_sanitized < 4U) {
                                w->logged_sanitized++;
                                fprintf(stderr, "virgl-worker: sanitized %u unsupported sampler wrap mode(s) for ES 3.0 (ctx=%u)\n",
                                        sanitized, node->ctx_id);
                            }
#endif
                            int rc_sub = virgl_renderer_submit_cmd(aligned_cmd, (int)node->ctx_id, (int)(cmd_bytes / 4U));
                            if (rc_sub != 0) {
                                if (w->logged_sub < 8U) {
                                    w->logged_sub++;
                                    uint32_t ndw = cmd_bytes / 4U;
                                    fprintf(stderr, "virgl-worker: submit_cmd failed (ctx=%u bytes=%u ndw=%u hdr0=0x%08x rc=%d)\n",
                                            node->ctx_id, cmd_bytes, ndw, aligned_cmd[0], rc_sub);
                                    if (w->logged_sub <= 2U) {
                                        uint32_t off = 0U;
                                        uint32_t seen = 0U;
                                        uint32_t printed = 0U;
                                        uint32_t prev_off = 0U;
                                        uint32_t prev_h = 0U;
                                        while (off < ndw) {
                                            uint32_t h = aligned_cmd[off];
                                            uint32_t clen = h >> 16;
                                            uint32_t cobj = (h >> 8) & 0xFFU;
                                            uint32_t ccmd = h & 0xFFU;
                                            if (off + 1U + clen > ndw) {
                                                fprintf(stderr, "virgl-worker:   [off=%u #%u] TRUNCATED hdr=0x%08x (cmd=%u obj=%u len=%u ndw=%u)\n",
                                                        off, seen, h, ccmd, cobj, clen, ndw);
                                                break;
                                            }
                                            if (printed < 12U && (ccmd == 1U || seen < 3U)) {
                                                if (ccmd == 1U && seen > 0U) {
                                                    fprintf(stderr, "virgl-worker:   [prev off=%u] hdr=0x%08x (cmd=%u obj=%u len=%u)\n",
                                                            prev_off, prev_h, prev_h & 0xFFU, (prev_h >> 8) & 0xFFU, prev_h >> 16);
                                                }
                                                fprintf(stderr, "virgl-worker:   [off=%u #%u] hdr=0x%08x (cmd=%u obj=%u len=%u)",
                                                        off, seen, h, ccmd, cobj, clen);
                                                uint32_t dump_n = (clen < 10U) ? clen : 10U;
                                                for (uint32_t k = 1U; k <= dump_n; k++) {
                                                    fprintf(stderr, " w%u=0x%08x", k, aligned_cmd[off + k]);
                                                }
                                                fprintf(stderr, "\n");
                                                printed++;
                                            }
                                            prev_off = off;
                                            prev_h = h;
                                            off += 1U + clen;
                                            seen++;
                                        }
                                    }
                                }
                                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_UNSPEC;
                            }
                            free(aligned_cmd);
                        }
                    }
#endif
                }
            }
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_SET_SCANOUT: {
            if (node->payload == NULL || node->payload_len < 24U) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
            } else {
                uint32_t rw = read_le32(node->payload + 8U);
                uint32_t rh = read_le32(node->payload + 12U);
                uint32_t scanout_id = read_le32(node->payload + 16U);
                uint32_t res_id = read_le32(node->payload + 20U);
                resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                    w->gpu, node->cmd_type, node->ctx_id, res_id, scanout_id, rw, rh, 0U, NULL, 0U);
                if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA &&
                    scanout_id < HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
                    if (w->virgl_initialized && res_id != 0U && rw > 0U && rh > 0U &&
                        w->swapchains[scanout_id] != NULL) {
                        (void)henge_gpu_swapchain_resize(w->swapchains[scanout_id], rw, rh, false);
                    }
                    if (scanout_id == 0U && w->on_display_event != NULL) {
                        w->on_display_event(w->callback_opaque, 0U, false, true);
                    }
                }
            }
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_FLUSH: {
            if (node->payload == NULL || node->payload_len < 20U) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
            } else {
                uint32_t rw = read_le32(node->payload + 8U);
                uint32_t rh = read_le32(node->payload + 12U);
                uint32_t res_id = read_le32(node->payload + 16U);
                resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                    w->gpu, node->cmd_type, node->ctx_id, res_id, 0U, rw, rh, 0U, NULL, 0U);
                if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA) {
                    if (w->virgl_initialized) {
                        pthread_mutex_lock(&w->mu);
                        w->flushes_3d++;
                        pthread_mutex_unlock(&w->mu);
                        henge_gpu_telemetry_inc_3d_flushes();
                        for (uint32_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
                            if (res_id == henge_virtio_gpu_scanout_resource(w->gpu, s) &&
                                w->swapchains[s] != NULL) {
                                uint32_t slot_idx = 0U;
                                HengeGpuSwapchainSlot slot;
                                if (henge_gpu_swapchain_acquire_back(w->swapchains[s], &slot_idx, &slot) == 0) {
                                    void *shared_ev = NULL;
                                    uint64_t sig = 0ULL;
#if HENGE_WORKER_HAS_VIRGL && HENGE_WORKER_HAS_ANGLE_EGL
                                    if (angle_blit_scanout_to_iosurface(w, s, slot_idx, res_id, &slot, &shared_ev, &sig)) {
                                        if (w->logged_blit == 0U) {
                                            w->logged_blit = 1U;
                                            fprintf(stderr, "virgl-worker: first 3D IOSurface blit succeeded (scanout=%u res=%u %ux%u)\n",
                                                    s, res_id, slot.width, slot.height);
                                        }
                                        (void)henge_gpu_swapchain_publish(w->swapchains[s], slot_idx, shared_ev, sig, slot.is_srgb);
                                    }
#else
                                    sig = ++w->swapchain_signal_seq;
                                    (void)henge_gpu_swapchain_publish(w->swapchains[s], slot_idx, shared_ev, sig, slot.is_srgb);
#endif
                                }
                            }
                        }
                    }
                    if (res_id == henge_virtio_gpu_scanout_resource(w->gpu, 0U) &&
                        w->on_display_event != NULL) {
                        w->on_display_event(w->callback_opaque, 0U, false, false);
                    }
                }
            }
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
        }

        default:
            resp_type = HENGE_VIRTIO_GPU_RESP_ERR_UNSPEC;
            write_ctrl_hdr(stack_resp, resp_type, node->flags, node->fence_id, node->ctx_id, node->ring_idx);
            break;
    }

    complete_or_fence_cmd(w, node, resp_ptr, resp_len, resp_type);
    free(heap_resp);
}

static void *virgl_worker_thread_main(void *arg) {
    HengeVirglWorker *w = (HengeVirglWorker *)arg;

#if HENGE_WORKER_HAS_VIRGL
    bool virgl_ok = false;
    if (w->enable_virgl) {
        /* virgl_renderer_init() stores the callbacks pointer without copying it, so
         * the struct must live on the heap inside HengeVirglWorker for the full lifetime. */
        memset(&w->virgl_cbs, 0, sizeof(w->virgl_cbs));
        w->virgl_cbs.version = 1;
        w->virgl_cbs.write_fence = virgl_cb_write_fence;

        /* Keep all virglrenderer + ANGLE Metal GL calls strictly single-threaded on virgl_thread
         * (VIRGL_RENDERER_THREAD_SYNC spawns a second thread that collides on EGLSurface). */
        int flags = VIRGL_RENDERER_USE_GLES;
#if HENGE_WORKER_HAS_ANGLE_EGL
        bool egl_ok = angle_init_metal_egl(w);
        if (egl_ok) {
            w->virgl_cbs.create_gl_context = virgl_cb_create_gl_context;
            w->virgl_cbs.destroy_gl_context = virgl_cb_destroy_gl_context;
            w->virgl_cbs.make_current = virgl_cb_make_current;
        }
        if (egl_ok && virgl_renderer_init(w, flags, &w->virgl_cbs) == 0) {
            virgl_ok = true;
            fprintf(stderr, "virgl-worker: initialized libvirglrenderer + ANGLE Metal on virgl_thread (flags=0x%x, vram=%u MiB)\n",
                    flags, w->vram_mib);
        } else {
            angle_teardown_metal_egl(w);
            fprintf(stderr, "virgl-worker: ANGLE Metal / virgl_renderer_init failed; staying on 2D KMS fallback\n");
        }
#else
        if (virgl_renderer_init(w, flags, &w->virgl_cbs) == 0) {
            virgl_ok = true;
            fprintf(stderr, "virgl-worker: initialized libvirglrenderer on dedicated virgl_thread (flags=0x%x, vram=%u MiB)\n",
                    flags, w->vram_mib);
        } else {
            fprintf(stderr, "virgl-worker: virgl_renderer_init failed; staying on 2D KMS fallback\n");
        }
#endif
    }
#else
    bool virgl_ok = false;
#endif

    pthread_mutex_lock(&w->mu);
    w->virgl_initialized = virgl_ok;
    w->init_done = true;
    pthread_cond_broadcast(&w->drain_cv);

    for (;;) {
        while (!w->stop && w->q_head == NULL) {
#if HENGE_WORKER_HAS_VIRGL
            uint32_t pending_f = 0U;
            if (w->virgl_initialized) {
                pthread_mutex_lock(&w->fence_mu);
                pending_f = w->fence_count;
                pthread_mutex_unlock(&w->fence_mu);
            }
            if (pending_f > 0U) {
                struct timespec ts;
                clock_gettime(CLOCK_REALTIME, &ts);
                ts.tv_nsec += 2000000L; /* 2 ms poll cadence while fences are in flight */
                if (ts.tv_nsec >= 1000000000L) {
                    ts.tv_sec += 1;
                    ts.tv_nsec -= 1000000000L;
                }
                (void)pthread_cond_timedwait(&w->cv, &w->mu, &ts);
                if (w->q_head == NULL && !w->stop) {
                    pthread_mutex_unlock(&w->mu);
                    virgl_renderer_poll();
                    pthread_mutex_lock(&w->mu);
                }
                continue;
            }
#endif
            pthread_cond_wait(&w->cv, &w->mu);
        }

        if (w->stop && w->q_head == NULL) {
            break;
        }

        HengeWorkNode *node = w->q_head;
        w->q_head = node->next;
        if (w->q_head == NULL) {
            w->q_tail = NULL;
        }
        if (w->q_depth > 0U) {
            w->q_depth--;
        }
        uint64_t active_gen = w->active_generation;
        pthread_mutex_unlock(&w->mu);

        if (node->kind == HENGE_WORK_RESET) {
            flush_stale_fences(w, node->generation, false);
#if HENGE_WORKER_HAS_VIRGL && HENGE_WORKER_HAS_ANGLE_EGL
            angle_release_all_bindings(w);
#endif
            for (uint32_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
                if (w->swapchains[s] != NULL) {
                    henge_gpu_swapchain_destroy(w->swapchains[s]);
                    w->swapchains[s] = henge_gpu_swapchain_create();
                }
            }
#if HENGE_WORKER_HAS_VIRGL
            if (w->virgl_initialized) {
                virgl_renderer_reset();
                virgl_iov_clear_all(w);
            }
#endif
            pthread_mutex_lock(&w->mu);
            w->resets_processed++;
            pthread_mutex_unlock(&w->mu);
        } else if (node->kind == HENGE_WORK_MEMPR) {
#if HENGE_WORKER_HAS_VIRGL
            if (w->virgl_initialized) {
                virgl_renderer_poll();
                virgl_renderer_force_ctx_0();
            }
#endif
        } else if (node->kind == HENGE_WORK_DRAIN) {
#if HENGE_WORKER_HAS_VIRGL
            if (w->virgl_initialized) {
                virgl_renderer_poll();
                virgl_renderer_force_ctx_0();
            }
#endif
            pthread_mutex_lock(&w->mu);
            if (node->generation > w->drain_epoch_done) {
                w->drain_epoch_done = node->generation;
            }
            pthread_cond_broadcast(&w->drain_cv);
            pthread_mutex_unlock(&w->mu);
        } else {
            if (node->generation < active_gen) {
                if (w->on_complete != NULL) {
                    w->on_complete(w->callback_opaque, node->cmd_tag, node->generation, NULL, 0U);
                }
            } else {
                execute_work_cmd(w, node);
            }
        }

        free_work_node(node);
        pthread_mutex_lock(&w->mu);
    }

    pthread_mutex_unlock(&w->mu);

    flush_stale_fences(w, 0ULL, true);
#if HENGE_WORKER_HAS_VIRGL
    if (w->virgl_initialized) {
        virgl_renderer_cleanup(w);
        virgl_iov_clear_all(w);
    }
#if HENGE_WORKER_HAS_ANGLE_EGL
    angle_teardown_metal_egl(w);
#endif
#endif
    return NULL;
}

HengeVirglWorker *henge_virgl_worker_create(const HengeVirglWorkerConfig *cfg) {
    if (cfg == NULL || cfg->gpu == NULL) {
        return NULL;
    }

    HengeVirglWorker *w = calloc(1U, sizeof(*w));
    if (w == NULL) {
        return NULL;
    }

    pthread_mutex_init(&w->mu, NULL);
    pthread_cond_init(&w->cv, NULL);
    pthread_cond_init(&w->drain_cv, NULL);
    pthread_mutex_init(&w->fence_mu, NULL);

    w->gpu = cfg->gpu;
    w->enable_virgl = cfg->enable_virgl;
    w->vram_mib = (cfg->vram_mib >= 64U && cfg->vram_mib <= 2048U) ? cfg->vram_mib : 512U;
    w->callback_opaque = cfg->callback_opaque;
    w->on_complete = cfg->on_complete;
    w->on_display_event = cfg->on_display_event;
    for (uint32_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
        w->swapchains[s] = henge_gpu_swapchain_create();
    }

    /* iOS secondary pthreads default to a 512 KiB stack, which ANGLE's GLSL->MSL compiler
     * and virglrenderer's TGSI translator easily overflow. Allocate an 8 MiB stack explicitly. */
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    (void)pthread_attr_setstacksize(&attr, HENGE_VIRGL_THREAD_STACK_SZ);
    int create_rc = pthread_create(&w->thread, &attr, virgl_worker_thread_main, w);
    pthread_attr_destroy(&attr);
    if (create_rc != 0) {
        for (uint32_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
            henge_gpu_swapchain_destroy(w->swapchains[s]);
            w->swapchains[s] = NULL;
        }
        pthread_mutex_destroy(&w->fence_mu);
        pthread_cond_destroy(&w->drain_cv);
        pthread_cond_destroy(&w->cv);
        pthread_mutex_destroy(&w->mu);
        free(w);
        return NULL;
    }
    w->thread_started = true;

    pthread_mutex_lock(&w->mu);
    while (!w->init_done) {
        pthread_cond_wait(&w->drain_cv, &w->mu);
    }
    pthread_mutex_unlock(&w->mu);
    return w;
}

void henge_virgl_worker_destroy(HengeVirglWorker *worker) {
    if (worker == NULL) {
        return;
    }
    henge_virgl_unregister_active_worker(worker);

    pthread_mutex_lock(&worker->mu);
    worker->stop = true;
    pthread_cond_broadcast(&worker->cv);
    pthread_cond_broadcast(&worker->drain_cv);
    pthread_mutex_unlock(&worker->mu);

    if (worker->thread_started) {
        pthread_join(worker->thread, NULL);
        worker->thread_started = false;
    }

    while (worker->q_head != NULL) {
        HengeWorkNode *node = worker->q_head;
        worker->q_head = node->next;
        free_work_node(node);
    }
    flush_stale_fences(worker, 0ULL, true);
    for (uint32_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
        henge_gpu_swapchain_destroy(worker->swapchains[s]);
        worker->swapchains[s] = NULL;
    }

    pthread_mutex_destroy(&worker->fence_mu);
    pthread_cond_destroy(&worker->drain_cv);
    pthread_cond_destroy(&worker->cv);
    pthread_mutex_destroy(&worker->mu);
    free(worker);
}

bool henge_virgl_worker_is_virgl_active(const HengeVirglWorker *worker) {
    return worker != NULL && worker->virgl_initialized;
}

uint32_t henge_virgl_worker_num_capsets(const HengeVirglWorker *worker) {
    return (worker != NULL && worker->virgl_initialized) ? 2U : 0U;
}

int henge_virgl_worker_enqueue(HengeVirglWorker *worker, const HengeVirglCommand *cmd) {
    if (worker == NULL || cmd == NULL) {
        return -1;
    }
    if (cmd->payload_len > HENGE_VIRGL_MAX_PAYLOAD_LEN ||
        (cmd->payload_len > 0U && cmd->payload == NULL)) {
        return -1;
    }
    if (cmd->backing_count > HENGE_VIRGL_MAX_BACKING ||
        (cmd->backing_count > 0U && cmd->backing == NULL)) {
        return -1;
    }

    HengeWorkNode *node = calloc(1U, sizeof(*node));
    if (node == NULL) {
        return -1;
    }
    node->kind = HENGE_WORK_CMD;
    node->queue_index = cmd->queue_index;
    node->cmd_type = cmd->cmd_type;
    node->flags = cmd->flags;
    node->fence_id = cmd->fence_id;
    node->ctx_id = cmd->ctx_id;
    node->ring_idx = cmd->ring_idx;
    node->generation = cmd->generation;
    node->cmd_tag = cmd->cmd_tag;

    if (cmd->payload_len > 0U) {
        node->payload = malloc(cmd->payload_len);
        if (node->payload == NULL) {
            free_work_node(node);
            return -1;
        }
        memcpy(node->payload, cmd->payload, cmd->payload_len);
        node->payload_len = cmd->payload_len;
    }
    if (cmd->backing_count > 0U) {
        node->backing = malloc((size_t)cmd->backing_count * sizeof(*node->backing));
        if (node->backing == NULL) {
            free_work_node(node);
            return -1;
        }
        memcpy(node->backing, cmd->backing, (size_t)cmd->backing_count * sizeof(*node->backing));
        node->backing_count = cmd->backing_count;
    }

    pthread_mutex_lock(&worker->mu);
    if (worker->stop || worker->q_depth >= HENGE_VIRGL_MAX_QUEUE_DEPTH) {
        pthread_mutex_unlock(&worker->mu);
        free_work_node(node);
        return -1;
    }
    if (worker->q_tail == NULL) {
        worker->q_head = node;
        worker->q_tail = node;
    } else {
        worker->q_tail->next = node;
        worker->q_tail = node;
    }
    worker->q_depth++;
    worker->cmds_enqueued++;
    pthread_cond_signal(&worker->cv);
    pthread_mutex_unlock(&worker->mu);
    return 0;
}

int henge_virgl_worker_enqueue_reset(HengeVirglWorker *worker, uint64_t new_generation) {
    if (worker == NULL) {
        return -1;
    }
    HengeWorkNode *node = calloc(1U, sizeof(*node));
    if (node == NULL) {
        return -1;
    }
    node->kind = HENGE_WORK_RESET;
    node->generation = new_generation;

    pthread_mutex_lock(&worker->mu);
    if (worker->stop) {
        pthread_mutex_unlock(&worker->mu);
        free_work_node(node);
        return -1;
    }
    if (new_generation > worker->active_generation) {
        worker->active_generation = new_generation;
    }
    if (worker->q_tail == NULL) {
        worker->q_head = node;
        worker->q_tail = node;
    } else {
        worker->q_tail->next = node;
        worker->q_tail = node;
    }
    worker->q_depth++;
    pthread_cond_signal(&worker->cv);
    pthread_mutex_unlock(&worker->mu);
    return 0;
}

int henge_virgl_worker_drain(HengeVirglWorker *worker, uint32_t timeout_ms) {
    if (worker == NULL) {
        return 0;
    }
    HengeWorkNode *node = calloc(1U, sizeof(*node));
    if (node == NULL) {
        return -1;
    }
    node->kind = HENGE_WORK_DRAIN;

    pthread_mutex_lock(&worker->mu);
    if (worker->stop) {
        pthread_mutex_unlock(&worker->mu);
        free_work_node(node);
        return 0;
    }
    uint64_t target_epoch = ++worker->drain_epoch_req;
    node->generation = target_epoch;
    if (worker->q_tail == NULL) {
        worker->q_head = node;
        worker->q_tail = node;
    } else {
        worker->q_tail->next = node;
        worker->q_tail = node;
    }
    worker->q_depth++;
    pthread_cond_signal(&worker->cv);

    int rc = 0;
    if (timeout_ms == 0U) {
        while (!worker->stop && worker->drain_epoch_done < target_epoch) {
            pthread_cond_wait(&worker->drain_cv, &worker->mu);
        }
    } else {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += (time_t)(timeout_ms / 1000U);
        ts.tv_nsec += (long)(timeout_ms % 1000U) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) {
            ts.tv_sec += 1;
            ts.tv_nsec -= 1000000000L;
        }
        while (!worker->stop && worker->drain_epoch_done < target_epoch) {
            int wrc = pthread_cond_timedwait(&worker->drain_cv, &worker->mu, &ts);
            if (wrc == ETIMEDOUT) {
                rc = -1;
                break;
            }
        }
    }
    pthread_mutex_unlock(&worker->mu);
    return rc;
}

void henge_virgl_worker_get_stats(const HengeVirglWorker *worker,
                                  HengeVirglWorkerStats *out_stats) {
    if (out_stats == NULL) {
        return;
    }
    memset(out_stats, 0, sizeof(*out_stats));
    if (worker == NULL) {
        return;
    }
    HengeVirglWorker *mut = (HengeVirglWorker *)worker;
    pthread_mutex_lock(&mut->mu);
    out_stats->cmds_enqueued = mut->cmds_enqueued;
    out_stats->cmds_completed = mut->cmds_completed;
    out_stats->fences_retired = mut->fences_retired;
    out_stats->resets_processed = mut->resets_processed;
    out_stats->flushes_3d = mut->flushes_3d;
    out_stats->pending_queue_depth = mut->q_depth;
    out_stats->virgl_initialized = mut->virgl_initialized;
    pthread_mutex_unlock(&mut->mu);

    pthread_mutex_lock(&mut->fence_mu);
    out_stats->pending_fence_count = mut->fence_count;
    pthread_mutex_unlock(&mut->fence_mu);
}

int henge_virgl_worker_get_front_surface(const HengeVirglWorker *worker,
                                         uint32_t scanout_id,
                                         HengeGpuSwapchainSlot *out_slot) {
    if (worker == NULL || out_slot == NULL || scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
        return -1;
    }
    if (worker->swapchains[scanout_id] == NULL) {
        return -1;
    }
    return henge_gpu_swapchain_get_front(worker->swapchains[scanout_id], out_slot);
}

int henge_virgl_worker_notify_memory_pressure(HengeVirglWorker *worker) {
    if (worker == NULL) {
        return 0;
    }
    HengeWorkNode *node = calloc(1U, sizeof(*node));
    if (node == NULL) {
        return -1;
    }
    node->kind = HENGE_WORK_MEMPR;
    pthread_mutex_lock(&worker->mu);
    if (worker->stop) {
        pthread_mutex_unlock(&worker->mu);
        free_work_node(node);
        return 0;
    }
    if (worker->q_tail == NULL) {
        worker->q_head = node;
        worker->q_tail = node;
    } else {
        worker->q_tail->next = node;
        worker->q_tail = node;
    }
    worker->q_depth++;
    pthread_cond_signal(&worker->cv);
    pthread_mutex_unlock(&worker->mu);
    return 0;
}

static uint32_t sanitize_pipe_tex_wrap(uint32_t wrap,
                                       bool allow_border_clamp,
                                       bool allow_mirror_clamp) {
    /* PIPE_TEX_WRAP_CLAMP_TO_EDGE = 2, CLAMP_TO_BORDER = 3,
     * MIRROR_CLAMP = 5, MIRROR_CLAMP_TO_EDGE = 6, MIRROR_CLAMP_TO_BORDER = 7. */
    if (!allow_border_clamp && (wrap == 3U || wrap == 7U)) {
        return 2U;
    }
    if (!allow_mirror_clamp && (wrap == 5U || wrap == 6U || wrap == 7U)) {
        return 2U;
    }
    return wrap;
}

uint32_t henge_virgl_sanitize_cmd_stream(uint32_t *cmds,
                                         size_t ndw,
                                         bool allow_border_clamp,
                                         bool allow_mirror_clamp) {
    if (cmds == NULL || ndw == 0U || (allow_border_clamp && allow_mirror_clamp)) {
        return 0U;
    }
    uint32_t rewritten = 0U;
    size_t off = 0U;
    while (off < ndw) {
        uint32_t h = cmds[off];
        uint32_t clen = h >> 16;
        uint32_t cobj = (h >> 8) & 0xFFU;
        uint32_t ccmd = h & 0xFFU;
        if ((size_t)clen > ndw - off - 1U) {
            break;
        }
        /* VIRGL_CCMD_CREATE_OBJECT (1), VIRGL_OBJECT_SAMPLER_STATE (7), length 9. */
        if (ccmd == 1U && cobj == 7U && clen == 9U) {
            uint32_t s0 = cmds[off + 2U];
            uint32_t ws = sanitize_pipe_tex_wrap((s0 >> 0U) & 0x7U, allow_border_clamp, allow_mirror_clamp);
            uint32_t wt = sanitize_pipe_tex_wrap((s0 >> 3U) & 0x7U, allow_border_clamp, allow_mirror_clamp);
            uint32_t wr = sanitize_pipe_tex_wrap((s0 >> 6U) & 0x7U, allow_border_clamp, allow_mirror_clamp);
            uint32_t new_s0 = (s0 & ~0x1FFU) | ws | (wt << 3U) | (wr << 6U);
            if (new_s0 != s0) {
                cmds[off + 2U] = new_s0;
                rewritten++;
            }
        }
        off += 1U + (size_t)clen;
    }
    return rewritten;
}

void henge_virgl_register_active_worker(HengeVirglWorker *worker) {
    pthread_mutex_lock(&g_active_worker_mu);
    g_active_worker = worker;
    pthread_mutex_unlock(&g_active_worker_mu);
}

void henge_virgl_unregister_active_worker(HengeVirglWorker *worker) {
    pthread_mutex_lock(&g_active_worker_mu);
    if (g_active_worker == worker) {
        g_active_worker = NULL;
    }
    pthread_mutex_unlock(&g_active_worker_mu);
}

void henge_virgl_drain_active_worker(uint32_t timeout_ms) {
    pthread_mutex_lock(&g_active_worker_mu);
    HengeVirglWorker *w = g_active_worker;
    if (w != NULL) {
        (void)henge_virgl_worker_drain(w, timeout_ms);
    }
    pthread_mutex_unlock(&g_active_worker_mu);
}

void henge_virgl_notify_active_memory_pressure(void) {
    pthread_mutex_lock(&g_active_worker_mu);
    HengeVirglWorker *w = g_active_worker;
    if (w != NULL) {
        (void)henge_virgl_worker_notify_memory_pressure(w);
    }
    pthread_mutex_unlock(&g_active_worker_mu);
}
