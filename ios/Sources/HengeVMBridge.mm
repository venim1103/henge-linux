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
    uint8_t _hidModifiers;
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
    std::string _bootLogPathStr;
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
        _hidModifiers = 0;
        _statusText = self.isEngineLinked
            ? @"Engine linked · Ready"
            : @"Host substrate ready (run sync_upstream.sh + build_ios_deps.sh for full VM)";
        _guestRam = nullptr;
        _guestRamBytes = 0;
        _gpuDevice = nullptr;

        NSURL *docsURL = [self documentsDirectoryURL];
        NSURL *logURL = [docsURL URLByAppendingPathComponent:@"hengelinux-boot.log"];
        _bootLogPathStr = logURL.path.fileSystemRepresentation;
        hengelinux_start_console_capture(_bootLogPathStr.c_str());
        hengelinux_console_append_line("[bridge] HengeVMBridge initialized");
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

- (uint64_t)consoleTotalBytes {
    return hengelinux_console_total_bytes();
}

- (NSString *)bootLogFilePath {
    if (_bootLogPathStr.empty()) {
        return @"";
    }
    return [NSString stringWithUTF8String:_bootLogPathStr.c_str()] ?: @"";
}

- (NSString *)copyConsoleLog {
    char *buf = static_cast<char *>(std::malloc(65536U));
    if (buf == nullptr) {
        return @"";
    }
    size_t n = hengelinux_copy_console_log(buf, 65536U);
    NSString *str = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
    if (str == nil) {
        str = [[NSString alloc] initWithBytes:buf length:n encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    std::free(buf);
    return str;
}

- (void)clearConsoleLog {
    hengelinux_clear_console_log();
}

- (NSString *)diagnosticSnapshot {
    HengeJitPool pool;
    std::memset(&pool, 0, sizeof(pool));
    bool hasPool = henge_jit_current_pool(&pool);
    bool csDebugged = henge_txm_is_cs_debugged();
    bool ptraced = henge_txm_is_ptraced();
    uint64_t frames = [self framesPresented];
    uint64_t logBytes = [self consoleTotalBytes];
    NSString *jitDesc = hasPool
        ? [NSString stringWithFormat:@"Blessed (%zu MiB @ 0x%llx)",
           pool.size >> 20,
           (unsigned long long)pool.rx_base]
        : @"Inactive";
    return [NSString stringWithFormat:
            @"EngineLinked=%@ | Running=%@ | Frames=%llu | LogBytes=%llu\n"
            @"CS_DEBUGGED=%@ | P_TRACED=%@ | JIT=%@\n"
            @"RAM=%u MiB | vCPUs=%d | Layer=%@ | Status=%@",
            self.isEngineLinked ? @"YES" : @"NO",
            _running ? @"YES" : @"NO",
            (unsigned long long)frames,
            (unsigned long long)logBytes,
            csDebugged ? @"YES" : @"NO",
            ptraced ? @"YES" : @"NO",
            jitDesc,
            _activeRamMiB,
            _activeCpuCount,
            (_displayLayer != nil) ? @"Attached" : @"Nil",
            _statusText ?: @""];
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
        NSDictionary *sparseAttrs = [fm attributesOfItemAtPath:sparseURL.path error:nil];
        unsigned long long sparseSize = [sparseAttrs[NSFileSize] unsignedLongLongValue];
        BOOL needsUnpack = !hasRaw;
        if (hasRaw) {
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
            NSString *unpackMsg = [NSString stringWithFormat:
                @"[bridge] Unpacking archlinux.hvsparse (%llu bytes) -> archlinux.img...",
                sparseSize];
            hengelinux_console_append_line(unpackMsg.UTF8String);
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
                        hengelinux_console_append_line("[bridge] ERROR: hv_sparse_unpack failed");
                        NSError *err = [NSError errorWithDomain:HengeVMErrorDomain
                                                           code:1007
                                                       userInfo:@{NSLocalizedDescriptionKey: msg}];
                        completion(NO, err);
                    } else {
                        hengelinux_console_append_line("[bridge] Unpacked archlinux.img successfully");
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
    NSString *createDiag = [NSString stringWithFormat:
        @"[bridge] Calling hv_winvm_create(ram=%llu MiB, cpus=%d, jit_rx=0x%llx, jit_bytes=%zu, cs_debugged=%d, ptraced=%d)",
        cfg.ram_mb,
        cfg.ncpus,
        (unsigned long long)jitPool.rx_base,
        jitPool.size,
        henge_txm_is_cs_debugged() ? 1 : 0,
        henge_txm_is_ptraced() ? 1 : 0];
    hengelinux_console_append_line(createDiag.UTF8String);
    if (hv_winvm_create(&cfg, errBuf, sizeof(errBuf)) != 0) {
        henge_free_ledger_exempt_ram(ramPtr, (size_t)alignedBytes);
        NSString *msg = errBuf[0] != '\0'
            ? [NSString stringWithUTF8String:errBuf]
            : @"hv_winvm_create failed";
        _statusText = msg;
        hengelinux_console_append_line([[NSString stringWithFormat:@"[bridge] ERROR: hv_winvm_create failed: %@", msg] UTF8String]);
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
    hengelinux_console_append_line("[bridge] Calling hv_winvm_start(1, henge_on_vm_exit)...");
    hv_winvm_start(1, henge_on_vm_exit);
    hengelinux_console_append_line("[bridge] hv_winvm_start returned; vCPUs running");
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
    hengelinux_console_append_line("[bridge] stopGuest requested");
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
    hengelinux_console_append_line("[bridge] Guest stopped and RAM released");
}

- (void)handleEngineExitReason:(int)reason {
    if (!_running && !_vmCreated) {
        return;
    }
#if HENGE_HAS_UPSTREAM_ENGINE
    const char *name = hv_winvm_reason_name(reason);
    NSString *exitMsg = [NSString stringWithFormat:@"Guest halted (%s)", name ? name : "exit"];
#else
    (void)reason;
    NSString *exitMsg = @"Guest halted";
#endif
    hengelinux_console_append_line([[NSString stringWithFormat:@"[bridge] Engine exit callback: %@ (code=%d)", exitMsg, reason] UTF8String]);
    [self stopGuest];
    _statusText = exitMsg;
}

#if HENGE_HAS_UPSTREAM_ENGINE
static void henge_forward_hid_to_pl011(HvPl011 *uart, uint8_t usage, uint8_t modifiers) {
    if (!uart) {
        return;
    }
    const bool shift = (modifiers & 0x22U) != 0;
    const bool ctrl = (modifiers & 0x11U) != 0;

    auto sendBytes = [uart](const char *seq, size_t len) {
        for (size_t i = 0; i < len; ++i) {
            hv_pl011_receive(uart, static_cast<uint8_t>(seq[i]));
        }
    };

    if (usage >= 0x04 && usage <= 0x1D) {
        char ch = static_cast<char>('a' + (usage - 0x04));
        if (ctrl) {
            uint8_t c = static_cast<uint8_t>((ch - 'a') + 1);
            hv_pl011_receive(uart, c);
        } else if (shift) {
            hv_pl011_receive(uart, static_cast<uint8_t>(ch - 'a' + 'A'));
        } else {
            hv_pl011_receive(uart, static_cast<uint8_t>(ch));
        }
        return;
    }
    if (usage >= 0x1E && usage <= 0x26) {
        static const char kShiftDigits[] = "!@#$%^&*(";
        char ch = shift ? kShiftDigits[usage - 0x1E] : static_cast<char>('1' + (usage - 0x1E));
        hv_pl011_receive(uart, static_cast<uint8_t>(ch));
        return;
    }
    switch (usage) {
    case 0x27: hv_pl011_receive(uart, shift ? ')' : '0'); break;
    case 0x28: hv_pl011_receive(uart, '\r'); break;
    case 0x29: hv_pl011_receive(uart, 0x1B); break;
    case 0x2A: hv_pl011_receive(uart, 0x7F); break;
    case 0x2B: hv_pl011_receive(uart, '\t'); break;
    case 0x2C: hv_pl011_receive(uart, ' '); break;
    case 0x2D: hv_pl011_receive(uart, shift ? '_' : '-'); break;
    case 0x2E: hv_pl011_receive(uart, shift ? '+' : '='); break;
    case 0x2F: hv_pl011_receive(uart, shift ? '{' : '['); break;
    case 0x30: hv_pl011_receive(uart, shift ? '}' : ']'); break;
    case 0x31: hv_pl011_receive(uart, shift ? '|' : '\\'); break;
    case 0x33: hv_pl011_receive(uart, shift ? ':' : ';'); break;
    case 0x34: hv_pl011_receive(uart, shift ? '"' : '\''); break;
    case 0x35: hv_pl011_receive(uart, shift ? '~' : '`'); break;
    case 0x36: hv_pl011_receive(uart, shift ? '<' : ','); break;
    case 0x37: hv_pl011_receive(uart, shift ? '>' : '.'); break;
    case 0x38: hv_pl011_receive(uart, shift ? '?' : '/'); break;
    case 0x3A: sendBytes("\x1BOP", 3); break;   /* F1 */
    case 0x3B: sendBytes("\x1BOQ", 3); break;   /* F2 */
    case 0x3C: sendBytes("\x1BOR", 3); break;   /* F3 */
    case 0x3D: sendBytes("\x1BOS", 3); break;   /* F4 */
    case 0x45: sendBytes("\x1B[24~", 5); break; /* F12 */
    case 0x4A: sendBytes("\x1B[H", 3); break;   /* Home */
    case 0x4B: sendBytes("\x1B[5~", 4); break;  /* PageUp */
    case 0x4C: sendBytes("\x1B[3~", 4); break;  /* Delete */
    case 0x4D: sendBytes("\x1B[F", 3); break;   /* End */
    case 0x4E: sendBytes("\x1B[6~", 4); break;  /* PageDown */
    case 0x4F: sendBytes("\x1B[C", 3); break;   /* Right */
    case 0x50: sendBytes("\x1B[D", 3); break;   /* Left */
    case 0x51: sendBytes("\x1B[B", 3); break;   /* Down */
    case 0x52: sendBytes("\x1B[A", 3); break;   /* Up */
    case 0x54: hv_pl011_receive(uart, '/'); break;  /* Keypad / */
    case 0x55: hv_pl011_receive(uart, '*'); break;  /* Keypad * */
    case 0x56: hv_pl011_receive(uart, '-'); break;  /* Keypad - */
    case 0x57: hv_pl011_receive(uart, '+'); break;  /* Keypad + */
    case 0x58: hv_pl011_receive(uart, '\r'); break; /* Keypad Enter */
    case 0x59: case 0x5A: case 0x5B: case 0x5C: case 0x5D:
    case 0x5E: case 0x5F: case 0x60: case 0x61:
        hv_pl011_receive(uart, static_cast<uint8_t>('1' + (usage - 0x59)));
        break;
    case 0x62: hv_pl011_receive(uart, '0'); break;  /* Keypad 0 */
    case 0x63: hv_pl011_receive(uart, '.'); break;  /* Keypad . */
    default: break;
    }
}
#endif

- (void)sendHidKeyUsage:(uint8_t)usage pressed:(BOOL)pressed {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (_running) {
        if (usage >= 0xE0 && usage <= 0xE7) {
            uint8_t bit = static_cast<uint8_t>(1U << (usage - 0xE0));
            if (pressed) {
                _hidModifiers |= bit;
            } else {
                _hidModifiers &= static_cast<uint8_t>(~bit);
            }
        }
        hv_winvm_key_hid(usage, pressed ? 1 : 0);
        if (pressed && !(usage >= 0xE0 && usage <= 0xE7)) {
            HvWinVirt *board = hv_winvm_board();
            if (board != nullptr && board->uart != nullptr) {
                henge_forward_hid_to_pl011(board->uart, usage, _hidModifiers);
            }
        }
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
        HvWinVirt *board = hv_winvm_board();
        if (board != nullptr && board->uart != nullptr) {
            NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
            const auto *bytes = static_cast<const uint8_t *>(utf8.bytes);
            for (NSUInteger i = 0; i < utf8.length; ++i) {
                uint8_t ch = bytes[i];
                if (ch == '\n') {
                    hv_pl011_receive(board->uart, '\r');
                } else {
                    hv_pl011_receive(board->uart, ch);
                }
            }
        }
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
