// GPU-only capture and reflection. The primary drawable is never acquired here.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN

// Call after the final render encoder ends, before presenting/committing this
// command buffer. Accepted classic buffers must subsequently be committed.
FOUNDATION_EXPORT void dm_control_reflection_capture(id<MTLCommandBuffer> command,
                                                     id<MTLTexture> source);
// Metal 4 has its own command-buffer protocol. Call synchronously after the
// source queue commit and before its drawable signal/present. This inserts a
// GPU event handshake with a small classic capture command, never a CPU wait.
#if !TARGET_OS_SIMULATOR
FOUNDATION_EXPORT void dm_control_reflection_capture_m4(id<MTL4CommandQueue> queue,
                                                        id<MTLTexture> source);
#endif

@interface DmReflectionGPU : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
// Main-thread configuration. A nil layer hides the effect while eligible
// capture keeps one current frame for controls edited while the guest is paused.
- (void)updateLayer:(nullable CAMetalLayer *)layer captureEligible:(BOOL)eligible
       captureSize:(CGSize)captureSize gameSize:(CGSize)gameSize
    sampleFraction:(CGFloat)fraction blurStrength:(CGFloat)strength;
- (void)setSuspended:(BOOL)suspended;
- (void)invalidate;
- (NSDictionary<NSString *, id> *)debugSnapshot;
@end

NS_ASSUME_NONNULL_END
