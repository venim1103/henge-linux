/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "HengeVMBridge.h"

#include "henge_platform.h"
#include "henge_txm_jit.h"
#include "henge_virtio_gpu.h"

#include <cstdlib>
#include <cstring>
#include <string>

#if __has_include("winvm.h") && __has_include("share.h")
#define HENGE_HAS_UPSTREAM_ENGINE 1
extern "C" {
#include "hvsparse.h"
#include "share.h"
#include "winvm.h"
}
#else
#define HENGE_HAS_UPSTREAM_ENGINE 0
#endif

static NSString *const HengeVMErrorDomain = @"io.hengelinux.vm";

@interface HengeVMBridge () {
    BOOL _running;
    BOOL _vmCreated;
    uint32_t _activeRamMiB;
    int _activeCpuCount;
    NSString *_statusText;
    CAMetalLayer *__weak _displayLayer;
    void *_guestRam;
    size_t _guestRamBytes;
    HengeVirtioGpuConfig _gpuConfig;
    HengeVirtioGpuDevice *_gpuDevice;
    std::string _codePathStr;
    std::string _varsPathStr;
    std::string _diskPathStr;
    std::string _shareDirStr;
    std::string _shareSockStr;
    std::string _snapshotPathStr;
}
- (void)handleEngineExitReason:(int)reason;
@end

#if HENGE_HAS_UPSTREAM_ENGINE
static void henge_on_vm_exit(int reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [HengeVMBridge.shared handleEngineExitReason:reason];
    });
}
#endif

@implementation HengeVMBridge

+ (HengeVMBridge *)shared {
    static HengeVMBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HengeVMBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _running = NO;
        _vmCreated = NO;
        _activeRamMiB = 0;
        _activeCpuCount = 4;
        _statusText = self.isEngineLinked
            ? @"Engine linked · Ready"
            : @"Host substrate ready (run sync_upstream.sh + build_ios_deps.sh for full VM)";
        _guestRam = nullptr;
        _guestRamBytes = 0;
        _gpuDevice = nullptr;
    }
    return self;
}

- (BOOL)isEngineLinked {
#if HENGE_HAS_UPSTREAM_ENGINE
    return YES;
#else
    return NO;
#endif
}

- (BOOL)isRunning {
    return _running;
}

- (BOOL)isVirgl3DActive {
    return _running &&
           _gpuDevice != nullptr &&
           henge_virtio_gpu_supports_virgl(&_gpuConfig) &&
           henge_virtio_gpu_has_virglrenderer();
}

- (BOOL)hasSavedBackgroundSnapshot {
    NSURL *docsURL = [self documentsDirectoryURL];
    NSURL *snapURL = [[[docsURL URLByAppendingPathComponent:@"Machines" isDirectory:YES]
                        URLByAppendingPathComponent:@"ArchLinux" isDirectory:YES]
                       URLByAppendingPathComponent:@"suspend.state"];
    HengeVmSnapshotInfo info;
    return henge_vm_snapshot_read(snapURL.path.fileSystemRepresentation, &info, nullptr, 0U) == 0;
}

- (uint32_t)activeRamMiB {
    return _activeRamMiB;
}

- (NSString *)statusText {
    return _statusText;
}

- (uint64_t)framesPresented {
    uint64_t virglFrames = (_gpuDevice != nullptr) ? henge_virtio_gpu_flush_count(_gpuDevice) : 0ULL;
#if HENGE_HAS_UPSTREAM_ENGINE
    return _running ? (hv_winvm_display_frames() + virglFrames) : 0ULL;
#else
    return _running ? virglFrames : 0ULL;
#endif
}

- (void)attachDisplayLayer:(nullable CAMetalLayer *)layer {
    if (_displayLayer == layer) {
        return;
    }
    _displayLayer = layer;
#if HENGE_HAS_UPSTREAM_ENGINE
    if (_vmCreated) {
        hv_winvm_set_display_layer(layer != nil ? (__bridge void *)layer : nullptr);
    }
#endif
}

- (void)detachDisplayLayerIfMatching:(nullable CAMetalLayer *)layer {
    if (layer == nil || _displayLayer == layer) {
        [self attachDisplayLayer:nil];
    }
}

