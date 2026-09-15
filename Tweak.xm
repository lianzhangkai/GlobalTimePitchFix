#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <new>
#include <pthread.h>
#include <unistd.h>
#include "vendor/vlc_scaletempo/GTScaleTempo.h"

// 0.7.2 architecture change:
// - The original ijk PCM callback is STILL called only from AudioQueue's callback thread.
// - VLC-style scaletempo + S16<->float conversion run on a separate worker thread.
// - Two SPSC rings decouple source PCM and processed PCM.
// This keeps the expensive correlation search out of the realtime AudioQueue callback.

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

// Single-producer/single-consumer interleaved S16 ring. Positions are frame counters.
typedef struct GTS16Ring {
    int16_t *data;
    int capacityFrames;
    int channels;
    volatile uint64_t readPos;
    volatile uint64_t writePos;
} GTS16Ring;

static inline uint64_t GTRingLoadRead(const GTS16Ring *r) {
    return __atomic_load_n(&r->readPos, __ATOMIC_ACQUIRE);
}
static inline uint64_t GTRingLoadWrite(const GTS16Ring *r) {
    return __atomic_load_n(&r->writePos, __ATOMIC_ACQUIRE);
}
static inline void GTRingStoreRead(GTS16Ring *r, uint64_t v) {
    __atomic_store_n(&r->readPos, v, __ATOMIC_RELEASE);
}
static inline void GTRingStoreWrite(GTS16Ring *r, uint64_t v) {
    __atomic_store_n(&r->writePos, v, __ATOMIC_RELEASE);
}
static int GTRingAvailable(const GTS16Ring *r) {
    if (!r || !r->data || r->capacityFrames <= 0) return 0;
    uint64_t rd = GTRingLoadRead(r), wr = GTRingLoadWrite(r);
    uint64_t n = wr >= rd ? (wr - rd) : 0;
    if (n > (uint64_t)r->capacityFrames) n = (uint64_t)r->capacityFrames;
    return (int)n;
}
static int GTRingFree(const GTS16Ring *r) {
    return r ? (r->capacityFrames - GTRingAvailable(r)) : 0;
}
static BOOL GTRingInit(GTS16Ring *r, int capacityFrames, int channels) {
    if (!r || capacityFrames < 1024 || channels < 1 || channels > 2) return NO;
    memset(r, 0, sizeof(*r));
    r->data = (int16_t *)calloc((size_t)capacityFrames * (size_t)channels, sizeof(int16_t));
    if (!r->data) return NO;
    r->capacityFrames = capacityFrames;
    r->channels = channels;
    return YES;
}
static void GTRingDestroy(GTS16Ring *r) {
    if (!r) return;
    free(r->data); r->data = NULL; r->capacityFrames = 0; r->readPos = r->writePos = 0;
}
static void GTRingDiscardAll(GTS16Ring *r) {
    if (!r) return;
    uint64_t wr = GTRingLoadWrite(r);
    GTRingStoreRead(r, wr);
}
static void GTRingResetProducer(GTS16Ring *r) {
    if (!r) return;
    uint64_t rd = GTRingLoadRead(r);
    GTRingStoreWrite(r, rd);
}
static int GTRingWrite(GTS16Ring *r, const int16_t *src, int frames) {
    if (!r || !r->data || !src || frames <= 0) return 0;
    int freeFrames = GTRingFree(r);
    if (frames > freeFrames) frames = freeFrames;
    if (frames <= 0) return 0;
    uint64_t wr = GTRingLoadWrite(r);
    int idx = (int)(wr % (uint64_t)r->capacityFrames);
    int first = r->capacityFrames - idx;
    if (first > frames) first = frames;
    memcpy(r->data + (size_t)idx * (size_t)r->channels,
           src,
           (size_t)first * (size_t)r->channels * sizeof(int16_t));
    int rest = frames - first;
    if (rest > 0) {
        memcpy(r->data,
               src + (size_t)first * (size_t)r->channels,
               (size_t)rest * (size_t)r->channels * sizeof(int16_t));
    }
    GTRingStoreWrite(r, wr + (uint64_t)frames);
    return frames;
}
static int GTRingRead(GTS16Ring *r, int16_t *dst, int frames) {
    if (!r || !r->data || !dst || frames <= 0) return 0;
    int avail = GTRingAvailable(r);
    if (frames > avail) frames = avail;
    if (frames <= 0) return 0;
    uint64_t rd = GTRingLoadRead(r);
    int idx = (int)(rd % (uint64_t)r->capacityFrames);
    int first = r->capacityFrames - idx;
    if (first > frames) first = frames;
    memcpy(dst,
           r->data + (size_t)idx * (size_t)r->channels,
           (size_t)first * (size_t)r->channels * sizeof(int16_t));
    int rest = frames - first;
    if (rest > 0) {
        memcpy(dst + (size_t)first * (size_t)r->channels,
               r->data,
               (size_t)rest * (size_t)r->channels * sizeof(int16_t));
    }
    GTRingStoreRead(r, rd + (uint64_t)frames);
    return frames;
}

