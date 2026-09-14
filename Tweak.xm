#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "sonic.h"

// Minimal copy of ijkplayer's SDL_AudioSpec layout.
typedef uint8_t  GTUint8;
typedef uint16_t GTUint16;
typedef uint32_t GTUint32;
typedef uint16_t GTSDL_AudioFormat;
typedef void (*GTSDL_AudioCallback)(void *userdata, GTUint8 *stream, int len);

typedef struct GTSDL_AudioSpec {
    int freq;
    GTSDL_AudioFormat format;
    GTUint8 channels;
    GTUint8 silence;
    GTUint16 samples;
    GTUint16 padding;
    GTUint32 size;
    GTSDL_AudioCallback callback;
    void *userdata;
} GTSDL_AudioSpec;

// ijkplayer expects signed 16-bit native-endian PCM on iOS.
#define GT_AUDIO_S16SYS 0x8010

typedef struct GTPFContext {
    GTSDL_AudioCallback originalCallback;
    void *originalUserdata;
    int sampleRate;
    int channels;
    int frameBytes;
    volatile float requestedSpeed;
    volatile int resetRequested;
    volatile int stopped;
    sonicStream sonic;
    int16_t *inputBuffer;
    int inputCapacityFrames;
} GTPFContext;

static const void *kGTPFContextKey = &kGTPFContextKey;

static GTPFContext *GTPFGetContext(id obj) {
    NSValue *value = objc_getAssociatedObject(obj, kGTPFContextKey);
    return value ? (GTPFContext *)[value pointerValue] : NULL;
}

static BOOL GTPFEnsureInputCapacity(GTPFContext *ctx, int frames) {
    if (!ctx || frames <= 0) return NO;
    if (ctx->inputCapacityFrames >= frames && ctx->inputBuffer) return YES;
    size_t samples = (size_t)frames * (size_t)ctx->channels;
    int16_t *p = (int16_t *)realloc(ctx->inputBuffer, samples * sizeof(int16_t));
    if (!p) return NO;
    ctx->inputBuffer = p;
    ctx->inputCapacityFrames = frames;
    return YES;
}

static BOOL GTPFResetSonic(GTPFContext *ctx, float speed) {
    if (!ctx) return NO;
    if (ctx->sonic) {
        sonicDestroyStream(ctx->sonic);
        ctx->sonic = NULL;
    }
    ctx->sonic = sonicCreateStream(ctx->sampleRate, ctx->channels);
    if (!ctx->sonic) return NO;
    sonicSetSpeed(ctx->sonic, speed);
    sonicSetPitch(ctx->sonic, 1.0f);
    sonicSetRate(ctx->sonic, 1.0f);
    // Sonic docs: quality=0 is nearly as good and much faster, but A12X has ample CPU.
    sonicSetQuality(ctx->sonic, 1);
    ctx->resetRequested = 0;
    return YES;
}

static void GTPFPCMCallback(void *userdata, GTUint8 *stream, int len) {
    GTPFContext *ctx = (GTPFContext *)userdata;
    if (!ctx || !stream || len <= 0 || !ctx->originalCallback || ctx->stopped) {
        if (stream && len > 0) memset(stream, 0, (size_t)len);
        return;
    }

    float speed = ctx->requestedSpeed;
    if (!isfinite(speed) || speed < 0.25f || speed > 6.0f) speed = 1.0f;

    // At 1x, do an exact pass-through: no Sonic processing at all.
    if (fabsf(speed - 1.0f) < 0.0001f) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        ctx->resetRequested = 1; // discard any old >1x buffered Sonic audio next time it is needed
        return;
    }

    if (ctx->frameBytes <= 0 || (len % ctx->frameBytes) != 0) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        return;
    }

    const int outputFrames = len / ctx->frameBytes;
    if (outputFrames <= 0 || !GTPFEnsureInputCapacity(ctx, outputFrames)) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        return;
    }

    if (ctx->resetRequested || !ctx->sonic) {
        if (!GTPFResetSonic(ctx, speed)) {
            ctx->originalCallback(ctx->originalUserdata, stream, len);
            return;
        }
    } else {
        sonicSetSpeed(ctx->sonic, speed);
    }

    // Feed decoded S16 PCM until Sonic has enough frames for one hardware buffer.
    // For 3x, this normally calls the original ijk callback roughly three times,
    // consuming ~3x source audio while AudioQueue itself stays at 1x.
    int loops = 0;
    const int maxLoops = 12;
    while (sonicSamplesAvailable(ctx->sonic) < outputFrames && loops < maxLoops) {
        memset(ctx->inputBuffer, 0, (size_t)len);
        ctx->originalCallback(ctx->originalUserdata, (GTUint8 *)ctx->inputBuffer, len);
        if (!sonicWriteShortToStream(ctx->sonic, (const short *)ctx->inputBuffer, outputFrames)) {
            break;
        }
        loops++;
    }

    int got = sonicReadShortFromStream(ctx->sonic, (short *)stream, outputFrames);
    if (got < 0) got = 0;
    if (got < outputFrames) {
        size_t offset = (size_t)got * (size_t)ctx->frameBytes;
        size_t missing = (size_t)(outputFrames - got) * (size_t)ctx->frameBytes;
        memset(stream + offset, 0, missing);
    }
}

