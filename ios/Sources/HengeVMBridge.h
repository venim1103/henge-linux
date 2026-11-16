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
@property (nonatomic, readonly, copy) NSString *statusText;
@property (nonatomic, readonly) uint64_t framesPresented;

/// Attach or detach the `MetalDisplaySurfaceView` `CAMetalLayer` for UEFI GOP / framebuffer output.
- (void)attachDisplayLayer:(nullable CAMetalLayer *)layer NS_SWIFT_NAME(attachDisplayLayer(_:));
- (void)detachDisplayLayerIfMatching:(nullable CAMetalLayer *)layer NS_SWIFT_NAME(detachDisplayLayer(ifMatching:));

/// Unpack `archlinux.hvsparse` into `archlinux.img` off the main thread when needed
/// before calling `startGuestWithRamMiB:`.
- (void)prepareDiskImageWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// Start the Arch Linux AArch64 VM with `ramMiB` and `cpuCount` using guest
/// artifacts in `Documents/Machines/ArchLinux/{archlinux.hvsparse,code.fd,vars.fd}`.
- (BOOL)startGuestWithRamMiB:(uint32_t)ramMiB
                    cpuCount:(int)cpuCount
                  gpuBackend:(int)gpuBackend
                       error:(NSError * _Nullable * _Nullable)error;

/// Stop the VM and release ledger-exempt guest RAM.
- (void)stopGuest;

/// Persist a checksummed background VM snapshot (`Documents/Machines/ArchLinux/suspend.state`).
- (BOOL)saveBackgroundSnapshot;

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
