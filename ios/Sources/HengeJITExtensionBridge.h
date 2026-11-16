/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_JIT_EXTENSION_BRIDGE_H
#define HENGE_JIT_EXTENSION_BRIDGE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C bridge for invoking the embedded `HengeLinuxJITExtension`
/// (`com.apple.ar.viewer` appex) via `NSExtension` XPC lifecycle callbacks.
@interface HengeJITExtensionBridge : NSObject

+ (BOOL)isExtensionRuntimeAvailable;

+ (void)invokeExtensionWithIdentifier:(NSString *)extensionIdentifier
                             userInfo:(NSDictionary<NSString *, id> *)userInfo
                       timeoutSeconds:(NSTimeInterval)timeoutSeconds
                           completion:(void (^)(NSDictionary<NSString *, id> * _Nullable responseInfo,
                                                NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* HENGE_JIT_EXTENSION_BRIDGE_H */