typedef id (*InitAudioSpecIMP)(id, SEL, const GTSDL_AudioSpec *);
typedef void (*RateSetterIMP)(id, SEL, float);
typedef void (*VoidMethodIMP)(id, SEL);

static InitAudioSpecIMP orig_initWithAudioSpec = NULL;
static RateSetterIMP orig_setPlaybackRate = NULL;
static VoidMethodIMP orig_flush = NULL;
static VoidMethodIMP orig_stop = NULL;

static id hook_initWithAudioSpec(id self, SEL _cmd, const GTSDL_AudioSpec *spec) {
    if (!spec || !spec->callback || spec->freq <= 0 || spec->channels < 1 || spec->channels > 2 || spec->format != GT_AUDIO_S16SYS) {
        return orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, spec) : nil;
    }

    GTPFContext *ctx = (GTPFContext *)calloc(1, sizeof(GTPFContext));
    if (!ctx) return orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, spec) : nil;

    ctx->originalCallback = spec->callback;
    ctx->originalUserdata = spec->userdata;
    ctx->sampleRate = spec->freq;
    ctx->channels = spec->channels;
    ctx->frameBytes = spec->channels * 2;
    ctx->requestedSpeed = 1.0f;
    ctx->resetRequested = 1;
    ctx->stopped = 0;

    GTSDL_AudioSpec modified = *spec;
    modified.callback = GTPFPCMCallback;
    modified.userdata = ctx;

    id result = orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, &modified) : nil;
    if (!result) {
        free(ctx);
        return nil;
    }

    objc_setAssociatedObject(result, kGTPFContextKey, [NSValue valueWithPointer:ctx], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

static void hook_setPlaybackRate(id self, SEL _cmd, float rate) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (ctx) {
        float sane = rate;
        if (!isfinite(sane) || sane < 0.25f || sane > 6.0f) sane = 1.0f;
        float old = ctx->requestedSpeed;
        ctx->requestedSpeed = sane;
        if (fabsf(old - sane) > 0.0001f) ctx->resetRequested = 1;
    }

    // Critical: never ask Apple's AudioQueue TimePitch to change rate.
    // ijkplayer's higher-level FF controller still keeps the real requested rate.
    if (orig_setPlaybackRate) orig_setPlaybackRate(self, _cmd, 1.0f);
}

static void hook_flush(id self, SEL _cmd) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (ctx) ctx->resetRequested = 1;
    if (orig_flush) orig_flush(self, _cmd);
}

static void hook_stop(id self, SEL _cmd) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (ctx) {
        // AudioQueue callbacks may still be unwinding while -stop returns.
        // Do NOT free the context here: the callback's userdata is this raw pointer,
        // and freeing it synchronously can create a use-after-free crash.
        // This prototype deliberately keeps the small context alive until process exit.
        // Once the PCM path is proven stable, production cleanup can be moved to a
        // verified-safe lifecycle point (e.g. after queue disposal/dealloc).
        ctx->stopped = 1;
    }
    if (orig_stop) orig_stop(self, _cmd);
}

static BOOL GTHookMethod(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (!cls || !class_getInstanceMethod(cls, sel)) return NO;
    MSHookMessageEx(cls, sel, replacement, originalOut);
    return YES;
}

static void GTPFInstall(void) {
    Class cls = NSClassFromString(@"IJKSDLAudioQueueController");
    if (!cls) return;
    GTHookMethod(cls, @selector(initWithAudioSpec:), (IMP)hook_initWithAudioSpec, (IMP *)&orig_initWithAudioSpec);
    GTHookMethod(cls, @selector(setPlaybackRate:), (IMP)hook_setPlaybackRate, (IMP *)&orig_setPlaybackRate);
    GTHookMethod(cls, @selector(flush), (IMP)hook_flush, (IMP *)&orig_flush);
    GTHookMethod(cls, @selector(stop), (IMP)hook_stop, (IMP *)&orig_stop);
}

%ctor {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"tv.danmaku.bilianime"]) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GTPFInstall();
        });
    }
}
