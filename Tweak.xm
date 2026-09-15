#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <new>
#include "vendor/vlc_scaletempo/GTScaleTempo.h"

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
    volatile int transitionPending;
    GTScaleTempo *scaleTempo;
    int16_t lastOutput[2];
    int haveLastOutput;
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

static BOOL GTPFResetScaleTempo(GTPFContext *ctx, float speed) {
    if (!ctx || !ctx->scaleTempo || !ctx->scaleTempo->valid()) return NO;
    // 0.7.1: never allocate/free the DSP from the realtime AudioQueue callback.
    // Reset only its buffered state; the object itself is pre-created at controller init.
    ctx->scaleTempo->reset();
    ctx->scaleTempo->setSpeed(speed);
    ctx->resetRequested = 0;
    return YES;
}

static void GTPFRememberTail(GTPFContext *ctx, const int16_t *samples, int frames) {
    if (!ctx || !samples || frames <= 0) return;
    const int base = (frames - 1) * ctx->channels;
    for (int ch = 0; ch < ctx->channels && ch < 2; ++ch) ctx->lastOutput[ch] = samples[base + ch];
    ctx->haveLastOutput = 1;
}

static void GTPFApplyTransitionFade(GTPFContext *ctx, int16_t *samples, int frames) {
    if (!ctx || !samples || frames <= 0 || !ctx->transitionPending) return;
    if (!ctx->haveLastOutput) {
        ctx->transitionPending = 0;
        return;
    }

    // Smooth the first ~5 ms after a rate-path switch.  A hard jump between the
    // previous DSP/raw tail and the new buffer is exactly the kind of discontinuity
    // that is heard as a sharp click/pop.
    int fadeFrames = ctx->sampleRate / 200; // 5 ms
    if (fadeFrames < 16) fadeFrames = 16;
    if (fadeFrames > frames) fadeFrames = frames;
    if (fadeFrames <= 1) {
        ctx->transitionPending = 0;
        return;
    }

    for (int f = 0; f < fadeFrames; ++f) {
        float w = (float)f / (float)(fadeFrames - 1);
        for (int ch = 0; ch < ctx->channels && ch < 2; ++ch) {
            int idx = f * ctx->channels + ch;
            float a = (float)ctx->lastOutput[ch];
            float b = (float)samples[idx];
            int v = (int)lrintf(a + (b - a) * w);
            if (v > 32767) v = 32767;
            if (v < -32768) v = -32768;
            samples[idx] = (int16_t)v;
        }
    }
    ctx->transitionPending = 0;
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

    // Exact 1x bypass: no conversion, no DSP. 0.7.1 keeps a tiny transition
    // crossfade so returning from a processed rate does not hard-step the waveform.
    if (fabsf(speed - 1.0f) < 0.0001f) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        int frames = (ctx->frameBytes > 0 && (len % ctx->frameBytes) == 0) ? (len / ctx->frameBytes) : 0;
        if (frames > 0) {
            int16_t *dst = (int16_t *)stream;
            GTPFApplyTransitionFade(ctx, dst, frames);
            GTPFRememberTail(ctx, dst, frames);
        }
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

    if (ctx->resetRequested || !ctx->scaleTempo) {
        if (!GTPFResetScaleTempo(ctx, speed)) {
            ctx->originalCallback(ctx->originalUserdata, stream, len);
            return;
        }
    } else {
        ctx->scaleTempo->setSpeed(speed);
    }

    // Pull source PCM repeatedly until VLC-style scaletempo has enough output
    // for one hardware AudioQueue callback. At 3x this normally consumes ~3x
    // source PCM while the hardware queue itself remains fixed at 1x.
    int loops = 0;
    const int maxLoops = 64;
    while (ctx->scaleTempo->availableFrames() < outputFrames && loops < maxLoops) {
        ctx->originalCallback(ctx->originalUserdata, (GTUint8 *)ctx->inputS16, len);
        const int values = outputFrames * ctx->channels;
        for (int i = 0; i < values; ++i) ctx->inputF32[i] = (float)ctx->inputS16[i] / 32768.0f;
        if (!ctx->scaleTempo->push(ctx->inputF32, outputFrames)) break;
        loops++;
    }

    int got = ctx->scaleTempo->read(ctx->outputF32, outputFrames);
    int16_t *dst = (int16_t *)stream;
    const int gotValues = got * ctx->channels;
    for (int i = 0; i < gotValues; ++i) dst[i] = GTPFFloatToS16(ctx->outputF32[i]);

    // Startup or unexpected starvation. Avoid an abrupt signal->zero edge: taper the
    // missing tail toward zero and request a short fade on the next callback.
    if (got < outputFrames) {
        int16_t tail[2] = {0, 0};
        if (got > 0) {
            int base = (got - 1) * ctx->channels;
            for (int ch = 0; ch < ctx->channels && ch < 2; ++ch) tail[ch] = dst[base + ch];
        }
        int missingFrames = outputFrames - got;
        for (int f = 0; f < missingFrames; ++f) {
            float k = 1.0f - ((float)(f + 1) / (float)missingFrames);
            for (int ch = 0; ch < ctx->channels && ch < 2; ++ch)
                dst[(got + f) * ctx->channels + ch] = (int16_t)lrintf((float)tail[ch] * k);
        }
        ctx->transitionPending = 1;
    }

    GTPFApplyTransitionFade(ctx, dst, outputFrames);
    GTPFRememberTail(ctx, dst, outputFrames);
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
    ctx->transitionPending = 0;
    ctx->scaleTempo = new (std::nothrow) GTScaleTempo(ctx->sampleRate, ctx->channels);
    ctx->haveLastOutput = 0;
    if (!ctx->scaleTempo || !ctx->scaleTempo->valid()) {
        delete ctx->scaleTempo;
        free(ctx);
        return orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, spec) : nil;
    }

    // Preallocate normal callback scratch outside the realtime callback. This avoids
    // malloc/realloc spikes at the instant the user changes playback speed.
    int preFrames = spec->samples > 0 ? (int)spec->samples : 4096;
    if (spec->size > 0 && ctx->frameBytes > 0) {
        int bySize = (int)(spec->size / (GTUint32)ctx->frameBytes);
        if (bySize > preFrames) preFrames = bySize;
    }
    if (preFrames < 4096) preFrames = 4096;
    if (!GTPFEnsureCapacity(ctx, preFrames)) {
        delete ctx->scaleTempo;
        free(ctx->inputS16); free(ctx->inputF32); free(ctx->outputF32);
        free(ctx);
        return orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, spec) : nil;
    }

    GTSDL_AudioSpec modified = *spec;
    modified.callback = GTPFPCMCallback;
    modified.userdata = ctx;

    id result = orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, &modified) : nil;
    if (!result) {
        delete ctx->scaleTempo;
        free(ctx->inputS16); free(ctx->inputF32); free(ctx->outputF32);
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
        if (fabsf(old - sane) > 0.0001f) {
            const BOOL oldOne = fabsf(old - 1.0f) < 0.0001f;
            const BOOL newOne = fabsf(sane - 1.0f) < 0.0001f;
            ctx->requestedSpeed = sane;
            ctx->transitionPending = 1;
            // Crossing the 1x bypass boundary invalidates buffered DSP audio. A
            // non-1x -> non-1x change can safely keep VLC scaletempo's history.
            if (oldOne != newOne) ctx->resetRequested = 1;
        }
    }

    // Keep Apple's AudioQueue playback-rate DSP completely out of the path.
    // IJKFFMoviePlayerController still receives the real user speed and drives
    // video/clock synchronization; only the audio queue is held at 1x.
    if (orig_setPlaybackRate) orig_setPlaybackRate(self, _cmd, 1.0f);
}

static void hook_flush(id self, SEL _cmd) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (ctx) { ctx->resetRequested = 1; ctx->transitionPending = 1; }
    if (orig_flush) orig_flush(self, _cmd);
}

static void hook_stop(id self, SEL _cmd) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (ctx) {
        // Prototype safety choice: do not free here. AudioQueue callbacks may still
        // be unwinding. The small context is reclaimed when Bilibili exits.
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
