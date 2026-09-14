#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <substrate.h>

// Bilibili-only fix for old ijkplayer builds.
// The public IJKSDLAudioQueueController.m sets TimePitchAlgorithm on
// _audioQueueRef before assigning audioQueueRef to that ivar. This tweak
// re-applies the intended algorithm after the queue is actually valid.

#define GTPF_ALGORITHM kAudioQueueTimePitchAlgorithm_Spectral

typedef id   (*InitWithAudioSpecIMP)(id, SEL, const void *);
typedef void (*SetPlaybackRateIMP)(id, SEL, float);

static InitWithAudioSpecIMP orig_initWithAudioSpec = NULL;
static SetPlaybackRateIMP   orig_setPlaybackRate = NULL;

static AudioQueueRef GTPFGetQueue(id obj) {
    if (!obj) return NULL;
    Class cls = object_getClass(obj);
    Ivar ivar = class_getInstanceVariable(cls, "_audioQueueRef");
    if (!ivar) return NULL;

    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t *base = (uint8_t *)(__bridge void *)obj;
    return *(AudioQueueRef *)(base + offset);
}

static void GTPFConfigureQueue(id obj) {
    AudioQueueRef q = GTPFGetQueue(obj);
    if (!q) return;

    UInt32 enabled = 1;
    AudioQueueSetProperty(q,
                          kAudioQueueProperty_EnableTimePitch,
                          &enabled,
                          sizeof(enabled));

    UInt32 algorithm = GTPF_ALGORITHM;
    AudioQueueSetProperty(q,
                          kAudioQueueProperty_TimePitchAlgorithm,
                          &algorithm,
                          sizeof(algorithm));
}

static id hook_initWithAudioSpec(id self, SEL _cmd, const void *spec) {
    id result = orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, spec) : self;
    if (result) {
        // At this point ijkplayer has finished assigning _audioQueueRef.
        GTPFConfigureQueue(result);
    }
    return result;
}

static void hook_setPlaybackRate(id self, SEL _cmd, float rate) {
    // Re-apply immediately before ijkplayer toggles bypass / play rate.
    // This also handles cases where AudioQueue internally resets the property.
    GTPFConfigureQueue(self);
    if (orig_setPlaybackRate) orig_setPlaybackRate(self, _cmd, rate);
}

static void GTPFInstallHooks(void) {
    Class cls = NSClassFromString(@"IJKSDLAudioQueueController");
    if (!cls) return;

    SEL initSel = NSSelectorFromString(@"initWithAudioSpec:");
    Method initMethod = class_getInstanceMethod(cls, initSel);
    if (initMethod) {
        MSHookMessageEx(cls,
                        initSel,
                        (IMP)hook_initWithAudioSpec,
                        (IMP *)&orig_initWithAudioSpec);
    }

    SEL rateSel = @selector(setPlaybackRate:);
    Method rateMethod = class_getInstanceMethod(cls, rateSel);
    if (rateMethod) {
        MSHookMessageEx(cls,
                        rateSel,
                        (IMP)hook_setPlaybackRate,
                        (IMP *)&orig_setPlaybackRate);
    }
}

%ctor {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"tv.danmaku.bilianime"]) return;

        // The IJK classes live in a bundled framework in this Bilibili build,
        // so wait briefly for them to be loaded before installing hooks.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            GTPFInstallHooks();
        });
    }
}