- (void)prepareDiskImageWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSURL *docsURL = [self documentsDirectoryURL];
    NSURL *machineDir = [[docsURL URLByAppendingPathComponent:@"Machines" isDirectory:YES]
                         URLByAppendingPathComponent:@"ArchLinux" isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:machineDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSURL *codeURL = [machineDir URLByAppendingPathComponent:@"code.fd"];
    NSURL *varsURL = [machineDir URLByAppendingPathComponent:@"vars.fd"];
    NSURL *sparseURL = [machineDir URLByAppendingPathComponent:@"archlinux.hvsparse"];
    NSURL *rawDiskURL = [machineDir URLByAppendingPathComponent:@"archlinux.img"];

    BOOL hasSparse = [fm fileExistsAtPath:sparseURL.path];
    BOOL hasRaw = [fm fileExistsAtPath:rawDiskURL.path];

    if (![fm fileExistsAtPath:codeURL.path] ||
        ![fm fileExistsAtPath:varsURL.path] ||
        (!hasSparse && !hasRaw)) {
        NSString *msg = @"Missing guest files in Files -> HengeLinux -> Machines/ArchLinux/ (need code.fd, vars.fd, and archlinux.hvsparse).";
        _statusText = msg;
        NSError *err = [NSError errorWithDomain:HengeVMErrorDomain
                                           code:1001
                                       userInfo:@{NSLocalizedDescriptionKey: msg}];
        completion(NO, err);
        return;
    }

#if HENGE_HAS_UPSTREAM_ENGINE
    if (hasSparse) {
        BOOL needsUnpack = !hasRaw;
        if (hasRaw) {
            NSDictionary *sparseAttrs = [fm attributesOfItemAtPath:sparseURL.path error:nil];
            NSDictionary *rawAttrs = [fm attributesOfItemAtPath:rawDiskURL.path error:nil];
            NSDate *sparseMod = sparseAttrs[NSFileModificationDate];
            NSDate *rawMod = rawAttrs[NSFileModificationDate];
            unsigned long long rawSize = [rawAttrs[NSFileSize] unsignedLongLongValue];
            if (rawSize == 0ULL || (sparseMod != nil && rawMod != nil && [sparseMod compare:rawMod] == NSOrderedDescending)) {
                needsUnpack = YES;
            }
        }
        if (needsUnpack) {
            _statusText = @"Unpacking archlinux.hvsparse disk image...";
            std::string sparseStr = sparseURL.path.fileSystemRepresentation;
            std::string rawStr = rawDiskURL.path.fileSystemRepresentation;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                std::remove(rawStr.c_str());
                int rc = hv_sparse_unpack(sparseStr.c_str(), rawStr.c_str(), nullptr, nullptr);
                if (rc != 0) {
                    std::remove(rawStr.c_str());
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (rc != 0) {
                        NSString *msg = @"Failed to unpack archlinux.hvsparse into sparse raw NVMe disk image.";
                        self->_statusText = msg;
                        NSError *err = [NSError errorWithDomain:HengeVMErrorDomain
                                                           code:1007
                                                       userInfo:@{NSLocalizedDescriptionKey: msg}];
                        completion(NO, err);
                    } else {
                        completion(YES, nil);
                    }
                });
            });
            return;
        }
    }
#endif
    completion(YES, nil);
}

- (NSURL *)documentsDirectoryURL {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
    if (!docs) {
        docs = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    }
    return docs;
}

