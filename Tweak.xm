#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <new>
#include "SoundTouch.h"

using soundtouch::SoundTouch;

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
    SoundTouch *st;
    int16_t *inputS16;
    float *inputF32;
    float *outputF32;
    int capacityFrames;
} GTPFContext;

static const void *kGTPFContextKey = &kGTPFContextKey;

static GTPFContext *GTPFGetContext(id obj) {
    NSValue *value = objc_getAssociatedObject(obj, kGTPFContextKey);
    return value ? (GTPFContext *)[value pointerValue] : NULL;
}

static BOOL GTPFEnsureCapacity(GTPFContext *ctx, int frames) {
    if (!ctx || frames <= 0) return NO;
    if (ctx->capacityFrames >= frames && ctx->inputS16 && ctx->inputF32 && ctx->outputF32) return YES;
    size_t count = (size_t)frames * (size_t)ctx->channels;
    int16_t *s16 = (int16_t *)realloc(ctx->inputS16, count * sizeof(int16_t));
    if (!s16) return NO;
    ctx->inputS16 = s16;
    float *in = (float *)realloc(ctx->inputF32, count * sizeof(float));
    if (!in) return NO;
    ctx->inputF32 = in;
    float *out = (float *)realloc(ctx->outputF32, count * sizeof(float));
    if (!out) return NO;
    ctx->outputF32 = out;
    ctx->capacityFrames = frames;
    return YES;
}

static void GTPFTuneSpeech(SoundTouch *st, float speed) {
    if (!st) return;
    st->setSetting(SETTING_USE_QUICKSEEK, 0);
    st->setSetting(SETTING_USE_AA_FILTER, 1);

    // SoundTouch documentation says smaller sequence windows are generally
    // preferable when *speeding up* tempo. These values are intentionally
    // speech-biased rather than music-biased and can be tuned later by A/B tests.
    if (speed >= 2.5f) {
        st->setSetting(SETTING_SEQUENCE_MS, 18);
        st->setSetting(SETTING_SEEKWINDOW_MS, 8);
        st->setSetting(SETTING_OVERLAP_MS, 5);
    } else if (speed >= 1.9f) {
        st->setSetting(SETTING_SEQUENCE_MS, 25);
        st->setSetting(SETTING_SEEKWINDOW_MS, 12);
        st->setSetting(SETTING_OVERLAP_MS, 6);
    } else {
        st->setSetting(SETTING_SEQUENCE_MS, 35);
        st->setSetting(SETTING_SEEKWINDOW_MS, 15);
        st->setSetting(SETTING_OVERLAP_MS, 8);
    }
}

static BOOL GTPFResetSoundTouch(GTPFContext *ctx, float speed) {
    if (!ctx) return NO;
    if (ctx->st) {
        delete ctx->st;
        ctx->st = NULL;
    }
    SoundTouch *st = new (std::nothrow) SoundTouch();
    if (!st) return NO;
    st->setSampleRate((uint)ctx->sampleRate);
    st->setChannels((uint)ctx->channels);
    // Tempo only: duration changes, pitch stays unchanged.
    st->setRate(1.0);
    st->setPitch(1.0);
    st->setTempo((double)speed);
    GTPFTuneSpeech(st, speed);
    ctx->st = st;
    ctx->resetRequested = 0;
    return YES;
}

static inline int16_t GTPFFloatToS16(float x) {
    if (x > 1.0f) x = 1.0f;
    if (x < -1.0f) x = -1.0f;
    int v = (int)lrintf(x * 32767.0f);
    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    return (int16_t)v;
}

static void GTPFPCMCallback(void *userdata, GTUint8 *stream, int len) {
    GTPFContext *ctx = (GTPFContext *)userdata;
    if (!ctx || !stream || len <= 0 || !ctx->originalCallback || ctx->stopped) {
        if (stream && len > 0) memset(stream, 0, (size_t)len);
        return;
    }

    float speed = ctx->requestedSpeed;
    if (!isfinite(speed) || speed < 0.25f || speed > 6.0f) speed = 1.0f;

    if (fabsf(speed - 1.0f) < 0.0001f) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        ctx->resetRequested = 1;
        return;
    }

    if (ctx->frameBytes <= 0 || (len % ctx->frameBytes) != 0) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        return;
    }

    const int outputFrames = len / ctx->frameBytes;
    if (outputFrames <= 0 || !GTPFEnsureCapacity(ctx, outputFrames)) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        return;
    }

    if (ctx->resetRequested || !ctx->st) {
        if (!GTPFResetSoundTouch(ctx, speed)) {
            ctx->originalCallback(ctx->originalUserdata, stream, len);
            return;
        }
    } else {
        ctx->st->setTempo((double)speed);
    }

    int loops = 0;
    const int maxLoops = 16;
    while ((int)ctx->st->numSamples() < outputFrames && loops < maxLoops) {
        ctx->originalCallback(ctx->originalUserdata, (GTUint8 *)ctx->inputS16, len);
        const int values = outputFrames * ctx->channels;
        for (int i = 0; i < values; ++i) {
            ctx->inputF32[i] = (float)ctx->inputS16[i] / 32768.0f;
        }
        ctx->st->putSamples((const soundtouch::SAMPLETYPE *)ctx->inputF32, (uint)outputFrames);
        loops++;
    }

    uint got = ctx->st->receiveSamples((soundtouch::SAMPLETYPE *)ctx->outputF32, (uint)outputFrames);
    const int gotValues = (int)got * ctx->channels;
    int16_t *dst = (int16_t *)stream;
    for (int i = 0; i < gotValues; ++i) dst[i] = GTPFFloatToS16(ctx->outputF32[i]);
    if ((int)got < outputFrames) {
        size_t offset = (size_t)got * (size_t)ctx->frameBytes;
        size_t missing = (size_t)(outputFrames - (int)got) * (size_t)ctx->frameBytes;
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
    ctx->st = NULL;

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

    // Keep Apple's AudioQueue at 1x. The higher-level IJKFF controller still
    // retains the user's real playback speed for video/clock synchronization.
    if (orig_setPlaybackRate) orig_setPlaybackRate(self, _cmd, 1.0f);
}

static void hook_flush(id self, SEL _cmd) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (ctx) ctx->resetRequested = 1;
    if (orig_flush) orig_flush(self, _cmd);
}

static void hook_stop(id self, SEL _cmd) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (ctx) ctx->stopped = 1;
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