typedef struct GTPFContext {
    GTSDL_AudioCallback originalCallback;
    void *originalUserdata;
    int sampleRate;
    int channels;
    int frameBytes;
    int nominalCallbackFrames;

    volatile float requestedSpeed;
    volatile int stopped;
    volatile uint32_t epoch;
    volatile uint32_t workerEpoch;
    volatile int workerExit;
    volatile int workerStarted;

    // AudioQueue-callback-owned accounting. Keeping a small fixed source look-ahead
    // lets the worker stay ahead without calling the ijk callback from another thread.
    uint32_t audioEpochSeen;
    double sourceDemandFrames;
    double sourcePulledFrames;

    GTS16Ring sourceRing; // AQ callback -> worker
    GTS16Ring outputRing; // worker -> AQ callback

    GTScaleTempo *scaleTempo;
    pthread_t workerThread;

    int16_t *callbackScratch;
    int callbackScratchFrames;

    int16_t *workerS16;
    float *workerInF32;
    float *workerOutF32;
    int workerChunkFrames;

    int16_t lastOutput[2];
    int haveLastOutput;
    volatile int transitionPending;
    volatile uint64_t underrunFrames;
} GTPFContext;

static const void *kGTPFContextKey = &kGTPFContextKey;

static GTPFContext *GTPFGetContext(id obj) {
    NSValue *value = objc_getAssociatedObject(obj, kGTPFContextKey);
    return value ? (GTPFContext *)[value pointerValue] : NULL;
}

static inline int16_t GTPFFloatToS16(float x) {
    if (x > 1.0f) x = 1.0f;
    if (x < -1.0f) x = -1.0f;
    int v = (int)lrintf(x * 32767.0f);
    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    return (int16_t)v;
}

static void GTPFRememberTail(GTPFContext *ctx, const int16_t *samples, int frames) {
    if (!ctx || !samples || frames <= 0) return;
    int base = (frames - 1) * ctx->channels;
    for (int ch = 0; ch < ctx->channels && ch < 2; ++ch) ctx->lastOutput[ch] = samples[base + ch];
    ctx->haveLastOutput = 1;
}

