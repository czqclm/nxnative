// Test-only animated Metal source in the actual production game layer.
// No game assets, game modules, screenshot readback, or production renderer run.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
NSDictionary *dm_preview_pause_snapshot(void);
void dm_control_reflection_capture(id<MTLCommandBuffer> command, id<MTLTexture> source);
#if !TARGET_OS_SIMULATOR
void dm_control_reflection_capture_m4(id<MTL4CommandQueue> queue, id<MTLTexture> source);
#endif
static uint64_t frameCount;
@interface PreviewMetalRenderer : NSObject
@property(nonatomic, weak) UIView *view;
@property(nonatomic, strong) CADisplayLink *link;
- (instancetype)initWithView:(UIView *)view;
@end
@implementation PreviewMetalRenderer {
    id<MTLCommandQueue> _queue;
#if !TARGET_OS_SIMULATOR
    id<MTL4CommandQueue> _presentQueue;
    id<MTLSharedEvent> _sourceReady;
    uint64_t _ticket;
#endif
    id<MTLRenderPipelineState> _pipeline;
    float _time;
}
- (instancetype)initWithView:(UIView *)view {
    if ((self = [super init])) {
        self.view = view;
        CAMetalLayer *layer = (CAMetalLayer *)view.layer;
        id<MTLDevice> device = layer.device;
        _queue = [device newCommandQueue];
#if !TARGET_OS_SIMULATOR
        _presentQueue = [device newMTL4CommandQueue];
        _sourceReady = [device newSharedEvent];
#endif
        NSString *source = @"#include <metal_stdlib>\n"
            @"using namespace metal;\n"
            @"struct V { float4 position [[position]]; float2 uv; };\n"
            @"vertex V probeVertex(uint id [[vertex_id]]) {\n"
            @"  float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};\n"
            @"  V o; o.position=float4(p[id],0,1); o.uv=float2((p[id].x+1)*.5,(1-p[id].y)*.5); return o;\n"
            @"}\n"
            @"fragment float4 probeFragment(V in [[stage_in]], constant float4 &u [[buffer(0)]]) {\n"
            @"  float2 uv=in.uv; float t=u.x; bool alt=u.y>.5;\n"
            @"  if(u.z==1) return float4(0,0,0,1);\n"
            @"  if(u.z==2) { float d=distance(uv,float2(.5,.65)); return float4(float3(1-smoothstep(.04,.045,d)),1); }\n"
            @"  if(u.z==3) { float c=fmod(floor(uv.x*32)+floor(uv.y*18),2); return float4(float3(c),1); }\n"
            @"  float3 a=alt?float3(.08,.95,.2):float3(.98,.12,.04);\n"
            @"  float3 b=alt?float3(.65,.05,.98):float3(.02,.65,1.0);\n"
            @"  float wave=.5+.5*sin(uv.x*11.0+t*2.0);\n"
            @"  float3 color=mix(a,b,clamp(uv.x*.65+wave*.35,0.0,1.0));\n"
            @"  color*=.5+.5*uv.y;\n"
            @"  float2 center=float2(.5+.3*sin(t),.45+.2*cos(t*.7));\n"
            @"  float spot=1.0-smoothstep(.08,.10,distance(uv,center));\n"
            @"  color=mix(color,float3(1.0),spot*.9);\n"
            @"  if(uv.y>.84) { float stripe=step(.5,fract(uv.x*5.0+t*.35)); color=mix(a,b,stripe); }\n"
            @"  return float4(color,1.0);\n"
            @"}\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"probeVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"probeFragment"];
        descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat;
        if (library) _pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        NSAssert(_pipeline && _queue, @"Metal preview initialization failed: %@", error);
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        self.link.preferredFramesPerSecond = 30;
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (void)tick:(CADisplayLink *)link {
    if (!self.view.window || [dm_preview_pause_snapshot()[@"gfxSuspended"] boolValue]) return;
    [self.view layoutIfNeeded];
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    if (layer.drawableSize.width < 1 || layer.drawableSize.height < 1) return;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return;
    _time += 1.f / 30.f;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    float uniforms[4] = {_time, 0, (float)[NSUserDefaults.standardUserDefaults integerForKey:@"ReflectionTestPattern"], 0};
    [encoder setFragmentBytes:uniforms length:sizeof uniforms atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
#if !TARGET_OS_SIMULATOR
    BOOL metal4 = ![NSUserDefaults.standardUserDefaults objectForKey:@"ReflectionTestMetal4"]
        || [NSUserDefaults.standardUserDefaults boolForKey:@"ReflectionTestMetal4"];
    if (metal4 && _presentQueue && _sourceReady) {
        // Exercise the production Metal-4 cross-queue capture bridge, with a
        // simple classic-Metal source producer instead of any game renderer.
        uint64_t ticket = ++_ticket;
        [command encodeSignalEvent:_sourceReady value:ticket];
        [_presentQueue waitForDrawable:drawable];
        [command commit];
        [_presentQueue waitForEvent:_sourceReady value:ticket];
        dm_control_reflection_capture_m4(_presentQueue, drawable.texture);
        [_presentQueue signalDrawable:drawable];
        [drawable present];
    } else
#endif
    {
        dm_control_reflection_capture(command, drawable.texture);
        [command presentDrawable:drawable]; [command commit];
    }
    frameCount++;
}
@end
static PreviewMetalRenderer *renderer;
void dm_preview_start_metal(UIView *view) {
    if (renderer.view == view) return;
    [renderer.link invalidate]; renderer = [[PreviewMetalRenderer alloc] initWithView:view];
}
uint64_t dm_preview_metal_frames(void) { return frameCount; }
