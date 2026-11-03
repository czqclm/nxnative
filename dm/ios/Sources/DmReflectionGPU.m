#import "DmReflectionGPU.h"
#import <os/lock.h>
#include <math.h>

@interface DmReflectionFrame : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) BOOL capturing;
@property(nonatomic) NSUInteger readers;
@end
@implementation DmReflectionFrame
@end

static os_unfair_lock routeLock = OS_UNFAIR_LOCK_INIT;
static __weak DmReflectionGPU *captureTarget;

typedef struct { float dx, dy; } DmBlurStep;
typedef struct { float width, height, fraction, unused; } DmReflectionSample;

static NSString *const reflectionMetal =
@"#include <metal_stdlib>\n"
 "using namespace metal;\n"
 "constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);\n"
 "kernel void captureSmall(texture2d<float, access::sample> src [[texture(0)]],\n"
 " texture2d<half, access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {\n"
 " if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;\n"
 " float2 uv = (float2(p) + .5) / float2(dst.get_width(), dst.get_height());\n"
 " dst.write(half4(half3(src.sample(linearClamp, uv).rgb), half(1)), p);\n"
 "}\n"
 "kernel void gaussianAxis(texture2d<float, access::sample> src [[texture(0)]],\n"
 " texture2d<half, access::write> dst [[texture(1)]], constant float2 &step [[buffer(0)]],\n"
 " uint2 p [[thread_position_in_grid]]) {\n"
 " if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;\n"
 " float2 uv = (float2(p) + .5) / float2(dst.get_width(), dst.get_height());\n"
 " constexpr float weights[5] = {.2270270270, .1945945946, .1216216216, .0540540541, .0162162162};\n"
 " float3 rgb = src.sample(linearClamp, uv).rgb * weights[0];\n"
 " for (uint k=1; k<5; ++k) rgb += weights[k] *\n"
 "   (src.sample(linearClamp, uv + step * float(k)).rgb + src.sample(linearClamp, uv - step * float(k)).rgb);\n"
 " dst.write(half4(half3(rgb), half(1)), p);\n"
 "}\n"
 "vertex float4 reflectionVertex(uint n [[vertex_id]]) {\n"
 " constexpr float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[n],0,1);\n"
 "}\n"
 "struct Sample { float width, height, fraction, unused; };\n"
 "fragment float4 reflectionFragment(float4 p [[position]], texture2d<float> src [[texture(0)]],\n"
 " constant Sample &s [[buffer(0)]]) {\n"
 " float2 uv = float2(p.x / s.width, 1.0 - p.y / s.height * s.fraction);\n"
 " return float4(src.sample(linearClamp, uv).rgb, 1);\n"
 "}\n";

@interface DmReflectionGPU ()
- (void)captureCommand:(id<MTLCommandBuffer>)command source:(id<MTLTexture>)source;
#if !TARGET_OS_SIMULATOR
- (void)captureQueue4:(id<MTL4CommandQueue>)queue source:(id<MTLTexture>)source;
#endif
@end