- (BOOL)startGuestWithRamMiB:(uint32_t)ramMiB
                    cpuCount:(int)cpuCount
                  gpuBackend:(int)gpuBackend
                       error:(NSError * _Nullable * _Nullable)error {
    if (_running) {
        return YES;
    }
    if (_vmCreated || _guestRam != nullptr) {
        [self stopGuest];
    }

    hengelinux_reset_suspend_counter();

    HengeGpuBackendMode mode = (gpuBackend == 1)
        ? HENGE_GPU_BACKEND_VIRGL_3D
        : HENGE_GPU_BACKEND_GOP_2D;
    henge_virtio_gpu_init_config(mode, (mode == HENGE_GPU_BACKEND_VIRGL_3D) ? 512U : 128U, &_gpuConfig);
    if (_gpuDevice != nullptr) {
        henge_virtio_gpu_destroy(_gpuDevice);
        _gpuDevice = nullptr;
    }
    _gpuDevice = henge_virtio_gpu_create(&_gpuConfig);

    NSURL *docsURL = [self documentsDirectoryURL];
    NSURL *machineDir = [[docsURL URLByAppendingPathComponent:@"Machines" isDirectory:YES]
                         URLByAppendingPathComponent:@"ArchLinux" isDirectory:YES];
    NSURL *sharedDir = [docsURL URLByAppendingPathComponent:@"Shared" isDirectory:YES];

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:machineDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:sharedDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSURL *codeURL = [machineDir URLByAppendingPathComponent:@"code.fd"];
    NSURL *varsURL = [machineDir URLByAppendingPathComponent:@"vars.fd"];
    NSURL *sparseURL = [machineDir URLByAppendingPathComponent:@"archlinux.hvsparse"];
    NSURL *rawDiskURL = [machineDir URLByAppendingPathComponent:@"archlinux.img"];
    NSURL *snapURL = [machineDir URLByAppendingPathComponent:@"suspend.state"];
    _snapshotPathStr = snapURL.path.fileSystemRepresentation;

    HengeVmSnapshotInfo prevSnapshot;
    std::memset(&prevSnapshot, 0, sizeof(prevSnapshot));
    BOOL hadPriorSnapshot = (henge_vm_snapshot_read(_snapshotPathStr.c_str(), &prevSnapshot, nullptr, 0U) == 0);
    (void)hadPriorSnapshot;

    BOOL hasSparse = [fm fileExistsAtPath:sparseURL.path];
    BOOL hasRaw = [fm fileExistsAtPath:rawDiskURL.path];

    if (![fm fileExistsAtPath:codeURL.path] ||
        ![fm fileExistsAtPath:varsURL.path] ||
        (!hasSparse && !hasRaw)) {
        NSString *msg = @"Missing guest files in Files -> HengeLinux -> Machines/ArchLinux/ (need code.fd, vars.fd, and archlinux.hvsparse).";
        _statusText = msg;
        if (error) {
            *error = [NSError errorWithDomain:HengeVMErrorDomain
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

#if HENGE_HAS_UPSTREAM_ENGINE
    /* Unpack HVSPARSE archive into an APFS sparse raw image on first boot or
     * whenever archlinux.hvsparse is newer than archlinux.img. */
    if (hasSparse) {
        BOOL needsUnpack = !hasRaw;
        if (hasRaw) {
            NSDictionary *sparseAttrs = [fm attributesOfItemAtPath:sparseURL.path error:nil];
            NSDictionary *rawAttrs = [fm attributesOfItemAtPath:rawDiskURL.path error:nil];
            NSDate *sparseMod = sparseAttrs[NSFileModificationDate];
            NSDate *rawMod = rawAttrs[NSFileModificationDate];
            unsigned long long rawSize = [rawAttrs[NSFileSize] unsignedLongLongValue];
            if (rawSize == 0ULL || (sparseMod != nil && rawMod != nil && [sparseMod compare:rawMod] == NSOrderedDescending)) {
                needsUnpack = YES;
            }
        }
        if (needsUnpack) {
            [fm removeItemAtURL:rawDiskURL error:nil];
            if (hv_sparse_unpack(sparseURL.path.fileSystemRepresentation,
                                 rawDiskURL.path.fileSystemRepresentation,
                                 nullptr,
                                 nullptr) != 0) {
                [fm removeItemAtURL:rawDiskURL error:nil];
                NSString *msg = @"Failed to unpack archlinux.hvsparse into sparse raw NVMe disk image.";
                _statusText = msg;
                if (error) {
                    *error = [NSError errorWithDomain:HengeVMErrorDomain
                                                 code:1007
                                             userInfo:@{NSLocalizedDescriptionKey: msg}];
                }
                return NO;
            }
        }
    }

    /* Acquire TXM dual-mapped RX/RW JIT pool BEFORE mapping multi-GB guest RAM
     * so virtual address space around RX remains uncrowded for vm_remap. */
    HengeJitPool jitPool;
    std::memset(&jitPool, 0, sizeof(jitPool));
    if (!henge_jit_acquire_pool((size_t)HENGE_DEFAULT_JIT_POOL_BYTES, true, &jitPool)) {
        char jitErr[256] = {0};
        henge_jit_copy_status(jitErr, sizeof(jitErr));
        NSString *msg = (jitErr[0] != '\0')
            ? [NSString stringWithFormat:@"TXM JIT pool not active (%s). Attach StikDebug (henge-jit.js) or LLDB, then tap Boot.", jitErr]
            : @"TXM JIT pool not active. Attach StikDebug (henge-jit.js) or LLDB, then tap Boot.";
        _statusText = msg;
        if (error) {
            *error = [NSError errorWithDomain:HengeVMErrorDomain
                                         code:1006
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    uint32_t cappedRequestMiB = ramMiB;
    if (!henge_txm_is_cs_debugged() && cappedRequestMiB > 1536U) {
        cappedRequestMiB = 1536U;
    }

    uint64_t alignedBytes = henge_align_guest_ram_bytes(cappedRequestMiB, 8192U);
    bool ledgerExempt = false;
    void *ramPtr = henge_alloc_ledger_exempt_ram((size_t)alignedBytes, &ledgerExempt);
    if (!ramPtr) {
        NSString *msg = @"Failed to allocate 16 KiB-aligned guest RAM.";
        _statusText = msg;
        if (error) {
            *error = [NSError errorWithDomain:HengeVMErrorDomain
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    [fm createDirectoryAtPath:NSTemporaryDirectory()
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];

    char shareSockPath[HENGE_DARWIN_SUN_PATH_MAX];
    if (henge_format_unix_socket_path(machineDir.path.fileSystemRepresentation,
                                      "share.sock",
                                      shareSockPath,
                                      sizeof(shareSockPath)) != 0) {
        henge_free_ledger_exempt_ram(ramPtr, (size_t)alignedBytes);
        NSString *msg = @"Failed to format <104-byte AF_UNIX socket path inside app sandbox.";
        _statusText = msg;
        if (error) {
            *error = [NSError errorWithDomain:HengeVMErrorDomain
                                         code:1003
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    _codePathStr = codeURL.path.fileSystemRepresentation;
    _varsPathStr = varsURL.path.fileSystemRepresentation;
    _diskPathStr = rawDiskURL.path.fileSystemRepresentation;
    _shareDirStr = sharedDir.path.fileSystemRepresentation;
    _shareSockStr = shareSockPath;

    HvWinVmConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.code_fd = _codePathStr.c_str();
    cfg.vars_fd = _varsPathStr.c_str();
    cfg.disk0 = _diskPathStr.c_str();
    cfg.share_dir = _shareDirStr.c_str();
    cfg.share_sock = _shareSockStr.c_str();
    cfg.ncpus = (cpuCount > 0) ? cpuCount : 4;
    cfg.ram_mb = alignedBytes / (1024ULL * 1024ULL);
    cfg.jit_rx = (void *)jitPool.rx_base;
    cfg.jit_rw = (void *)jitPool.rw_base;
    cfg.jit_bytes = jitPool.size;
    cfg.prealloc_ram = ramPtr;
    cfg.enable_sound = 1;

    char errBuf[512];
    std::memset(errBuf, 0, sizeof(errBuf));
    if (hv_winvm_create(&cfg, errBuf, sizeof(errBuf)) != 0) {
        henge_free_ledger_exempt_ram(ramPtr, (size_t)alignedBytes);
        NSString *msg = errBuf[0] != '\0'
            ? [NSString stringWithUTF8String:errBuf]
            : @"hv_winvm_create failed";
        _statusText = msg;
        if (error) {
            *error = [NSError errorWithDomain:HengeVMErrorDomain
                                         code:1004
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    _guestRam = ramPtr;
    _guestRamBytes = (size_t)alignedBytes;
    _activeRamMiB = (uint32_t)cfg.ram_mb;
    _activeCpuCount = cfg.ncpus;
    _vmCreated = YES;
    _running = YES;
    NSString *gpuLabel = @"2D GOP";
    if (_gpuConfig.mode == HENGE_GPU_BACKEND_VIRGL_3D) {
        gpuLabel = henge_virtio_gpu_has_virglrenderer()
            ? @"VirGL 3D"
            : @"2D GOP (VirGL 3D staged)";
    }
    _statusText = [NSString stringWithFormat:@"Running · %llu MiB · %@ (%@)",
                   cfg.ram_mb,
                   gpuLabel,
                   ledgerExempt ? @"LEDGER_NO_FOOTPRINT" : @"standard ledger"];

    CAMetalLayer *layer = _displayLayer;
    if (layer != nil) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }
    hv_winvm_start(1, henge_on_vm_exit);
    return YES;
#else
    NSString *msg = @"Upstream WindowsiOS engine not compiled into libhengelinux.a yet (run sync_upstream.sh + build_ios_deps.sh).";
    _statusText = msg;
    if (error) {
        *error = [NSError errorWithDomain:HengeVMErrorDomain
                                     code:1005
                                 userInfo:@{NSLocalizedDescriptionKey: msg}];
    }
    return NO;
#endif
}

- (BOOL)saveBackgroundSnapshot {
    if (!_running || _snapshotPathStr.empty()) {
        return NO;
    }
#if HENGE_HAS_UPSTREAM_ENGINE
    if (_vmCreated) {
        hv_winvm_flush_disks();
    }
#endif
    HengeVmSnapshotInfo info;
    std::memset(&info, 0, sizeof(info));
    info.version = 1U;
    info.ram_mib = _activeRamMiB;
    info.cpu_count = (_activeCpuCount > 0) ? (uint32_t)_activeCpuCount : 4U;
    info.gpu_mode = (uint32_t)_gpuConfig.mode;
    info.scanout0_res_id = (_gpuDevice != nullptr)
        ? henge_virtio_gpu_scanout_resource(_gpuDevice, 0U)
        : 0U;
    info.suspend_counter_offset = hengelinux_suspend_counter_offset();
    info.gpu_flush_count = (_gpuDevice != nullptr)
        ? henge_virtio_gpu_flush_count(_gpuDevice)
        : 0ULL;
    return henge_vm_snapshot_write(_snapshotPathStr.c_str(), &info, nullptr, 0U) == 0;
}

- (void)stopGuest {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (_vmCreated) {
        hv_winvm_set_display_layer(nullptr);
        hv_winvm_stop();
        hv_winvm_flush_disks();
    }
#endif
    if (_gpuDevice != nullptr) {
        henge_virtio_gpu_destroy(_gpuDevice);
        _gpuDevice = nullptr;
    }
    _running = NO;
    _vmCreated = NO;
    _activeRamMiB = 0;
    _activeCpuCount = 4;
    if (_guestRam != nullptr && _guestRamBytes > 0) {
        henge_free_ledger_exempt_ram(_guestRam, _guestRamBytes);
        _guestRam = nullptr;
        _guestRamBytes = 0;
    }
    _statusText = @"Stopped";
}

- (void)handleEngineExitReason:(int)reason {
#if HENGE_HAS_UPSTREAM_ENGINE
    const char *name = hv_winvm_reason_name(reason);
    NSString *exitMsg = [NSString stringWithFormat:@"Guest halted (%s)", name ? name : "exit"];
#else
    (void)reason;
    NSString *exitMsg = @"Guest halted";
#endif
    [self stopGuest];
    _statusText = exitMsg;
}

- (void)sendHidKeyUsage:(uint8_t)usage pressed:(BOOL)pressed {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (_running) {
        hv_winvm_key_hid(usage, pressed ? 1 : 0);
    }
#else
    (void)usage;
    (void)pressed;
#endif
}

- (void)tapHidKeyUsage:(uint8_t)usage {
    [self sendHidKeyUsage:usage pressed:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self sendHidKeyUsage:usage pressed:NO];
    });
}

- (void)sendCtrlAltDel {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (_running) {
        hv_winvm_send_ctrl_alt_del();
    }
#endif
}

- (void)sendPointerNormX:(double)xNorm
                   normY:(double)yNorm
                 buttons:(uint8_t)buttons
                   wheel:(int8_t)wheel {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (_running) {
        hv_winvm_tablet(xNorm, yNorm, buttons, wheel);
    }
#else
    (void)xNorm;
    (void)yNorm;
    (void)buttons;
    (void)wheel;
#endif
}

- (nullable NSString *)takePendingOpenURL {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (!_running) {
        return nil;
    }
    char *raw = hv_share_take_open_url();
    if (!raw) {
        return nil;
    }
    NSString *urlStr = [NSString stringWithUTF8String:raw];
    std::free(raw);
    if (!urlStr) {
        return nil;
    }
    NSURL *parsed = [NSURL URLWithString:urlStr];
    NSString *scheme = parsed.scheme.lowercaseString;
    if (!parsed.host.length || (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])) {
        return nil;
    }
    return urlStr;
#else
    return nil;
#endif
}

- (BOOL)takePendingOAuthDone {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (!_running) {
        return NO;
    }
    return hv_share_take_oauth_done() != 0;
#else
    return NO;
#endif
}

- (void)pushHostClipboard:(NSString *)text {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (_running && text.length > 0) {
        hv_share_set_clipboard(text.UTF8String);
    }
#else
    (void)text;
#endif
}

- (nullable NSString *)takeGuestClipboard {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (!_running) {
        return nil;
    }
    char *raw = hv_share_take_clipboard();
    if (!raw) {
        return nil;
    }
    NSString *clip = [NSString stringWithUTF8String:raw];
    std::free(raw);
    return clip;
#else
    return nil;
#endif
}

@end
