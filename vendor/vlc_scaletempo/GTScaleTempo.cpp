/*
 * Minimal standalone adaptation of VLC 3.0.x modules/audio_filter/scaletempo.c
 * for an experimental iOS playback-speed tweak.
 *
 * Original VLC scaletempo copyright (c) 2008 VLC authors / VideoLAN.
 * This adaptation is distributed under LGPL-2.1-or-later. See LICENSE-LGPL-2.1.txt.
 *
 * Algorithm defaults intentionally match VLC 3.0.x scaletempo:
 *   stride: 30 ms
 *   overlap: 20%
 *   search: 14 ms
 */

#include "GTScaleTempo.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static inline int gt_maxi(int a, int b) { return a > b ? a : b; }
static inline int gt_mini(int a, int b) { return a < b ? a : b; }

GTScaleTempo::GTScaleTempo(int sampleRate, int channels)
    : sampleRate_(sampleRate), channels_(channels), speed_(1.0f),
      strideFrames_(0), overlapFrames_(0), standingFrames_(0), searchFrames_(0), queueMaxFrames_(0),
      input_(0), inputFrames_(0), inputCapacityFrames_(0), skipFrames_(0),
      overlap_(0), output_(0), outputFrames_(0), outputReadFrame_(0), outputCapacityFrames_(0),
      consumeError_(0.0), valid_(false) {
    if (sampleRate_ < 8000 || sampleRate_ > 192000 || channels_ < 1 || channels_ > 2) return;

    strideFrames_ = gt_maxi(1, (int)floor((30.0 * sampleRate_) / 1000.0));
    overlapFrames_ = gt_maxi(1, (int)floor(strideFrames_ * 0.20));
    if (overlapFrames_ >= strideFrames_) overlapFrames_ = strideFrames_ - 1;
    standingFrames_ = strideFrames_ - overlapFrames_;
    searchFrames_ = gt_maxi(1, (int)floor((14.0 * sampleRate_) / 1000.0));
    queueMaxFrames_ = searchFrames_ + strideFrames_ + overlapFrames_;

    overlap_ = (float *)calloc((size_t)overlapFrames_ * (size_t)channels_, sizeof(float));
    if (!overlap_) return;

    // Enough for several source callbacks and several output strides without realloc in steady state.
    inputCapacityFrames_ = gt_maxi(queueMaxFrames_ * 4, 8192);
    input_ = (float *)malloc((size_t)inputCapacityFrames_ * (size_t)channels_ * sizeof(float));
    if (!input_) return;

    outputCapacityFrames_ = gt_maxi(strideFrames_ * 8, 8192);
    output_ = (float *)malloc((size_t)outputCapacityFrames_ * (size_t)channels_ * sizeof(float));
    if (!output_) return;

    valid_ = true;
}

GTScaleTempo::~GTScaleTempo() {
    free(input_);
    free(overlap_);
    free(output_);
}

bool GTScaleTempo::valid() const { return valid_; }
float GTScaleTempo::speed() const { return speed_; }

void GTScaleTempo::reset() {
    inputFrames_ = 0;
    skipFrames_ = 0;
    outputFrames_ = 0;
    outputReadFrame_ = 0;
    consumeError_ = 0.0;
    if (overlap_) memset(overlap_, 0, (size_t)overlapFrames_ * (size_t)channels_ * sizeof(float));
}

void GTScaleTempo::setSpeed(float speed) {
    if (!isfinite(speed) || speed < 0.25f || speed > 6.0f) speed = 1.0f;
    speed_ = speed;
}

bool GTScaleTempo::ensureInputCapacity(int framesNeeded) {
    if (framesNeeded <= inputCapacityFrames_) return true;
    int newCap = inputCapacityFrames_ > 0 ? inputCapacityFrames_ : queueMaxFrames_;
    while (newCap < framesNeeded) newCap *= 2;
    float *p = (float *)realloc(input_, (size_t)newCap * (size_t)channels_ * sizeof(float));
    if (!p) return false;
    input_ = p;
    inputCapacityFrames_ = newCap;
    return true;
}

void GTScaleTempo::compactOutput() {
    if (outputReadFrame_ <= 0) return;
    int avail = outputFrames_ - outputReadFrame_;
    if (avail > 0) {
        memmove(output_,
                output_ + (size_t)outputReadFrame_ * (size_t)channels_,
                (size_t)avail * (size_t)channels_ * sizeof(float));
    }
    outputFrames_ = avail;
    outputReadFrame_ = 0;
}

bool GTScaleTempo::ensureOutputCapacity(int additionalFrames) {
    int availTail = outputCapacityFrames_ - outputFrames_;
    if (availTail >= additionalFrames) return true;
    compactOutput();
    availTail = outputCapacityFrames_ - outputFrames_;
    if (availTail >= additionalFrames) return true;

    int needed = outputFrames_ + additionalFrames;
    int newCap = outputCapacityFrames_ > 0 ? outputCapacityFrames_ : strideFrames_ * 4;
    while (newCap < needed) newCap *= 2;
    float *p = (float *)realloc(output_, (size_t)newCap * (size_t)channels_ * sizeof(float));
    if (!p) return false;
    output_ = p;
    outputCapacityFrames_ = newCap;
    return true;
}

