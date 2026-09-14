#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// First test build: use Spectral, Apple's highest-quality time/pitch algorithm.
// If spoken voice sounds metallic/robotic, change this one line to:
// AVAudioTimePitchAlgorithmTimeDomain
static AVAudioTimePitchAlgorithm const GTTargetAlgorithm = AVAudioTimePitchAlgorithmSpectral;

static inline BOOL GTIsLowQuality(AVAudioTimePitchAlgorithm algorithm) {
    return algorithm == nil || [algorithm isEqualToString:AVAudioTimePitchAlgorithmLowQualityZeroLatency];
}

static inline void GTUpgradePlayerItem(AVPlayerItem *item) {
    if (!item) return;
    @try {
        AVAudioTimePitchAlgorithm current = item.audioTimePitchAlgorithm;
        if (GTIsLowQuality(current)) {
            item.audioTimePitchAlgorithm = GTTargetAlgorithm;
        }
    } @catch (__unused NSException *e) {
        // Fail open: playback should continue normally if AVFoundation rejects a change.
    }
}

%hook AVPlayerItem

- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm {
    // Preserve an app's explicit TimeDomain/Spectral/Varispeed choice.
    // Only replace the old iOS low-quality/default path.
    if (GTIsLowQuality(algorithm)) {
        %orig(GTTargetAlgorithm);
    } else {
        %orig(algorithm);
    }
}

%end

%hook AVPlayer

- (void)setRate:(float)rate {
    if (rate != 0.0f && rate != 1.0f) {
        GTUpgradePlayerItem(self.currentItem);
    }
    %orig(rate);
}

- (void)playImmediatelyAtRate:(float)rate {
    if (rate != 0.0f && rate != 1.0f) {
        GTUpgradePlayerItem(self.currentItem);
    }
    %orig(rate);
}

- (void)setRate:(float)rate time:(CMTime)itemTime atHostTime:(CMTime)hostClockTime {
    if (rate != 0.0f && rate != 1.0f) {
        GTUpgradePlayerItem(self.currentItem);
    }
    %orig(rate, itemTime, hostClockTime);
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    GTUpgradePlayerItem(item);
    %orig(item);
}

%end

// WebKit / MediaSource-style playback may use AVSampleBufferAudioRenderer
// instead of a normal AVPlayerItem. iOS defaults this class to the same
// LowQualityZeroLatency algorithm, so upgrade it at creation time as well.
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
    if (GTIsLowQuality(algorithm)) {
        %orig(GTTargetAlgorithm);
    } else {
        %orig(algorithm);
    }
}

%end
