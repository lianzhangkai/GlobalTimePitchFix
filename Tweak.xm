#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <math.h>

// 0.3.0 AUDIO PATH PROBE ONLY.
// This build deliberately DOES NOT change playback rate, pitch, or audio quality.
// It reports which public playback/time-pitch APIs are actually hit when the user
// changes speed in Safari/WebKit or Bilibili.

static NSString * const GTEventPrefix = @"com.chatgpt.globaltimepitchfix.event.";
static NSMutableSet<NSString *> *GTReportedEvents;

static BOOL GTIsSafariMain(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] ?: @"" isEqualToString:@"com.apple.mobilesafari"];
}

static BOOL GTIsWebContent(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] ?: @"" isEqualToString:@"com.apple.WebKit.WebContent"];
}

static BOOL GTIsBilibili(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] ?: @"" isEqualToString:@"tv.danmaku.bilianime"];
}

static UIViewController *GTTopViewController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController) return GTTopViewController(controller.presentedViewController);
    if ([controller isKindOfClass:[UINavigationController class]]) {
        UIViewController *v = [(UINavigationController *)controller visibleViewController];
        return GTTopViewController(v ?: controller);
    }
    if ([controller isKindOfClass:[UITabBarController class]]) {
        UIViewController *v = [(UITabBarController *)controller selectedViewController];
        return GTTopViewController(v ?: controller);
    }
    return controller;
}

static UIWindow *GTKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *w in app.windows) if (w.isKeyWindow) return w;
    return app.windows.firstObject;
}

static void GTPresentMessage(NSString *message, NSUInteger retriesLeft) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = GTKeyWindow();
        UIViewController *presenter = GTTopViewController(window.rootViewController);
        if (!presenter || !presenter.view.window) {
            if (retriesLeft > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    GTPresentMessage(message, retriesLeft - 1);
                });
            }
            return;
        }

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"GTPF Audio Path Probe"
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                               style:UIAlertActionStyleDefault
                                             handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static NSString *GTAlgorithmLabel(AVAudioTimePitchAlgorithm algorithm) {
    if (!algorithm) return @"(nil/default)";
    if ([algorithm isEqualToString:AVAudioTimePitchAlgorithmLowQualityZeroLatency]) return @"LowQualityZeroLatency";
    if ([algorithm isEqualToString:AVAudioTimePitchAlgorithmTimeDomain]) return @"TimeDomain";
    if ([algorithm isEqualToString:AVAudioTimePitchAlgorithmSpectral]) return @"Spectral";
    if ([algorithm isEqualToString:AVAudioTimePitchAlgorithmVarispeed]) return @"Varispeed";
    return [algorithm description];
}

static NSString *GTSanitizeEvent(NSString *event) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."];
    NSArray<NSString *> *parts = [event componentsSeparatedByCharactersInSet:[allowed invertedSet]];
    return [parts componentsJoinedByString:@"_"];
}

static void GTMarkAndShowLocal(NSString *event, NSString *details) {
    if (!event) return;
    @synchronized (GTReportedEvents) {
        if ([GTReportedEvents containsObject:event]) return;
        [GTReportedEvents addObject:event];
    }
    NSString *msg = details.length ? [NSString stringWithFormat:@"命中：%@\n%@", event, details]
                                   : [NSString stringWithFormat:@"命中：%@", event];
    GTPresentMessage(msg, 8);
}

static void GTPostToSafariMain(NSString *event) {
    NSString *safe = GTSanitizeEvent(event);
    NSString *name = [GTEventPrefix stringByAppendingString:safe];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name,
                                         NULL, NULL, true);
}

static void GTReport(NSString *event, NSString *details) {
    if (GTIsWebContent()) {
        // Darwin notifications cannot carry userInfo, so put only the event key in the name.
        GTPostToSafariMain(event);
        return;
    }
    if (GTIsSafariMain() || GTIsBilibili()) {
        GTMarkAndShowLocal(event, details ?: @"");
    }
}

static void GTDarwinEventCallback(__unused CFNotificationCenterRef center,
                                  __unused void *observer,
                                  CFStringRef name,
                                  __unused const void *object,
                                  __unused CFDictionaryRef userInfo) {
    NSString *full = (__bridge NSString *)name;
    if (![full hasPrefix:GTEventPrefix]) return;
    NSString *event = [full substringFromIndex:GTEventPrefix.length];
    GTMarkAndShowLocal([@"WebContent → " stringByAppendingString:event], @"");
}

