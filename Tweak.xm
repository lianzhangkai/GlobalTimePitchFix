#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// 0.2.0 DIAGNOSTIC BUILD ONLY.
// Force Varispeed so successful hooking is unmistakable:
// at 2x playback, voices should become much higher-pitched ("chipmunk" effect).
static AVAudioTimePitchAlgorithm const GTTargetAlgorithm = AVAudioTimePitchAlgorithmVarispeed;

static inline void GTForcePlayerItem(AVPlayerItem *item) {
    if (!item) return;
    @try {
        item.audioTimePitchAlgorithm = GTTargetAlgorithm;
    } @catch (__unused NSException *e) {
        // Fail open: never break playback just because the property rejects a change.
    }
}

%hook AVPlayerItem

- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm {
    // Diagnostic build: ignore the requested algorithm and always force Varispeed.
    %orig(GTTargetAlgorithm);
}

%end

%hook AVPlayer

- (void)setRate:(float)rate {
    if (rate != 0.0f && rate != 1.0f) {
        GTForcePlayerItem(self.currentItem);
    }
    %orig(rate);
}

- (void)playImmediatelyAtRate:(float)rate {
    if (rate != 0.0f && rate != 1.0f) {
        GTForcePlayerItem(self.currentItem);
    }
    %orig(rate);
}

- (void)setRate:(float)rate time:(CMTime)itemTime atHostTime:(CMTime)hostClockTime {
    if (rate != 0.0f && rate != 1.0f) {
        GTForcePlayerItem(self.currentItem);
    }
    %orig(rate, itemTime, hostClockTime);
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    GTForcePlayerItem(item);
    %orig(item);
}

%end

// Some WebKit/MediaSource paths use AVSampleBufferAudioRenderer.
%hook AVSampleBufferAudioRenderer

- (instancetype)init {
    id obj = %orig;
    if (obj) {
        @try {
            [obj setAudioTimePitchAlgorithm:GTTargetAlgorithm];
        } @catch (__unused NSException *e) {
        }
    }
    return obj;
}

- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm {
    // Diagnostic build: always force Varispeed.
    %orig(GTTargetAlgorithm);
}

%end
