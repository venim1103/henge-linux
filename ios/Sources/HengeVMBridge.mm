/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "HengeVMBridge.h"

#include "henge_platform.h"
#include "henge_txm_jit.h"
#include "henge_virtio_gpu.h"
#include "henge_qcow2.h"

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
    uint32_t _lastDisplayWidth;
    uint32_t _lastDisplayHeight;
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
    std::string _disk1PathStr;
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
        _lastDisplayWidth = 1024U;
        _lastDisplayHeight = 768U;
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
    NSURL *archDir = [[docsURL URLByAppendingPathComponent:@"Machines" isDirectory:YES]
                      URLByAppendingPathComponent:@"ArchLinux" isDirectory:YES];
    return [self hasSavedBackgroundSnapshotAtMachineDir:archDir.path];
}

- (BOOL)hasSavedBackgroundSnapshotAtMachineDir:(NSString *)machineDirPath {
    if (machineDirPath.length == 0) {
        return NO;
    }
    NSURL *snapURL = [[NSURL fileURLWithPath:machineDirPath isDirectory:YES]
                      URLByAppendingPathComponent:@"suspend.state"];
    HengeVmSnapshotInfo info;
    return henge_vm_snapshot_read(snapURL.path.fileSystemRepresentation, &info, nullptr, 0U) == 0;
}

- (uint32_t)activeRamMiB {
    return _activeRamMiB;
}

- (int)activeCpuCount {
    return _activeCpuCount;
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

- (void)updateDisplaySizeWidth:(uint32_t)width height:(uint32_t)height {
    if (width < 320U) width = 320U;
    if (width > 4096U) width = 4096U;
    if (height < 240U) height = 240U;
    if (height > 4096U) height = 4096U;
    width &= ~1U;
    height &= ~1U;
    if (_lastDisplayWidth == width && _lastDisplayHeight == height) {
        return;
    }
    _lastDisplayWidth = width;
    _lastDisplayHeight = height;
    if (_gpuDevice != nullptr) {
        henge_virtio_gpu_set_display_mode(_gpuDevice, 0U, width, height, true);
    }
#if HENGE_HAS_UPSTREAM_ENGINE && defined(HENGE_WINVM_HAS_V4_RESIZE)
    if (_running && _vmCreated) {
        hv_winvm_set_virtio_gpu_size(width, height);
    }
#endif
}

- (void)prepareDiskImageWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSURL *docsURL = [self documentsDirectoryURL];
    NSURL *machineDir = [[docsURL URLByAppendingPathComponent:@"Machines" isDirectory:YES]
                         URLByAppendingPathComponent:@"ArchLinux" isDirectory:YES];
    [self prepareDiskImageAtMachineDir:machineDir.path
                       primaryDiskName:@"archlinux.hvsparse"
                              codePath:[machineDir URLByAppendingPathComponent:@"code.fd"].path
                              varsPath:[machineDir URLByAppendingPathComponent:@"vars.fd"].path
                            completion:completion];
}

- (void)prepareDiskImageAtMachineDir:(NSString *)machineDirPath
                     primaryDiskName:(NSString *)primaryDiskName
                            codePath:(NSString *)codePath
                            varsPath:(NSString *)varsPath
                          completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    [self prepareDiskImageAtMachineDir:machineDirPath
                       primaryDiskName:primaryDiskName
                              codePath:codePath
                              varsPath:varsPath
                          minDiskBytes:0ULL
                            completion:completion];
}