int GTScaleTempo::findBestOverlapOffset() const {
    if (!overlap_ || !input_ || overlapFrames_ <= 1 || searchFrames_ <= 1) return 0;

    double bestCorr = -1.0e300;
    int bestOff = 0;

    // Mirrors VLC's weighted cross-correlation idea. The first overlap frame is skipped,
    // matching the original implementation's channel-offset start.
    for (int off = 0; off < searchFrames_; ++off) {
        double corr = 0.0;
        for (int f = 1; f < overlapFrames_; ++f) {
            const double w = (double)f * (double)(overlapFrames_ - f);
            const float *po = overlap_ + (size_t)f * (size_t)channels_;
            const float *pi = input_ + (size_t)(off + f) * (size_t)channels_;
            for (int ch = 0; ch < channels_; ++ch) corr += (double)po[ch] * (double)pi[ch] * w;
        }
        if (corr > bestCorr) {
            bestCorr = corr;
            bestOff = off;
        }
    }
    return bestOff;
}

bool GTScaleTempo::processOneStride() {
    if (inputFrames_ < queueMaxFrames_) return false;
    if (!ensureOutputCapacity(strideFrames_)) return false;

    const int best = findBestOverlapOffset();
    float *dst = output_ + (size_t)outputFrames_ * (size_t)channels_;

    // Overlap-add previous tail with the selected input location.
    for (int f = 0; f < overlapFrames_; ++f) {
        const float blend = (float)f / (float)overlapFrames_;
        const float *prev = overlap_ + (size_t)f * (size_t)channels_;
        const float *cur = input_ + (size_t)(best + f) * (size_t)channels_;
        for (int ch = 0; ch < channels_; ++ch) {
            dst[(size_t)f * (size_t)channels_ + ch] = prev[ch] + blend * (cur[ch] - prev[ch]);
        }
    }

    // Copy the standing (non-overlapped) portion of the stride.
    const float *standing = input_ + (size_t)(best + overlapFrames_) * (size_t)channels_;
    memcpy(dst + (size_t)overlapFrames_ * (size_t)channels_,
           standing,
           (size_t)standingFrames_ * (size_t)channels_ * sizeof(float));

    // Save the next overlap tail exactly one stride after the selected start.
    const float *nextOverlap = input_ + (size_t)(best + strideFrames_) * (size_t)channels_;
    memcpy(overlap_, nextOverlap, (size_t)overlapFrames_ * (size_t)channels_ * sizeof(float));

    outputFrames_ += strideFrames_;

    // Constant output stride, input consumption scales with requested playback speed.
    double wanted = (double)strideFrames_ * (double)speed_ + consumeError_;
    int consumeFrames = (int)floor(wanted);
    consumeError_ = wanted - (double)consumeFrames;
    if (consumeFrames < 1) consumeFrames = 1;

    if (consumeFrames < inputFrames_) {
        int remain = inputFrames_ - consumeFrames;
        memmove(input_,
                input_ + (size_t)consumeFrames * (size_t)channels_,
                (size_t)remain * (size_t)channels_ * sizeof(float));
        inputFrames_ = remain;
    } else {
        skipFrames_ += consumeFrames - inputFrames_;
        inputFrames_ = 0;
    }
    return true;
}

void GTScaleTempo::processAvailable() {
    // Hard guard protects the audio callback from a logic bug causing an infinite loop.
    int guard = 0;
    while (inputFrames_ >= queueMaxFrames_ && guard++ < 128) {
        if (!processOneStride()) break;
    }
}

bool GTScaleTempo::push(const float *samples, int frames) {
    if (!valid_ || !samples || frames <= 0) return false;

    int start = 0;
    if (skipFrames_ > 0) {
        int drop = gt_mini(skipFrames_, frames);
        skipFrames_ -= drop;
        start += drop;
        frames -= drop;
    }
    if (frames <= 0) return true;

    if (!ensureInputCapacity(inputFrames_ + frames)) return false;
    memcpy(input_ + (size_t)inputFrames_ * (size_t)channels_,
           samples + (size_t)start * (size_t)channels_,
           (size_t)frames * (size_t)channels_ * sizeof(float));
    inputFrames_ += frames;
    processAvailable();
    return true;
}

int GTScaleTempo::availableFrames() const {
    return outputFrames_ - outputReadFrame_;
}

int GTScaleTempo::read(float *dst, int maxFrames) {
    if (!dst || maxFrames <= 0) return 0;
    int avail = availableFrames();
    int n = gt_mini(avail, maxFrames);
    if (n <= 0) return 0;
    memcpy(dst,
           output_ + (size_t)outputReadFrame_ * (size_t)channels_,
           (size_t)n * (size_t)channels_ * sizeof(float));
    outputReadFrame_ += n;
    if (outputReadFrame_ == outputFrames_) {
        outputReadFrame_ = 0;
        outputFrames_ = 0;
    }
    return n;
}