static void GTPFApplyTransitionFade(GTPFContext *ctx, int16_t *samples, int frames) {
    if (!ctx || !samples || frames <= 0 || !ctx->transitionPending) return;
    if (!ctx->haveLastOutput) { ctx->transitionPending = 0; return; }
    int fadeFrames = ctx->sampleRate / 200; // about 5 ms
    if (fadeFrames < 16) fadeFrames = 16;
    if (fadeFrames > frames) fadeFrames = frames;
    if (fadeFrames <= 1) { ctx->transitionPending = 0; return; }
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

static void GTPFFillMissingSmooth(GTPFContext *ctx, int16_t *dst, int startFrame, int totalFrames) {
    if (!ctx || !dst || startFrame >= totalFrames) return;
    int16_t tail[2] = {0, 0};
    if (startFrame > 0) {
        int base = (startFrame - 1) * ctx->channels;
        for (int ch = 0; ch < ctx->channels && ch < 2; ++ch) tail[ch] = dst[base + ch];
    } else if (ctx->haveLastOutput) {
        for (int ch = 0; ch < ctx->channels && ch < 2; ++ch) tail[ch] = ctx->lastOutput[ch];
    }
    int missing = totalFrames - startFrame;
    int taper = ctx->sampleRate / 400; // 2.5 ms taper, then silence
    if (taper < 16) taper = 16;
    if (taper > missing) taper = missing;
    for (int f = 0; f < missing; ++f) {
        float k = f < taper ? (1.0f - (float)(f + 1) / (float)taper) : 0.0f;
        for (int ch = 0; ch < ctx->channels && ch < 2; ++ch)
            dst[(startFrame + f) * ctx->channels + ch] = (int16_t)lrintf((float)tail[ch] * k);
    }
    ctx->transitionPending = 1;
    __atomic_add_fetch(&ctx->underrunFrames, (uint64_t)missing, __ATOMIC_RELAXED);
}

static void *GTPFWorkerMain(void *opaque) {
    GTPFContext *ctx = (GTPFContext *)opaque;
    if (!ctx) return NULL;
#if defined(__APPLE__)
    pthread_setname_np("GTPF-ScaleTempo");
#endif
    uint32_t localEpoch = 0;
    while (!ctx->workerExit) {
        uint32_t e = __atomic_load_n(&ctx->epoch, __ATOMIC_ACQUIRE);
        float speed = ctx->requestedSpeed;
        if (!isfinite(speed) || speed < 0.25f || speed > 6.0f) speed = 1.0f;

        if (e != localEpoch) {
            ctx->scaleTempo->reset();
            ctx->scaleTempo->setSpeed(speed);
            // This is safe by protocol: the AQ callback will not consume processed
            // output for a new epoch until workerEpoch publishes this reset.
            GTRingDiscardAll(&ctx->sourceRing);
            GTRingResetProducer(&ctx->outputRing);
            localEpoch = e;
            __atomic_store_n(&ctx->workerEpoch, e, __ATOMIC_RELEASE);
        }

        if (ctx->stopped || fabsf(speed - 1.0f) < 0.0001f) {
            usleep(2000);
            continue;
        }

        ctx->scaleTempo->setSpeed(speed);
        BOOL didWork = NO;

        // Drain already-processed float PCM first, so the DSP's private output
        // buffer cannot grow while the public output ring has room.
        while (ctx->scaleTempo->availableFrames() > 0 && GTRingFree(&ctx->outputRing) > 0) {
            int n = ctx->scaleTempo->availableFrames();
            if (n > ctx->workerChunkFrames) n = ctx->workerChunkFrames;
            int freeFrames = GTRingFree(&ctx->outputRing);
            if (n > freeFrames) n = freeFrames;
            if (n <= 0) break;
            int got = ctx->scaleTempo->read(ctx->workerOutF32, n);
            if (got <= 0) break;
            int values = got * ctx->channels;
            for (int i = 0; i < values; ++i) ctx->workerS16[i] = GTPFFloatToS16(ctx->workerOutF32[i]);
            GTRingWrite(&ctx->outputRing, ctx->workerS16, got);
            didWork = YES;
        }

        // Do not consume more source if processed output is backed up.
        if (GTRingFree(&ctx->outputRing) >= ctx->workerChunkFrames / 2) {
            int n = GTRingRead(&ctx->sourceRing, ctx->workerS16, ctx->workerChunkFrames);
            if (n > 0) {
                int values = n * ctx->channels;
                for (int i = 0; i < values; ++i) ctx->workerInF32[i] = (float)ctx->workerS16[i] / 32768.0f;
                ctx->scaleTempo->push(ctx->workerInF32, n);
                didWork = YES;
                // Drain immediately after every push.
                while (ctx->scaleTempo->availableFrames() > 0 && GTRingFree(&ctx->outputRing) > 0) {
                    int m = ctx->scaleTempo->availableFrames();
                    if (m > ctx->workerChunkFrames) m = ctx->workerChunkFrames;
                    int freeFrames = GTRingFree(&ctx->outputRing);
                    if (m > freeFrames) m = freeFrames;
                    if (m <= 0) break;
                    int got = ctx->scaleTempo->read(ctx->workerOutF32, m);
                    if (got <= 0) break;
                    int vals = got * ctx->channels;
                    for (int i = 0; i < vals; ++i) ctx->workerS16[i] = GTPFFloatToS16(ctx->workerOutF32[i]);
                    GTRingWrite(&ctx->outputRing, ctx->workerS16, got);
                }
            }
        }

        if (!didWork) usleep(250);
    }
    return NULL;
}

static BOOL GTPFEnsureCallbackScratch(GTPFContext *ctx, int frames) {
    if (!ctx || frames <= 0) return NO;
    if (ctx->callbackScratch && ctx->callbackScratchFrames >= frames) return YES;
    // This is only a rare safety fallback. Normal callback size is preallocated at init.
    int16_t *p = (int16_t *)realloc(ctx->callbackScratch,
        (size_t)frames * (size_t)ctx->channels * sizeof(int16_t));
    if (!p) return NO;
    ctx->callbackScratch = p;
    ctx->callbackScratchFrames = frames;
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

    if (ctx->frameBytes <= 0 || (len % ctx->frameBytes) != 0) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        return;
    }
    int outputFrames = len / ctx->frameBytes;
    if (outputFrames <= 0) {
        memset(stream, 0, (size_t)len);
        return;
    }

    uint32_t e = __atomic_load_n(&ctx->epoch, __ATOMIC_ACQUIRE);
    if (ctx->audioEpochSeen != e) {
        ctx->audioEpochSeen = e;
        ctx->sourceDemandFrames = 0.0;
        ctx->sourcePulledFrames = 0.0;
        ctx->transitionPending = 1;
    }

    // Exact 1x bypass. The worker never calls originalCallback, so returning to 1x
    // cannot race the source callback or leave DSP code in the hardware callback.
    if (fabsf(speed - 1.0f) < 0.0001f || !ctx->workerStarted) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        int16_t *dst = (int16_t *)stream;
        GTPFApplyTransitionFade(ctx, dst, outputFrames);
        GTPFRememberTail(ctx, dst, outputFrames);
        return;
    }

    if (!GTPFEnsureCallbackScratch(ctx, outputFrames)) {
        ctx->originalCallback(ctx->originalUserdata, stream, len);
        return;
    }

    // Wait briefly for the worker to acknowledge a rate-path reset. During normal
    // steady state this loop is skipped completely.
    int ackSpins = 0;
    while (__atomic_load_n(&ctx->workerEpoch, __ATOMIC_ACQUIRE) != e && ackSpins++ < 20) usleep(100);
    if (__atomic_load_n(&ctx->workerEpoch, __ATOMIC_ACQUIRE) != e) {
        int16_t *dst = (int16_t *)stream;
        memset(dst, 0, (size_t)len);
        GTPFFillMissingSmooth(ctx, dst, 0, outputFrames);
        GTPFRememberTail(ctx, dst, outputFrames);
        return;
    }

    // Desired source consumption follows speed * hardware output, plus a small fixed
    // look-ahead: VLC scaletempo's ~50 ms queue plus one hardware callback. This is
    // enough to absorb its 30 ms stride granularity without an ever-growing prefetch.
    ctx->sourceDemandFrames += (double)speed * (double)outputFrames;
    double lookAhead = (double)(ctx->sampleRate / 20 + outputFrames); // ~50 ms + 1 callback
    double desiredPulled = ctx->sourceDemandFrames + lookAhead;

    int pulls = 0;
    const int maxPullsPerCallback = 16;
    while (ctx->sourcePulledFrames + 0.5 < desiredPulled && pulls < maxPullsPerCallback) {
        // Never consume source that cannot be enqueued: dropping already-consumed PCM
        // would itself create a discontinuity.
        if (GTRingFree(&ctx->sourceRing) < outputFrames) break;
        ctx->originalCallback(ctx->originalUserdata, (GTUint8 *)ctx->callbackScratch, len);
        int written = GTRingWrite(&ctx->sourceRing, ctx->callbackScratch, outputFrames);
        if (written != outputFrames) break;
        ctx->sourcePulledFrames += (double)outputFrames;
        pulls++;
    }

    // Give the worker a very small scheduling window. The expensive cross-correlation
    // no longer executes here; this wait only lets already-fed work finish.
    int waitSpins = 0;
    while (GTRingAvailable(&ctx->outputRing) < outputFrames && waitSpins++ < 24) usleep(100); // <=2.4 ms

    int16_t *dst = (int16_t *)stream;
    int got = GTRingRead(&ctx->outputRing, dst, outputFrames);
    if (got < outputFrames) GTPFFillMissingSmooth(ctx, dst, got, outputFrames);
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
    ctx->nominalCallbackFrames = spec->samples > 0 ? (int)spec->samples : 4096;
    if (spec->size > 0 && ctx->frameBytes > 0) {
        int f = (int)(spec->size / (GTUint32)ctx->frameBytes);
        if (f > ctx->nominalCallbackFrames) ctx->nominalCallbackFrames = f;
    }
    if (ctx->nominalCallbackFrames < 1024) ctx->nominalCallbackFrames = 1024;
    if (ctx->nominalCallbackFrames > 16384) ctx->nominalCallbackFrames = 16384;

    ctx->requestedSpeed = 1.0f;
    ctx->epoch = 1;
    ctx->workerEpoch = 0;
    ctx->audioEpochSeen = 0;
    ctx->transitionPending = 0;

    ctx->scaleTempo = new (std::nothrow) GTScaleTempo(ctx->sampleRate, ctx->channels);
    if (!ctx->scaleTempo || !ctx->scaleTempo->valid()) {
        delete ctx->scaleTempo; free(ctx);
        return orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, spec) : nil;
    }

    // Generous fixed rings; normal look-ahead is only ~50-100 ms.
    int sourceCap = ctx->sampleRate * 2;
    int outputCap = ctx->sampleRate;
    if (!GTRingInit(&ctx->sourceRing, sourceCap, ctx->channels) ||
        !GTRingInit(&ctx->outputRing, outputCap, ctx->channels)) {
        GTRingDestroy(&ctx->sourceRing); GTRingDestroy(&ctx->outputRing);
        delete ctx->scaleTempo; free(ctx);
        return orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, spec) : nil;
    }

    ctx->callbackScratchFrames = ctx->nominalCallbackFrames;
    ctx->callbackScratch = (int16_t *)malloc((size_t)ctx->callbackScratchFrames * (size_t)ctx->channels * sizeof(int16_t));
    ctx->workerChunkFrames = 4096;
    ctx->workerS16 = (int16_t *)malloc((size_t)ctx->workerChunkFrames * (size_t)ctx->channels * sizeof(int16_t));
    ctx->workerInF32 = (float *)malloc((size_t)ctx->workerChunkFrames * (size_t)ctx->channels * sizeof(float));
    ctx->workerOutF32 = (float *)malloc((size_t)ctx->workerChunkFrames * (size_t)ctx->channels * sizeof(float));
    if (!ctx->callbackScratch || !ctx->workerS16 || !ctx->workerInF32 || !ctx->workerOutF32) {
        free(ctx->callbackScratch); free(ctx->workerS16); free(ctx->workerInF32); free(ctx->workerOutF32);
        GTRingDestroy(&ctx->sourceRing); GTRingDestroy(&ctx->outputRing);
        delete ctx->scaleTempo; free(ctx);
        return orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, spec) : nil;
    }

    GTSDL_AudioSpec modified = *spec;
    modified.callback = GTPFPCMCallback;
    modified.userdata = ctx;
    id result = orig_initWithAudioSpec ? orig_initWithAudioSpec(self, _cmd, &modified) : nil;
    if (!result) {
        free(ctx->callbackScratch); free(ctx->workerS16); free(ctx->workerInF32); free(ctx->workerOutF32);
        GTRingDestroy(&ctx->sourceRing); GTRingDestroy(&ctx->outputRing);
        delete ctx->scaleTempo; free(ctx);
        return nil;
    }

    objc_setAssociatedObject(result, kGTPFContextKey, [NSValue valueWithPointer:ctx], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (pthread_create(&ctx->workerThread, NULL, GTPFWorkerMain, ctx) == 0) {
        ctx->workerStarted = 1;
    } else {
        // Fail-safe: 1x remains exact bypass, and rate setter below will hand the
        // real rate back to Apple's original AudioQueue path if no worker exists.
        ctx->workerStarted = 0;
    }
    return result;
}