- (void)prepareDiskImageAtMachineDir:(NSString *)machineDirPath
                     primaryDiskName:(NSString *)primaryDiskName
                            codePath:(NSString *)codePath
                            varsPath:(NSString *)varsPath
                        minDiskBytes:(uint64_t)minDiskBytes
                          completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSURL *machineDir = [NSURL fileURLWithPath:machineDirPath isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:machineDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *diskName = (primaryDiskName.length > 0) ? primaryDiskName : @"disk0.img";
    NSURL *primaryURL = [machineDir URLByAppendingPathComponent:diskName];
    BOOL primaryExists = [fm fileExistsAtPath:primaryURL.path];
    HengeImageFormat detectedFmt = primaryExists
        ? henge_detect_image_format(primaryURL.path.fileSystemRepresentation)
        : HENGE_IMG_FORMAT_UNKNOWN;
    BOOL isSparseArchive = (detectedFmt == HENGE_IMG_FORMAT_HVSPARSE) ||
                           [diskName.lowercaseString hasSuffix:@".hvsparse"];
    BOOL isQcow2Image = (detectedFmt == HENGE_IMG_FORMAT_QCOW2) ||
                        [diskName.lowercaseString hasSuffix:@".qcow2"];

    NSString *rawName = diskName;
    if (isSparseArchive) {
        rawName = [[diskName stringByDeletingPathExtension] stringByAppendingPathExtension:@"img"];
    } else if (isQcow2Image) {
        rawName = [[diskName stringByDeletingPathExtension] stringByAppendingString:@".raw.img"];
    }
    NSURL *rawDiskURL = [machineDir URLByAppendingPathComponent:rawName];

    BOOL hasArchive = (isSparseArchive || isQcow2Image) && primaryExists;
    BOOL hasRaw = [fm fileExistsAtPath:rawDiskURL.path];
    if (!hasArchive && !hasRaw && [fm fileExistsAtPath:[machineDir URLByAppendingPathComponent:@"archlinux.img"].path]) {
        rawDiskURL = [machineDir URLByAppendingPathComponent:@"archlinux.img"];
        hasRaw = YES;
    }

    if (![fm fileExistsAtPath:codePath] ||
        ![fm fileExistsAtPath:varsPath] ||
        (!hasArchive && !hasRaw)) {
        NSString *msg = [NSString stringWithFormat:@"Missing guest files for this VM (need code.fd, vars.fd, and %@).", diskName];
        _statusText = msg;
        NSError *err = [NSError errorWithDomain:HengeVMErrorDomain
                                           code:1001
                                       userInfo:@{NSLocalizedDescriptionKey: msg}];
        completion(NO, err);
        return;
    }

    if (hasArchive) {
        NSDictionary *srcAttrs = [fm attributesOfItemAtPath:primaryURL.path error:nil];
        unsigned long long srcSize = [srcAttrs[NSFileSize] unsignedLongLongValue];
        BOOL needsUnpack = !hasRaw;
        if (hasRaw) {
            NSDictionary *rawAttrs = [fm attributesOfItemAtPath:rawDiskURL.path error:nil];
            NSDate *srcMod = srcAttrs[NSFileModificationDate];
            NSDate *rawMod = rawAttrs[NSFileModificationDate];
            unsigned long long rawSize = [rawAttrs[NSFileSize] unsignedLongLongValue];
            if (rawSize == 0ULL || (srcMod != nil && rawMod != nil && [srcMod compare:rawMod] == NSOrderedDescending)) {
                needsUnpack = YES;
            }
        }
        if (needsUnpack) {
            _statusText = [NSString stringWithFormat:@"Unpacking %@ disk image...", diskName];
            NSString *unpackMsg = [NSString stringWithFormat:
                @"[bridge] Unpacking %@ (%s, %llu bytes) -> %@...",
                diskName, isQcow2Image ? "QCOW2" : "HVSPARSE", srcSize, rawDiskURL.lastPathComponent];
            hengelinux_console_append_line(unpackMsg.UTF8String);
            std::string srcStr = primaryURL.path.fileSystemRepresentation;
            std::string rawStr = rawDiskURL.path.fileSystemRepresentation;
            BOOL unpackQcow2 = isQcow2Image;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                std::remove(rawStr.c_str());
                char errBuf[256] = {0};
                int rc = -1;
                if (unpackQcow2) {
                    /* Ensure at least 8 GiB (or user target) virtual size for cloud images. */
                    uint64_t minVirt = (minDiskBytes > (8ULL << 30)) ? minDiskBytes : (8ULL << 30);
                    rc = henge_qcow2_unpack_to_raw(srcStr.c_str(), rawStr.c_str(), minVirt, errBuf, sizeof(errBuf));
                } else {
#if HENGE_HAS_UPSTREAM_ENGINE
                    rc = hv_sparse_unpack(srcStr.c_str(), rawStr.c_str(), nullptr, nullptr);
                    if (rc != 0) {
                        std::snprintf(errBuf, sizeof(errBuf), "hv_sparse_unpack failed");
                    } else if (minDiskBytes > 0ULL) {
                        uint64_t finalSz = 0ULL;
                        rc = henge_expand_sparse_raw_disk(rawStr.c_str(), minDiskBytes, &finalSz, errBuf, sizeof(errBuf));
                    }
#else
                    std::snprintf(errBuf, sizeof(errBuf), "Upstream HVSPARSE unpacker not linked");
#endif
                }
                if (rc != 0) {
                    std::remove(rawStr.c_str());
                }
                NSString *detail = (errBuf[0] != '\0') ? [NSString stringWithUTF8String:errBuf] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (rc != 0) {
                        NSString *msg = detail
                            ? [NSString stringWithFormat:@"Failed to unpack %@: %@", diskName, detail]
                            : [NSString stringWithFormat:@"Failed to unpack %@ into sparse raw NVMe disk image.", diskName];
                        self->_statusText = msg;
                        hengelinux_console_append_line([[NSString stringWithFormat:@"[bridge] ERROR: %@", msg] UTF8String]);
                        NSError *err = [NSError errorWithDomain:HengeVMErrorDomain
                                                           code:1007
                                                       userInfo:@{NSLocalizedDescriptionKey: msg}];
                        completion(NO, err);
                    } else {
                        hengelinux_console_append_line("[bridge] Unpacked disk image successfully");
                        completion(YES, nil);
                    }
                });
            });
            return;
        }
    }
    if (minDiskBytes > 0ULL && [fm fileExistsAtPath:rawDiskURL.path]) {
        char expandErr[256] = {0};
        uint64_t finalSz = 0ULL;
        if (henge_expand_sparse_raw_disk(rawDiskURL.path.fileSystemRepresentation,
                                         minDiskBytes,
                                         &finalSz,
                                         expandErr,
                                         sizeof(expandErr)) != 0) {
            NSString *msg = [NSString stringWithFormat:@"Failed to expand %@: %s", rawDiskURL.lastPathComponent, expandErr];
            _statusText = msg;
            NSError *err = [NSError errorWithDomain:HengeVMErrorDomain
                                               code:1008
                                           userInfo:@{NSLocalizedDescriptionKey: msg}];
            completion(NO, err);
            return;
        }
    }
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
    NSURL *docsURL = [self documentsDirectoryURL];
    NSURL *machineDir = [[docsURL URLByAppendingPathComponent:@"Machines" isDirectory:YES]
                         URLByAppendingPathComponent:@"ArchLinux" isDirectory:YES];
    return [self startGuestAtMachineDir:machineDir.path
                        primaryDiskName:@"archlinux.hvsparse"
                      secondaryDiskPath:nil
                               codePath:[machineDir URLByAppendingPathComponent:@"code.fd"].path
                               varsPath:[machineDir URLByAppendingPathComponent:@"vars.fd"].path
                                 ramMiB:ramMiB
                               cpuCount:cpuCount
                             gpuBackend:gpuBackend
                      enableVirtioInput:YES
                             enableXhci:NO
                         enableAcpiSpcr:YES
                                  error:error];
}