@implementation DmReflectionGPU {
    os_unfair_lock _lock;
    id<MTLDevice> _device;
    dispatch_queue_t _work;
    id<MTLCommandQueue> _copyQueue, _drawQueue;
    id<MTLComputePipelineState> _downsample, _gaussian;
    id<MTLRenderPipelineState> _present;
    id<MTLSharedEvent> _bridgeEvent;
    uint64_t _eventValue, _generation;
    BOOL _eligible, _suspended, _invalid, _failed, _ready, _bridgeBusy;
    BOOL _renderBusy, _renderScheduled, _renderWanted;
    NSUInteger _width, _height;
    CGSize _gameSize;
    CGFloat _fraction, _strength;
    CAMetalLayer *_layer;
    NSArray<DmReflectionFrame *> *_frames;
    DmReflectionFrame *_last;
    // Only the serial worker touches scratch textures. One draw is in flight.
    id<MTLTexture> _horizontal, _vertical;
    NSUInteger _captures, _bridgeCaptures, _classicCaptures, _renders, _skipped, _errors;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT; _device = device; _generation = 1;
        _work = dispatch_queue_create("org.nxnative.reflection.gpu", DISPATCH_QUEUE_SERIAL);
        _frames = @[];
        dispatch_async(_work, ^{ [self preparePipelines]; });
    }
    return self;
}
- (void)preparePipelines {
    @autoreleasepool {
        NSError *error = nil;
        id<MTLLibrary> library = [_device newLibraryWithSource:reflectionMetal options:nil error:&error];
        id<MTLComputePipelineState> down = library ? [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"captureSmall"] error:&error] : nil;
        id<MTLComputePipelineState> gaussian = library ? [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"gaussianAxis"] error:&error] : nil;
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"reflectionVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"reflectionFragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> present = library ? [_device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
        id<MTLCommandQueue> copy = [_device newCommandQueueWithMaxCommandBufferCount:2];
        id<MTLCommandQueue> draw = [_device newCommandQueueWithMaxCommandBufferCount:2];
        id<MTLSharedEvent> event = [_device newSharedEvent];
        os_unfair_lock_lock(&_lock);
        if (!_invalid) {
            _downsample = down; _gaussian = gaussian; _present = present;
            _copyQueue = copy; _drawQueue = draw; _bridgeEvent = event;
            _failed = !down || !gaussian || !present || !copy || !draw || !event;
        }
        BOOL failed = _failed;
        os_unfair_lock_unlock(&_lock);
        if (failed) NSLog(@"[RED] control reflection: GPU preparation failed: %@", error);
        [self prepareFrames];
    }
}
- (id<MTLTexture>)textureWidth:(NSUInteger)width height:(NSUInteger)height {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
        width:width height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return [_device newTextureWithDescriptor:descriptor];
}
- (void)prepareFrames {
    os_unfair_lock_lock(&_lock);
    BOOL needed = _eligible && !_invalid && !_failed && _downsample && !_ready;
    NSUInteger width = _width, height = _height; uint64_t generation = _generation;
    os_unfair_lock_unlock(&_lock);
    if (!needed || !width || !height) return;
    NSMutableArray *frames = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        DmReflectionFrame *frame = [DmReflectionFrame new]; frame.texture = [self textureWidth:width height:height];
        if (!frame.texture) break;
        frame.texture.label = @"Reflection immutable capture slot"; [frames addObject:frame];
    }
    os_unfair_lock_lock(&_lock);
    if (generation == _generation && _eligible && !_invalid && frames.count == 4) {
        _frames = frames; _ready = YES; [self scheduleRenderLocked];
    }
    os_unfair_lock_unlock(&_lock);
}
- (void)scheduleRenderLocked {
    if (!_renderWanted || _renderScheduled || _renderBusy || !_layer || !_last || _suspended || _invalid || _failed || !_present) return;
    _renderScheduled = YES;
    dispatch_async(_work, ^{ @autoreleasepool { [self renderLatest]; } });
}
- (void)updateLayer:(CAMetalLayer *)layer captureEligible:(BOOL)eligible
       captureSize:(CGSize)captureSize gameSize:(CGSize)gameSize
    sampleFraction:(CGFloat)fraction blurStrength:(CGFloat)strength {
    NSAssert(NSThread.isMainThread, @"Reflection configuration belongs to the main thread");
    NSUInteger width = (NSUInteger)fmax(1, fmin(640, ceil(captureSize.width)));
    NSUInteger height = (NSUInteger)fmax(1, fmin(640, ceil(captureSize.height)));
    os_unfair_lock_lock(&_lock);
    BOOL resize = width != _width || height != _height;
    BOOL topology = resize || _layer != layer || _eligible != eligible;
    if (topology) _generation++;
    _eligible = eligible && !_invalid; _layer = layer; _gameSize = gameSize;
    _fraction = isfinite(fraction) ? fmin(1, fmax(0, fraction)) : 1;
    _strength = isfinite(strength) ? fmin(1, fmax(0, strength)) : 1;
    _width = width; _height = height;
    if (resize || !_eligible) { _frames = @[]; _ready = NO; }
    _renderWanted = layer != nil;
    [self scheduleRenderLocked];
    os_unfair_lock_unlock(&_lock);
    os_unfair_lock_lock(&routeLock);
    if (_eligible) captureTarget = self; else if (captureTarget == self) captureTarget = nil;
    os_unfair_lock_unlock(&routeLock);
    dispatch_async(_work, ^{
        [self prepareFrames];
        if (!layer) { self->_horizontal = nil; self->_vertical = nil; }
    });
}
- (void)setSuspended:(BOOL)suspended {
    os_unfair_lock_lock(&_lock);
    if (_suspended != suspended) _generation++;
    _suspended = suspended;
    if (!suspended && _layer) _renderWanted = YES;
    [self scheduleRenderLocked];
    os_unfair_lock_unlock(&_lock);
    if (!suspended) dispatch_async(_work, ^{ [self prepareFrames]; });
}
- (void)invalidate {
    os_unfair_lock_lock(&routeLock);
    if (captureTarget == self) captureTarget = nil;
    os_unfair_lock_unlock(&routeLock);
    os_unfair_lock_lock(&_lock);
    _generation++; _invalid = YES; _eligible = NO; _layer = nil; _last = nil; _frames = @[]; _ready = NO;
    os_unfair_lock_unlock(&_lock);
    dispatch_async(_work, ^{ self->_horizontal = nil; self->_vertical = nil; });
}

