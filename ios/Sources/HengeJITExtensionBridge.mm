/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "HengeJITExtensionBridge.h"
#import <objc/message.h>

@interface HengePrivateNSExtension : NSObject
+ (nullable instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError * _Nullable * _Nullable)error;
- (void)beginExtensionRequestWithInputItems:(nullable NSArray *)inputItems
                                 completion:(void (^ _Nullable)(id<NSCopying> _Nullable requestIdentifier))completion;
- (void)cancelExtensionRequestWithIdentifier:(id<NSCopying>)requestIdentifier;
@property (nonatomic, copy, nullable) void (^requestCompletionBlock)(id<NSCopying> requestIdentifier, NSArray * _Nullable extensionItems);
@property (nonatomic, copy, nullable) void (^requestCancellationBlock)(id<NSCopying> requestIdentifier, NSError * _Nullable error);
@property (nonatomic, copy, nullable) void (^requestInterruptionBlock)(id<NSCopying> requestIdentifier);
@end

static NSString *const HengeJITExtensionBridgeDomain = @"io.hengelinux.jit-extension";

@implementation HengeJITExtensionBridge

+ (BOOL)isExtensionRuntimeAvailable {
    Class extClass = NSClassFromString(@"NSExtension");
    return extClass != Nil &&
           [extClass respondsToSelector:@selector(extensionWithIdentifier:error:)];
}

+ (void)invokeExtensionWithIdentifier:(NSString *)extensionIdentifier
                             userInfo:(NSDictionary<NSString *, id> *)userInfo
                       timeoutSeconds:(NSTimeInterval)timeoutSeconds
                           completion:(void (^)(NSDictionary<NSString *, id> * _Nullable responseInfo,
                                                NSError * _Nullable error))completion {
    Class extClass = NSClassFromString(@"NSExtension");
    if (extClass == Nil || ![extClass respondsToSelector:@selector(extensionWithIdentifier:error:)]) {
        NSError *err = [NSError errorWithDomain:HengeJITExtensionBridgeDomain
                                           code:2001
                                       userInfo:@{NSLocalizedDescriptionKey: @"NSExtension runtime unavailable in this process."}];
        completion(nil, err);
        return;
    }

    NSError *lookupError = nil;
    id rawExtension = ((id (*)(id, SEL, NSString *, NSError **))objc_msgSend)(
        extClass,
        @selector(extensionWithIdentifier:error:),
        extensionIdentifier,
        &lookupError
    );
    HengePrivateNSExtension *extension = (HengePrivateNSExtension *)rawExtension;
    if (!extension) {
        NSError *err = lookupError ?: [NSError errorWithDomain:HengeJITExtensionBridgeDomain
                                                          code:2002
                                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Embedded JIT extension '%@' not registered by PlugInKit.", extensionIdentifier]}];
        completion(nil, err);
        return;
    }

    NSLock *guardLock = [[NSLock alloc] init];
    __block BOOL finished = NO;
    __block id<NSCopying> activeRequestID = nil;
    __block HengePrivateNSExtension *retainedExtension = extension;

    void (^finishOnce)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable) =
        ^(NSDictionary<NSString *, id> * _Nullable info, NSError * _Nullable err) {
            [guardLock lock];
            if (finished) {
                [guardLock unlock];
                return;
            }
            finished = YES;
            retainedExtension.requestCompletionBlock = nil;
            retainedExtension.requestCancellationBlock = nil;
            retainedExtension.requestInterruptionBlock = nil;
            retainedExtension = nil;
            [guardLock unlock];
            completion(info, err);
        };

    extension.requestCompletionBlock = ^(id<NSCopying> requestIdentifier, NSArray * _Nullable extensionItems) {
        (void)requestIdentifier;
        NSMutableDictionary<NSString *, id> *merged = [NSMutableDictionary dictionary];
        for (id item in extensionItems) {
            if ([item isKindOfClass:[NSExtensionItem class]]) {
                NSDictionary *dict = ((NSExtensionItem *)item).userInfo;
                if ([dict isKindOfClass:[NSDictionary class]]) {
                    for (id key in dict) {
                        if ([key isKindOfClass:[NSString class]]) {
                            merged[(NSString *)key] = dict[key];
                        }
                    }
                }
            }
        }
        finishOnce([merged copy], nil);
    };

    extension.requestCancellationBlock = ^(id<NSCopying> requestIdentifier, NSError * _Nullable error) {
        (void)requestIdentifier;
        NSError *err = error ?: [NSError errorWithDomain:HengeJITExtensionBridgeDomain
                                                    code:2003
                                                userInfo:@{NSLocalizedDescriptionKey: @"JIT helper extension request was cancelled."}];
        finishOnce(nil, err);
    };

    extension.requestInterruptionBlock = ^(id<NSCopying> requestIdentifier) {
        (void)requestIdentifier;
        NSError *err = [NSError errorWithDomain:HengeJITExtensionBridgeDomain
                                           code:2004
                                       userInfo:@{NSLocalizedDescriptionKey: @"JIT helper extension process was interrupted (check extension memory ceiling)."}];
        finishOnce(nil, err);
    };

    NSExtensionItem *inputItem = [[NSExtensionItem alloc] init];
    inputItem.userInfo = userInfo;

    NSTimeInterval effectiveTimeout = (timeoutSeconds > 0.5) ? timeoutSeconds : 8.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(effectiveTimeout * (double)NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [guardLock lock];
        BOOL alreadyDone = finished;
        id<NSCopying> reqID = activeRequestID;
        HengePrivateNSExtension *ext = retainedExtension;
        [guardLock unlock];

        if (!alreadyDone) {
            if (reqID != nil && ext != nil &&
                [ext respondsToSelector:@selector(cancelExtensionRequestWithIdentifier:)]) {
                [ext cancelExtensionRequestWithIdentifier:reqID];
            }
            NSError *timeoutErr = [NSError errorWithDomain:HengeJITExtensionBridgeDomain
                                                      code:2005
                                                  userInfo:@{NSLocalizedDescriptionKey: @"JIT helper extension timed out waiting for debugserver handshake."}];
            finishOnce(nil, timeoutErr);
        }
    });

    [extension beginExtensionRequestWithInputItems:@[inputItem]
                                        completion:^(id<NSCopying> _Nullable requestIdentifier) {
        [guardLock lock];
        activeRequestID = requestIdentifier;
        [guardLock unlock];
    }];
}

@end