static void GTRegisterSafariEventObservers(void) {
    NSArray<NSString *> *events = @[
        @"AVPlayer_setRate",
        @"AVPlayer_playImmediatelyAtRate",
        @"AVPlayer_setRate_time_atHostTime",
        @"AVPlayerItem_setAudioTimePitchAlgorithm",
        @"AVSampleBufferAudioRenderer_setAudioTimePitchAlgorithm",
        @"AVAudioUnitTimePitch_setRate",
        @"AVAudioUnitVarispeed_setRate",
        @"AudioQueue_PlayRate",
        @"AudioQueue_Pitch",
        @"AudioUnit_NewTimePitch_Rate",
        @"AudioUnit_Varispeed_Rate"
    ];
    for (NSString *event in events) {
        NSString *name = [GTEventPrefix stringByAppendingString:event];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        GTDarwinEventCallback,
                                        (__bridge CFStringRef)name,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

%hook AVPlayer

- (void)setRate:(float)rate {
    if (rate > 1.01f || (rate > 0.0f && rate < 0.99f)) {
        NSString *alg = @"";
        @try { alg = GTAlgorithmLabel(self.currentItem.audioTimePitchAlgorithm); } @catch (__unused NSException *e) {}
        GTReport(@"AVPlayer_setRate", [NSString stringWithFormat:@"rate=%.3f, currentItem algorithm=%@", rate, alg]);
    }
    %orig(rate);
}

- (void)playImmediatelyAtRate:(float)rate {
    if (rate > 1.01f || (rate > 0.0f && rate < 0.99f)) {
        NSString *alg = @"";
        @try { alg = GTAlgorithmLabel(self.currentItem.audioTimePitchAlgorithm); } @catch (__unused NSException *e) {}
        GTReport(@"AVPlayer_playImmediatelyAtRate", [NSString stringWithFormat:@"rate=%.3f, currentItem algorithm=%@", rate, alg]);
    }
    %orig(rate);
}

- (void)setRate:(float)rate time:(CMTime)itemTime atHostTime:(CMTime)hostClockTime {
    if (rate > 1.01f || (rate > 0.0f && rate < 0.99f)) {
        GTReport(@"AVPlayer_setRate_time_atHostTime", [NSString stringWithFormat:@"rate=%.3f", rate]);
    }
    %orig(rate, itemTime, hostClockTime);
}

%end

%hook AVPlayerItem

- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm {
    GTReport(@"AVPlayerItem_setAudioTimePitchAlgorithm", GTAlgorithmLabel(algorithm));
    %orig(algorithm);
}

%end

%hook AVSampleBufferAudioRenderer

- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm {
    GTReport(@"AVSampleBufferAudioRenderer_setAudioTimePitchAlgorithm", GTAlgorithmLabel(algorithm));
    %orig(algorithm);
}

%end

%hook AVAudioUnitTimePitch

- (void)setRate:(float)rate {
    if (rate > 1.01f || (rate > 0.0f && rate < 0.99f)) {
        GTReport(@"AVAudioUnitTimePitch_setRate", [NSString stringWithFormat:@"rate=%.3f", rate]);
    }
    %orig(rate);
}

%end

%hook AVAudioUnitVarispeed

- (void)setRate:(float)rate {
    if (rate > 1.01f || (rate > 0.0f && rate < 0.99f)) {
        GTReport(@"AVAudioUnitVarispeed_setRate", [NSString stringWithFormat:@"rate=%.3f", rate]);
    }
    %orig(rate);
}

%end

%hookf(OSStatus, AudioQueueSetParameter,
       AudioQueueRef inAQ,
       AudioQueueParameterID inParamID,
       AudioQueueParameterValue inValue) {
    if (inParamID == kAudioQueueParam_PlayRate && (inValue > 1.01f || (inValue > 0.0f && inValue < 0.99f))) {
        GTReport(@"AudioQueue_PlayRate", [NSString stringWithFormat:@"rate=%.3f", (double)inValue]);
    } else if (inParamID == kAudioQueueParam_Pitch && fabs((double)inValue) > 0.01) {
        GTReport(@"AudioQueue_Pitch", [NSString stringWithFormat:@"cents=%.1f", (double)inValue]);
    }
    return %orig;
}

%hookf(OSStatus, AudioUnitSetParameter,
       AudioUnit inUnit,
       AudioUnitParameterID inID,
       AudioUnitScope inScope,
       AudioUnitElement inElement,
       AudioUnitParameterValue inValue,
       UInt32 inBufferOffsetInFrames) {
    AudioComponent component = AudioComponentInstanceGetComponent(inUnit);
    AudioComponentDescription desc = {0};
    if (component && AudioComponentGetDescription(component, &desc) == noErr) {
        BOOL changedRate = (inValue > 1.01f || (inValue > 0.0f && inValue < 0.99f));
        if (changedRate && desc.componentSubType == kAudioUnitSubType_NewTimePitch && inID == kNewTimePitchParam_Rate) {
            GTReport(@"AudioUnit_NewTimePitch_Rate", [NSString stringWithFormat:@"rate=%.3f", (double)inValue]);
        } else if (changedRate && desc.componentSubType == kAudioUnitSubType_Varispeed && inID == kVarispeedParam_PlaybackRate) {
            GTReport(@"AudioUnit_Varispeed_Rate", [NSString stringWithFormat:@"rate=%.3f", (double)inValue]);
        }
    }
    return %orig;
}

%ctor {
    @autoreleasepool {
        GTReportedEvents = [NSMutableSet set];
        if (GTIsSafariMain()) {
            GTRegisterSafariEventObservers();
            GTPresentMessage(@"0.3 Audio Path Probe 已加载。\n\n请打开视频，先播放 1×，再切到 2×。有命中的路径会弹窗。", 8);
        } else if (GTIsWebContent()) {
            // No startup popup in WebContent. Events are forwarded to Safari main process.
        } else if (GTIsBilibili()) {
            GTPresentMessage(@"0.3 Audio Path Probe 已加载。\n\n请播放视频，先 1×，再切到 2×。有命中的路径会弹窗。", 8);
        }
    }
}