- (DmReflectionFrame *)reserveSource:(id<MTLTexture>)source bridge:(BOOL)bridge
                          generation:(uint64_t *)generation pipeline:(id<MTLComputePipelineState> __strong *)pipeline
                               event:(id<MTLSharedEvent> __strong *)event readyValue:(uint64_t *)readyValue {
    // The guest's presentation thread must never wait behind UI configuration.
    if (!os_unfair_lock_trylock(&_lock)) return nil;
    DmReflectionFrame *slot = nil;
    if (_eligible && !_suspended && !_invalid && !_failed && _ready && source.device == _device
        && source.textureType == MTLTextureType2D && source.sampleCount == 1 && (!bridge || !_bridgeBusy)) {
        for (DmReflectionFrame *candidate in _frames) {
            if (candidate != _last && !candidate.capturing && !candidate.readers) { slot = candidate; break; }
        }
    }
    if (slot) {
        slot.capturing = YES; *generation = _generation; *pipeline = _downsample;
        if (bridge) { _bridgeBusy = YES; *event = _bridgeEvent; *readyValue = ++_eventValue; _eventValue++; }
    } else _skipped++;
    os_unfair_lock_unlock(&_lock);
    return slot;
}
- (BOOL)encodeCapture:(id<MTLCommandBuffer>)command source:(id<MTLTexture>)source
                 slot:(DmReflectionFrame *)slot pipeline:(id<MTLComputePipelineState>)pipeline {
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!encoder) return NO;
    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:source atIndex:0]; [encoder setTexture:slot.texture atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(slot.texture.width, slot.texture.height, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder endEncoding]; return YES;
}
- (void)cancelSlot:(DmReflectionFrame *)slot bridge:(BOOL)bridge {
    if (os_unfair_lock_trylock(&_lock)) {
        slot.capturing = NO; if (bridge) _bridgeBusy = NO; os_unfair_lock_unlock(&_lock);
    } else {
        dispatch_async(_work, ^{
            os_unfair_lock_lock(&self->_lock); slot.capturing = NO;
            if (bridge) self->_bridgeBusy = NO;
            os_unfair_lock_unlock(&self->_lock);
        });
    }
}
- (void)completeSlot:(DmReflectionFrame *)slot generation:(uint64_t)generation
              command:(id<MTLCommandBuffer>)command bridgeEvent:(id<MTLSharedEvent>)event done:(uint64_t)done {
    BOOL success = command.status == MTLCommandBufferStatusCompleted;
    os_unfair_lock_lock(&_lock);
    slot.capturing = NO;
    if (event) _bridgeBusy = NO;
    if (!success) { _failed = YES; _errors++; }
    if (success && generation == _generation && !_invalid) {
        _last = slot; _captures++;
        if (event) _bridgeCaptures++; else _classicCaptures++;
        if (_layer && !_suspended) _renderWanted = YES;
        [self scheduleRenderLocked];
    }
    os_unfair_lock_unlock(&_lock);
    if (!success) {
        // A failed copy may never execute its GPU signal. Fail closed before
        // releasing the host's queued GPU wait; no new bridge can race this value.
        if (event) event.signaledValue = MAX(event.signaledValue, done);
        NSLog(@"[RED] control reflection: capture failed (status=%lu): %@",
              (unsigned long)command.status, command.error);
    }
}
- (void)captureCommand:(id<MTLCommandBuffer>)command source:(id<MTLTexture>)source {
    if (!command || command.device != _device || command.status >= MTLCommandBufferStatusCommitted) return;
    uint64_t generation = 0, unused = 0; id<MTLComputePipelineState> pipeline; id<MTLSharedEvent> event;
    DmReflectionFrame *slot = [self reserveSource:source bridge:NO generation:&generation pipeline:&pipeline event:&event readyValue:&unused];
    if (!slot) return;
    if (![self encodeCapture:command source:source slot:slot pipeline:pipeline]) { [self cancelSlot:slot bridge:NO]; return; }
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        [self completeSlot:slot generation:generation command:completed bridgeEvent:nil done:0];
    }];
}
#if !TARGET_OS_SIMULATOR
- (void)captureQueue4:(id<MTL4CommandQueue>)queue source:(id<MTLTexture>)source {
    if (!queue || queue.device != _device) return;
    uint64_t generation = 0, ready = 0; id<MTLComputePipelineState> pipeline; id<MTLSharedEvent> event;
    DmReflectionFrame *slot = [self reserveSource:source bridge:YES generation:&generation pipeline:&pipeline event:&event readyValue:&ready];
    if (!slot) return;
    // These buffers retain resources. Preparing every encoder before touching
    // the Metal 4 queue leaves a clean skip path on allocation/encoder failure.
    id<MTLCommandBuffer> command = [_copyQueue commandBuffer];
    if (!command) { [self cancelSlot:slot bridge:YES]; return; }
    uint64_t done = ready + 1;
    [command encodeWaitForEvent:event value:ready];
    if (![self encodeCapture:command source:source slot:slot pipeline:pipeline]) { [self cancelSlot:slot bridge:YES]; return; }
    [command encodeSignalEvent:event value:done];
    // Reservation preceded CPU encoder setup. The scene may have suspended in
    // that interval. No event operation is issued until this final gate passes.
    if (!os_unfair_lock_trylock(&_lock)) { [self cancelSlot:slot bridge:YES]; return; }
    BOOL submit = generation == _generation && _eligible && !_suspended && !_invalid && !_failed;
    if (submit) {
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            [self completeSlot:slot generation:generation command:completed bridgeEvent:event done:done];
        }];
        [queue signalEvent:event value:ready];
        [command commit];
        [queue waitForEvent:event value:done];
    } else { slot.capturing = NO; _bridgeBusy = NO; }
    os_unfair_lock_unlock(&_lock);
}
#endif