- (BOOL)startGuestAtMachineDir:(NSString *)machineDirPath
               primaryDiskName:(NSString *)primaryDiskName
             secondaryDiskPath:(nullable NSString *)secondaryDiskPath
                      codePath:(NSString *)codePath
                      varsPath:(NSString *)varsPath
                        ramMiB:(uint32_t)ramMiB
                      cpuCount:(int)cpuCount
                    gpuBackend:(int)gpuBackend
             enableVirtioInput:(BOOL)enableVirtioInput
                    enableXhci:(BOOL)enableXhci
                enableAcpiSpcr:(BOOL)enableAcpiSpcr
                         error:(NSError * _Nullable * _Nullable)error {
    if (_running) {
        return YES;
    }
    if (_vmCreated || _guestRam != nullptr) {
        [self stopGuest];
    }

    hengelinux_reset_suspend_counter();
    hengelinux_reset_guest_hid_bridge_ready();

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
    NSURL *machineDir = [NSURL fileURLWithPath:machineDirPath isDirectory:YES];
    NSURL *sharedDir = [docsURL URLByAppendingPathComponent:@"Shared" isDirectory:YES];

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:machineDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:sharedDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSURL *codeURL = [NSURL fileURLWithPath:codePath];
    NSURL *varsURL = [NSURL fileURLWithPath:varsPath];
    NSString *diskName = (primaryDiskName.length > 0) ? primaryDiskName : @"disk0.img";
    NSURL *primaryURL = [machineDir URLByAppendingPathComponent:diskName];
    BOOL primaryExists = [fm fileExistsAtPath:primaryURL.path];
    HengeImageFormat detectedFmt = primaryExists
        ? henge_detect_image_format(primaryURL.path.fileSystemRepresentation)
        : HENGE_IMG_FORMAT_UNKNOWN;
    BOOL isSparseArchive = (detectedFmt == HENGE_IMG_FORMAT_HVSPARSE) ||
                           [diskName.lowercaseString hasSuffix:@".hvsparse"];
    BOOL isQcow2Image = (detectedFmt == HENGE_IMG_FORMAT_QCOW2) ||
                        [diskName.lowercaseString hasSuffix:@".qcow2"];

    NSString *rawName = diskName;
    if (isSparseArchive) {
        rawName = [[diskName stringByDeletingPathExtension] stringByAppendingPathExtension:@"img"];
    } else if (isQcow2Image) {
        rawName = [[diskName stringByDeletingPathExtension] stringByAppendingString:@".raw.img"];
    }
    NSURL *rawDiskURL = [machineDir URLByAppendingPathComponent:rawName];
    NSURL *snapURL = [machineDir URLByAppendingPathComponent:@"suspend.state"];
    _snapshotPathStr = snapURL.path.fileSystemRepresentation;

    HengeVmSnapshotInfo prevSnapshot;
    std::memset(&prevSnapshot, 0, sizeof(prevSnapshot));
    BOOL hadPriorSnapshot = (henge_vm_snapshot_read(_snapshotPathStr.c_str(), &prevSnapshot, nullptr, 0U) == 0);
    (void)hadPriorSnapshot;

    BOOL hasArchive = (isSparseArchive || isQcow2Image) && primaryExists;
    BOOL hasRaw = [fm fileExistsAtPath:rawDiskURL.path];
    if (!hasArchive && !hasRaw && [fm fileExistsAtPath:[machineDir URLByAppendingPathComponent:@"archlinux.img"].path]) {
        rawDiskURL = [machineDir URLByAppendingPathComponent:@"archlinux.img"];
        hasRaw = YES;
    }

    if (![fm fileExistsAtPath:codeURL.path] ||
        ![fm fileExistsAtPath:varsURL.path] ||
        (!hasArchive && !hasRaw)) {
        NSString *msg = [NSString stringWithFormat:@"Missing guest files for this VM (need code.fd, vars.fd, and %@).", diskName];
        _statusText = msg;
        if (error) {
            *error = [NSError errorWithDomain:HengeVMErrorDomain
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

#if HENGE_HAS_UPSTREAM_ENGINE
    /* Unpack HVSPARSE or QCOW2 archive into an APFS sparse raw image on first
     * boot or whenever the archive is newer than the unpacked raw disk. */
    if (hasArchive) {
        BOOL needsUnpack = !hasRaw;
        if (hasRaw) {
            NSDictionary *srcAttrs = [fm attributesOfItemAtPath:primaryURL.path error:nil];
            NSDictionary *rawAttrs = [fm attributesOfItemAtPath:rawDiskURL.path error:nil];
            NSDate *srcMod = srcAttrs[NSFileModificationDate];
            NSDate *rawMod = rawAttrs[NSFileModificationDate];
            unsigned long long rawSize = [rawAttrs[NSFileSize] unsignedLongLongValue];
            if (rawSize == 0ULL || (srcMod != nil && rawMod != nil && [srcMod compare:rawMod] == NSOrderedDescending)) {
                needsUnpack = YES;
            }
        }
        if (needsUnpack) {
            [fm removeItemAtURL:rawDiskURL error:nil];
            char unpackErr[256] = {0};
            int unpackRc = isQcow2Image
                ? henge_qcow2_unpack_to_raw(primaryURL.path.fileSystemRepresentation,
                                            rawDiskURL.path.fileSystemRepresentation,
                                            8ULL << 30,
                                            unpackErr,
                                            sizeof(unpackErr))
                : hv_sparse_unpack(primaryURL.path.fileSystemRepresentation,
                                   rawDiskURL.path.fileSystemRepresentation,
                                   nullptr,
                                   nullptr);
            if (unpackRc != 0) {
                [fm removeItemAtURL:rawDiskURL error:nil];
                NSString *msg = (unpackErr[0] != '\0')
                    ? [NSString stringWithFormat:@"Failed to unpack %@: %s", diskName, unpackErr]
                    : [NSString stringWithFormat:@"Failed to unpack %@ into sparse raw NVMe disk image.", diskName];
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

    /* Acquire dual-mapped RX/RW JIT pool BEFORE mapping multi-GB guest RAM
     * so virtual address space around RX remains uncrowded for vm_remap. */
    HengeJitPool jitPool;
    std::memset(&jitPool, 0, sizeof(jitPool));
    const size_t targetJitBytes = henge_recommended_jit_pool_bytes();
    if (!henge_jit_acquire_pool(targetJitBytes, true, &jitPool)) {
        char jitErr[256] = {0};
        henge_jit_copy_status(jitErr, sizeof(jitErr));
        NSString *msg = (jitErr[0] != '\0')
            ? [NSString stringWithFormat:@"JIT pool not active (%s). Enable JIT via StikDebug or LLDB, then tap Boot.", jitErr]
            : @"JIT pool not active. Enable JIT via StikDebug or LLDB, then tap Boot.";
        _statusText = msg;
        if (error) {
            *error = [NSError errorWithDomain:HengeVMErrorDomain
                                         code:1006
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    uint64_t alignedBytes = henge_align_guest_ram_bytes(ramMiB, HENGE_MAX_GUEST_RAM_MIB);
    bool ledgerExempt = false;
    void *ramPtr = henge_alloc_ledger_exempt_ram((size_t)alignedBytes, &ledgerExempt);
    if (!ramPtr) {
        NSString *msg = [NSString stringWithFormat:@"Failed to allocate %llu MiB of 16 KiB-aligned guest RAM.",
                         alignedBytes / (1024ULL * 1024ULL)];
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
    _disk1PathStr.clear();
    if (secondaryDiskPath != nil && secondaryDiskPath.length > 0 && [fm fileExistsAtPath:secondaryDiskPath]) {
        _disk1PathStr = [NSURL fileURLWithPath:secondaryDiskPath].path.fileSystemRepresentation;
    }
    _shareDirStr = sharedDir.path.fileSystemRepresentation;
    _shareSockStr = shareSockPath;
#if defined(HENGE_SHARE_HAS_GUEST_TOOLS)
    NSString *resourcePath = NSBundle.mainBundle.resourcePath;
    if (resourcePath != nil && resourcePath.length > 0) {
        hv_share_set_guest_tools_dir(resourcePath.fileSystemRepresentation);
    }
#endif

    HvWinVmConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.code_fd = _codePathStr.c_str();
    cfg.vars_fd = _varsPathStr.c_str();
    cfg.disk0 = _diskPathStr.c_str();
    cfg.disk1 = _disk1PathStr.empty() ? nullptr : _disk1PathStr.c_str();
    cfg.share_dir = _shareDirStr.c_str();
    cfg.share_sock = _shareSockStr.c_str();
    cfg.ncpus = (cpuCount > 0) ? cpuCount : 4;
    cfg.ram_mb = alignedBytes / (1024ULL * 1024ULL);
    cfg.jit_rx = (void *)jitPool.rx_base;
    cfg.jit_rw = (void *)jitPool.rw_base;
    cfg.jit_bytes = jitPool.size;
    cfg.prealloc_ram = ramPtr;
    cfg.enable_sound = 1;
#if defined(HENGE_WINVM_HAS_V2_FLAGS)
    cfg.disable_xhci = enableXhci ? 0 : 1;
    cfg.enable_virtio_input = enableVirtioInput ? 1 : 0;
    cfg.disable_acpi_spcr = enableAcpiSpcr ? 0 : 1;
    cfg.disk1_virtio_blk = _disk1PathStr.empty() ? 0 : 1;
#else
    (void)enableVirtioInput;
    (void)enableXhci;
    (void)enableAcpiSpcr;
#endif
#if defined(HENGE_WINVM_HAS_V3_GPU)
    cfg.enable_virtio_gpu = (gpuBackend == 1 || gpuBackend == 2) ? 1 : 0;
#endif
#if defined(HENGE_WINVM_HAS_V4_RESIZE)
    cfg.disk1_blk_size = _disk1PathStr.empty() ? 512U : henge_iso_preferred_block_size(_disk1PathStr.c_str());
#endif

    char errBuf[512];
    std::memset(errBuf, 0, sizeof(errBuf));
    NSString *createDiag = [NSString stringWithFormat:
        @"[bridge] Calling hv_winvm_create(ram=%llu MiB, cpus=%d, gpu=%d, jit_rx=0x%llx, jit_bytes=%zu, cs_debugged=%d, ptraced=%d)",
        cfg.ram_mb,
        cfg.ncpus,
        gpuBackend,
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
    if (gpuBackend == 2) {
        gpuLabel = @"VirtIO-GPU 2D KMS";
    } else if (_gpuConfig.mode == HENGE_GPU_BACKEND_VIRGL_3D) {
        gpuLabel = henge_virtio_gpu_has_virglrenderer()
            ? @"VirGL 3D"
            : @"VirtIO-GPU 2D KMS (VirGL 3D staged)";
    }
    _statusText = [NSString stringWithFormat:@"Running · %llu MiB · %@ (%@)",
                   cfg.ram_mb,
                   gpuLabel,
                   ledgerExempt ? @"LEDGER_NO_FOOTPRINT" : @"standard ledger"];

    CAMetalLayer *layer = _displayLayer;
    if (layer != nil) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }
#if defined(HENGE_WINVM_HAS_V4_RESIZE)
    if (_lastDisplayWidth >= 320U && _lastDisplayHeight >= 240U) {
        hv_winvm_set_virtio_gpu_size(_lastDisplayWidth, _lastDisplayHeight);
    }
#endif
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
    _lastDisplayWidth = 1024U;
    _lastDisplayHeight = 768U;
    hengelinux_reset_guest_hid_bridge_ready();
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
static size_t henge_hid_to_pl011_bytes(uint8_t usage, uint8_t modifiers, uint8_t out[16]) {
    const bool shift = (modifiers & 0x22U) != 0;
    const bool ctrl = (modifiers & 0x11U) != 0;

    auto emit = [out](const char *seq, size_t len) -> size_t {
        std::memcpy(out, seq, len);
        return len;
    };

    if (usage >= 0x04 && usage <= 0x1D) {
        char ch = static_cast<char>('a' + (usage - 0x04));
        if (ctrl) {
            out[0] = static_cast<uint8_t>((ch - 'a') + 1);
        } else if (shift) {
            out[0] = static_cast<uint8_t>(ch - 'a' + 'A');
        } else {
            out[0] = static_cast<uint8_t>(ch);
        }
        return 1;
    }
    if (usage >= 0x1E && usage <= 0x26) {
        static const char kShiftDigits[] = "!@#$%^&*(";
        out[0] = static_cast<uint8_t>(shift ? kShiftDigits[usage - 0x1E] : static_cast<char>('1' + (usage - 0x1E)));
        return 1;
    }
    switch (usage) {
    case 0x27: out[0] = shift ? ')' : '0'; return 1;
    case 0x28: out[0] = '\r'; return 1;
    case 0x29: out[0] = 0x1B; return 1;
    case 0x2A: out[0] = 0x7F; return 1;
    case 0x2B: out[0] = '\t'; return 1;
    case 0x2C: out[0] = ' '; return 1;
    case 0x2D: out[0] = shift ? '_' : '-'; return 1;
    case 0x2E: out[0] = shift ? '+' : '='; return 1;
    case 0x2F: out[0] = shift ? '{' : '['; return 1;
    case 0x30: out[0] = shift ? '}' : ']'; return 1;
    case 0x31: out[0] = shift ? '|' : '\\'; return 1;
    case 0x33: out[0] = shift ? ':' : ';'; return 1;
    case 0x34: out[0] = shift ? '"' : '\''; return 1;
    case 0x35: out[0] = shift ? '~' : '`'; return 1;
    case 0x36: out[0] = shift ? '<' : ','; return 1;
    case 0x37: out[0] = shift ? '>' : '.'; return 1;
    case 0x38: out[0] = shift ? '?' : '/'; return 1;
    case 0x3A: return emit("\x1BOP", 3);   /* F1 */
    case 0x3B: return emit("\x1BOQ", 3);   /* F2 */
    case 0x3C: return emit("\x1BOR", 3);   /* F3 */
    case 0x3D: return emit("\x1BOS", 3);   /* F4 */
    case 0x3E: return emit("\x1B[15~", 5); /* F5 */
    case 0x3F: return emit("\x1B[17~", 5); /* F6 */
    case 0x40: return emit("\x1B[18~", 5); /* F7 */
    case 0x41: return emit("\x1B[19~", 5); /* F8 */
    case 0x42: return emit("\x1B[20~", 5); /* F9 */
    case 0x43: return emit("\x1B[21~", 5); /* F10 */
    case 0x44: return emit("\x1B[23~", 5); /* F11 */
    case 0x45: return emit("\x1B[24~", 5); /* F12 */
    case 0x49: return emit("\x1B[2~", 4);  /* Insert */
    case 0x4A: return emit("\x1B[H", 3);   /* Home */
    case 0x4B: return emit("\x1B[5~", 4);  /* PageUp */
    case 0x4C: return emit("\x1B[3~", 4);  /* Delete */
    case 0x4D: return emit("\x1B[F", 3);   /* End */
    case 0x4E: return emit("\x1B[6~", 4);  /* PageDown */
    case 0x4F: return emit("\x1B[C", 3);   /* Right */
    case 0x50: return emit("\x1B[D", 3);   /* Left */
    case 0x51: return emit("\x1B[B", 3);   /* Down */
    case 0x52: return emit("\x1B[A", 3);   /* Up */
    case 0x54: out[0] = '/'; return 1;  /* Keypad / */
    case 0x55: out[0] = '*'; return 1;  /* Keypad * */
    case 0x56: out[0] = '-'; return 1;  /* Keypad - */
    case 0x57: out[0] = '+'; return 1;  /* Keypad + */
    case 0x58: out[0] = '\r'; return 1; /* Keypad Enter */
    case 0x59: case 0x5A: case 0x5B: case 0x5C: case 0x5D:
    case 0x5E: case 0x5F: case 0x60: case 0x61:
        out[0] = static_cast<uint8_t>('1' + (usage - 0x59));
        return 1;
    case 0x62: out[0] = '0'; return 1;  /* Keypad 0 */
    case 0x63: out[0] = '.'; return 1;  /* Keypad . */
    default: return 0;
    }
}

static void henge_forward_hid_to_pl011(HvPl011 *uart, uint8_t usage, uint8_t modifiers) {
    if (!uart) {
        return;
    }
    uint8_t seq[16];
    size_t len = henge_hid_to_pl011_bytes(usage, modifiers, seq);
    for (size_t i = 0; i < len; ++i) {
        hv_pl011_receive(uart, seq[i]);
    }
}

static void henge_forward_hid_to_pl011_osc_tty1(HvPl011 *uart, uint8_t usage, uint8_t modifiers) {
    if (!uart) {
        return;
    }
    uint8_t seq[16];
    size_t len = henge_hid_to_pl011_bytes(usage, modifiers, seq);
    if (len == 0) {
        return;
    }
    static const char kHex[] = "0123456789abcdef";
    char frame[64];
    size_t pos = 0;
    std::memcpy(frame, "\x1b]9999;T ", 9);
    pos = 9;
    for (size_t i = 0; i < len && pos + 3 < sizeof(frame); ++i) {
        frame[pos++] = kHex[(seq[i] >> 4) & 0xFU];
        frame[pos++] = kHex[seq[i] & 0xFU];
    }
    frame[pos++] = '\x07';
    for (size_t i = 0; i < pos; ++i) {
        hv_pl011_receive(uart, static_cast<uint8_t>(frame[i]));
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
        HvWinVirt *board = hv_winvm_board();
        const bool guestHidBridgeReady = hengelinux_is_guest_hid_bridge_ready();
        const bool isCtrlAltFKey = ((_hidModifiers & 0x11U) != 0U) &&
                                   ((_hidModifiers & 0x44U) != 0U) &&
                                   (usage >= 0x3AU && usage <= 0x45U);
        if (guestHidBridgeReady && board != nullptr && board->uart != nullptr) {
            /*
             * Guest is running henge_dual_console / henge-guest-agent on ttyAMA0
             * (which mirrors tty1 and injects OSC 9999 into /dev/uinput on vt2+).
             * Route exclusively over PL011 so virtio-input does not double-deliver
             * keystrokes onto tty1 (echo) or tty2/X11 (input).
             * Exception: Ctrl+Alt+F1..F12 VT-switch chords also pulse virtio-input
             * so switching from tty1 -> vt2 works even when henge_dual_console
             * suppresses uinput on tty1.
             */
            if (isCtrlAltFKey) {
                if (pressed) {
                    hv_winvm_key_hid(0xE0, 1);
                    hv_winvm_key_hid(0xE2, 1);
                    hv_winvm_key_hid(usage, 1);
                } else {
                    hv_winvm_key_hid(usage, 0);
                    hv_winvm_key_hid(0xE2, 0);
                    hv_winvm_key_hid(0xE0, 0);
                }
            }
            char osc[48];
            int n = std::snprintf(osc, sizeof(osc), "\x1b]9999;K %02x %d\x07", usage, pressed ? 1 : 0);
            if (n > 0) {
                for (int i = 0; i < n; ++i) {
                    hv_pl011_receive(board->uart, static_cast<uint8_t>(osc[i]));
                }
            }
            if (pressed && !isCtrlAltFKey && !(usage >= 0xE0 && usage <= 0xE7)) {
                if (hengelinux_is_guest_hid_bridge_v2()) {
                    henge_forward_hid_to_pl011_osc_tty1(board->uart, usage, _hidModifiers);
                } else {
                    henge_forward_hid_to_pl011(board->uart, usage, _hidModifiers);
                }
            }
            return;
        }

        hv_winvm_key_hid(usage, pressed ? 1 : 0);
        if (board != nullptr && board->uart != nullptr && pressed && !(usage >= 0xE0 && usage <= 0xE7)) {
            bool virtioKbdDriverReady = false;
#if defined(HENGE_WINVM_HAS_V2_FLAGS)
            if (board->vinput_kbd != nullptr && (board->vinput_kbd->vio.status & 4u) != 0u) {
                virtioKbdDriverReady = true;
            }
#endif
            /* Forward to PL011 only during UEFI/GRUB or when virtio-input is inactive. */
            if (!virtioKbdDriverReady) {
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
        if (hengelinux_is_guest_hid_bridge_ready()) {
            [self sendHidKeyUsage:0xE0 pressed:YES];
            [self sendHidKeyUsage:0xE2 pressed:YES];
            [self sendHidKeyUsage:0x4C pressed:YES];
            [self sendHidKeyUsage:0x4C pressed:NO];
            [self sendHidKeyUsage:0xE2 pressed:NO];
            [self sendHidKeyUsage:0xE0 pressed:NO];
        } else {
            hv_winvm_send_ctrl_alt_del();
        }
    }
#endif
}

- (void)sendPointerNormX:(double)xNorm
                   normY:(double)yNorm
                 buttons:(uint8_t)buttons
                   wheel:(int8_t)wheel {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (_running) {
        HvWinVirt *board = hv_winvm_board();
        bool virtioTabReady = false;
#if defined(HENGE_WINVM_HAS_V2_FLAGS)
        if (board != nullptr && board->vinput_tab != nullptr && (board->vinput_tab->vio.status & 4u) != 0u) {
            virtioTabReady = true;
        }
#endif
        /* Prefer VirtIO-Input tablet directly whenever the guest driver is active
         * so high-rate trackpad motion never floods the PL011 serial FIFO. */
        if (!virtioTabReady && board != nullptr && board->uart != nullptr && hengelinux_is_guest_hid_bridge_ready()) {
            double cx = (xNorm < 0.0) ? 0.0 : ((xNorm > 1.0) ? 1.0 : xNorm);
            double cy = (yNorm < 0.0) ? 0.0 : ((yNorm > 1.0) ? 1.0 : yNorm);
            int absX = static_cast<int>(cx * 32767.0 + 0.5);
            int absY = static_cast<int>(cy * 32767.0 + 0.5);
            char osc[64];
            int n = std::snprintf(osc, sizeof(osc), "\x1b]9999;P %d %d %u %d\x07",
                                  absX, absY, (unsigned)buttons, (int)wheel);
            if (n > 0) {
                for (int i = 0; i < n; ++i) {
                    hv_pl011_receive(board->uart, static_cast<uint8_t>(osc[i]));
                }
            }
            return;
        }
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

- (void)sendSerialText:(NSString *)text {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (!_running || text.length == 0) {
        return;
    }
    HvWinVirt *board = hv_winvm_board();
    if (board == nullptr || board->uart == nullptr) {
        return;
    }
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    const auto *bytes = static_cast<const uint8_t *>(utf8.bytes);
    for (NSUInteger i = 0; i < utf8.length; ++i) {
        uint8_t ch = bytes[i];
        hv_pl011_receive(board->uart, (ch == '\n') ? '\r' : ch);
    }
#else
    (void)text;
#endif
}

- (void)sendSerialControlByte:(uint8_t)byte {
#if HENGE_HAS_UPSTREAM_ENGINE
    if (!_running) {
        return;
    }
    HvWinVirt *board = hv_winvm_board();
    if (board != nullptr && board->uart != nullptr) {
        hv_pl011_receive(board->uart, byte);
    }
#else
    (void)byte;
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
