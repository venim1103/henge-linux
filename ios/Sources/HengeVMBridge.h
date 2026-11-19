/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_VM_BRIDGE_H
#define HENGE_VM_BRIDGE_H

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C/C++ runtime bridge connecting SwiftUI (`HengeLinuxApp`,
/// `SessionView`) to the `HengeVM` / `WindowsiOS` engine, `hvsparse` block
/// device, Metal presenter, xHCI HID input, and `10.0.2.4/.henge/` gateway.
NS_SWIFT_UI_ACTOR
@interface HengeVMBridge : NSObject

@property (class, nonatomic, readonly) HengeVMBridge *shared;

@property (nonatomic, readonly) BOOL isEngineLinked;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) BOOL isVirgl3DActive;
@property (nonatomic, readonly) BOOL hasSavedBackgroundSnapshot;
@property (nonatomic, readonly) uint32_t activeRamMiB;
@property (nonatomic, readonly) int activeCpuCount;
@property (nonatomic, readonly, copy) NSString *statusText;
@property (nonatomic, readonly) uint64_t framesPresented;
@property (nonatomic, readonly) uint64_t consoleTotalBytes;
@property (nonatomic, readonly, copy) NSString *bootLogFilePath;

/// Read or clear captured PL011 serial (`ttyAMA0`) + HengeVM engine diagnostic logs.
- (NSString *)copyConsoleLog;
- (void)clearConsoleLog;
- (NSString *)diagnosticSnapshot;

/// Attach or detach the `MetalDisplaySurfaceView` `CAMetalLayer` for UEFI GOP / framebuffer output.
- (void)attachDisplayLayer:(nullable CAMetalLayer *)layer NS_SWIFT_NAME(attachDisplayLayer(_:));
- (void)detachDisplayLayerIfMatching:(nullable CAMetalLayer *)layer NS_SWIFT_NAME(detachDisplayLayer(ifMatching:));
/// Notify the 2D VirtIO-GPU KMS backend of viewport / orientation pixel-size changes.
- (void)updateDisplaySizeWidth:(uint32_t)width height:(uint32_t)height NS_SWIFT_NAME(updateDisplaySize(width:height:));

/// Unpack primary `.hvsparse` disk image into a raw APFS sparse image off the main thread.
- (void)prepareDiskImageWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)prepareDiskImageAtMachineDir:(NSString *)machineDirPath
                     primaryDiskName:(NSString *)primaryDiskName
                            codePath:(NSString *)codePath
                            varsPath:(NSString *)varsPath
                          completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// Start a VM using explicit per-VM paths and PCIe/ACPI device toggles.
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
                         error:(NSError * _Nullable * _Nullable)error;

/// Legacy wrapper for `Documents/Machines/ArchLinux/`.
- (BOOL)startGuestWithRamMiB:(uint32_t)ramMiB
                    cpuCount:(int)cpuCount
                  gpuBackend:(int)gpuBackend
                       error:(NSError * _Nullable * _Nullable)error;

/// Stop the VM and release ledger-exempt guest RAM.
- (void)stopGuest;

/// Persist or query a checksummed background VM snapshot (`suspend.state`).
- (BOOL)saveBackgroundSnapshot;
- (BOOL)hasSavedBackgroundSnapshotAtMachineDir:(NSString *)machineDirPath;

/// Send raw text or control bytes directly to the guest PL011 UART (`ttyAMA0`).
- (void)sendSerialText:(NSString *)text;
- (void)sendSerialControlByte:(uint8_t)byte;

/// Forward USB HID keyboard usage codes (`0x29` Esc, `0x2B` Tab, `0xE0` Ctrl, etc.).
- (void)sendHidKeyUsage:(uint8_t)usage pressed:(BOOL)pressed;
- (void)tapHidKeyUsage:(uint8_t)usage;
- (void)sendCtrlAltDel;

/// Forward normalized tablet/touch pointer coordinates in `[0.0, 1.0]`.
- (void)sendPointerNormX:(double)xNorm
                   normY:(double)yNorm
                 buttons:(uint8_t)buttons
                   wheel:(int8_t)wheel;

/// Poll `http://10.0.2.4/.henge/open-url` and `/.henge/oauth-done` bridge events.
- (nullable NSString *)takePendingOpenURL;
- (BOOL)takePendingOAuthDone;

/// Sync host pasteboard with `http://10.0.2.4/.henge/clipboard`.
- (void)pushHostClipboard:(NSString *)text;
- (nullable NSString *)takeGuestClipboard;

@end

NS_ASSUME_NONNULL_END

#endif /* HENGE_VM_BRIDGE_H */