- (void)finishRender:(DmReflectionFrame *)frame completed:(BOOL)completed {
    os_unfair_lock_lock(&_lock);
    if (frame.readers) frame.readers--;
    _renderBusy = NO; if (completed) _renders++;
    [self scheduleRenderLocked]; os_unfair_lock_unlock(&_lock);
}
- (void)renderLatest {
    os_unfair_lock_lock(&_lock); _renderScheduled = NO;
    if (_renderBusy || !_renderWanted || !_last || !_layer || _suspended || _invalid || _failed || !_present) {
        os_unfair_lock_unlock(&_lock); return;
    }
    _renderWanted = NO; _renderBusy = YES;
    DmReflectionFrame *frame = _last; frame.readers++;
    CAMetalLayer *layer = _layer; uint64_t generation = _generation;
    CGFloat strength = _strength, fraction = _fraction; CGSize game = _gameSize;
    os_unfair_lock_unlock(&_lock);
    id<MTLTexture> picture = frame.texture;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    id<MTLCommandBuffer> command = drawable ? [_drawQueue commandBuffer] : nil;
    if (!command) { [self finishRender:frame completed:NO]; return; }
    command.label = @"Uniform black-preserving reflection";
    if (strength > 0) {
        if (_horizontal.width != picture.width || _horizontal.height != picture.height) {
            _horizontal = [self textureWidth:picture.width height:picture.height];
            _vertical = [self textureWidth:picture.width height:picture.height];
        }
        if (!_horizontal || !_vertical) { [self finishRender:frame completed:NO]; return; }
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (!encoder) { [self finishRender:frame completed:NO]; return; }
        [encoder setComputePipelineState:_gaussian];
        DmBlurStep horizontal = {(float)(14 * strength / fmax(1, game.width) / 4), 0};
        DmBlurStep vertical = {0, (float)(14 * strength / fmax(1, game.height) / 4)};
        [encoder setTexture:picture atIndex:0]; [encoder setTexture:_horizontal atIndex:1];
        [encoder setBytes:&horizontal length:sizeof(horizontal) atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(picture.width, picture.height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder endEncoding];
        encoder = [command computeCommandEncoder];
        if (!encoder) { [self finishRender:frame completed:NO]; return; }
        [encoder setComputePipelineState:_gaussian];
        [encoder setTexture:_horizontal atIndex:0]; [encoder setTexture:_vertical atIndex:1];
        [encoder setBytes:&vertical length:sizeof(vertical) atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(picture.width, picture.height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder endEncoding]; picture = _vertical;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) { [self finishRender:frame completed:NO]; return; }
    [encoder setRenderPipelineState:_present]; [encoder setFragmentTexture:picture atIndex:0];
    DmReflectionSample sample = {(float)drawable.texture.width, (float)drawable.texture.height, (float)fraction, 0};
    [encoder setFragmentBytes:&sample length:sizeof(sample) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [encoder endEncoding];
    // Serialize the final eligibility check with lifecycle suspension. A scene
    // cannot start another reflection submission after suspension takes effect.
    os_unfair_lock_lock(&_lock);
    BOOL submit = generation == _generation && _layer == layer && !_suspended && !_invalid && !_failed;
    if (submit) {
        // An uncommitted buffer can be discarded by a lifecycle/configuration
        // change. Give only submitted buffers a completion owner; rejected
        // buffers release the slot once through the manual path below.
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status != MTLCommandBufferStatusCompleted)
                NSLog(@"[RED] control reflection: render failed (status=%lu): %@",
                      (unsigned long)completed.status, completed.error);
            [self finishRender:frame completed:completed.status == MTLCommandBufferStatusCompleted];
        }];
        [command presentDrawable:drawable]; [command commit];
    }
    os_unfair_lock_unlock(&_lock);
    if (!submit) [self finishRender:frame completed:NO];
}
- (NSDictionary<NSString *, id> *)debugSnapshot {
    os_unfair_lock_lock(&_lock);
    NSDictionary *snapshot = @{@"backend": @"gpuGaussian", @"captureEligible": @(_eligible), @"suspended": @(_suspended),
        @"ready": @(_ready), @"failed": @(_failed), @"captureWidth": @(_width), @"captureHeight": @(_height),
        @"captureSlots": @(_frames.count), @"hasLastFrame": @(_last != nil), @"capturesCompleted": @(_captures),
        @"bridgeCapturesCompleted": @(_bridgeCaptures), @"classicCapturesCompleted": @(_classicCaptures),
        @"rendersCompleted": @(_renders), @"capturesSkipped": @(_skipped), @"captureErrors": @(_errors),
        @"bridgeInFlight": @(_bridgeBusy), @"renderInFlight": @(_renderBusy), @"generation": @(_generation)};
    os_unfair_lock_unlock(&_lock); return snapshot;
}
@end

static DmReflectionGPU *currentCaptureTarget(void) {
    if (!os_unfair_lock_trylock(&routeLock)) return nil;
    DmReflectionGPU *target = captureTarget;
    os_unfair_lock_unlock(&routeLock); return target;
}
void dm_control_reflection_capture(id<MTLCommandBuffer> command, id<MTLTexture> source) {
    @autoreleasepool { DmReflectionGPU *target = currentCaptureTarget(); if (target && source) [target captureCommand:command source:source]; }
}
#if !TARGET_OS_SIMULATOR
void dm_control_reflection_capture_m4(id<MTL4CommandQueue> queue, id<MTLTexture> source) {
    @autoreleasepool { DmReflectionGPU *target = currentCaptureTarget(); if (target && source) [target captureQueue4:queue source:source]; }
}
#endif