static void hook_setPlaybackRate(id self, SEL _cmd, float rate) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (!ctx) {
        if (orig_setPlaybackRate) orig_setPlaybackRate(self, _cmd, rate);
        return;
    }

    float sane = rate;
    if (!isfinite(sane) || sane < 0.25f || sane > 6.0f) sane = 1.0f;
    float old = ctx->requestedSpeed;
    BOOL changed = fabsf(old - sane) > 0.0001f;
    BOOL oldOne = fabsf(old - 1.0f) < 0.0001f;
    BOOL newOne = fabsf(sane - 1.0f) < 0.0001f;
    ctx->requestedSpeed = sane;
    if (changed) {
        ctx->transitionPending = 1;
        // Reset rings/DSP only when crossing the exact-1x bypass boundary.
        // Non-1x -> non-1x changes retain the audio history and only update speed.
        if (oldOne != newOne) __atomic_add_fetch(&ctx->epoch, 1u, __ATOMIC_ACQ_REL);
    }

    if (orig_setPlaybackRate) {
        if (ctx->workerStarted) orig_setPlaybackRate(self, _cmd, 1.0f);
        else orig_setPlaybackRate(self, _cmd, sane);
    }
}

static void hook_flush(id self, SEL _cmd) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (ctx) {
        ctx->transitionPending = 1;
        __atomic_add_fetch(&ctx->epoch, 1u, __ATOMIC_ACQ_REL);
    }
    if (orig_flush) orig_flush(self, _cmd);
}

static void hook_stop(id self, SEL _cmd) {
    GTPFContext *ctx = GTPFGetContext(self);
    if (ctx) {
        // Same conservative lifecycle policy as the earlier stable prototypes:
        // do not free context memory while AudioQueue callbacks may be unwinding.
        ctx->stopped = 1;
        ctx->workerExit = 1;
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
