#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// 0.3.2 SAFE AUDIO PATH PROBE ONLY.
// Removes low-level AudioQueue/AudioUnit C-function hooks because some apps (notably
// older Bilibili builds) may call them on real-time audio threads and can crash when
// a probe allocates Objective-C objects there.
// This build does NOT change playback rate, pitch, or audio quality.

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
                               dispatch_get_main_queue(), ^{ GTPresentMessage(message, retriesLeft - 1); });
            }
            return;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"GTPF Safe Probe"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static NSString *GTAlgorithmLabel(AVAudioTimePitchAlgorithm algorithm) {
    if (!algorithm) return @"DefaultNil";
    if ([algorithm isEqualToString:AVAudioTimePitchAlgorithmLowQualityZeroLatency]) return @"LowQualityZeroLatency";
    if ([algorithm isEqualToString:AVAudioTimePitchAlgorithmTimeDomain]) return @"TimeDomain";
    if ([algorithm isEqualToString:AVAudioTimePitchAlgorithmSpectral]) return @"Spectral";
    if ([algorithm isEqualToString:AVAudioTimePitchAlgorithmVarispeed]) return @"Varispeed";
    return @"Other";
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
                                         (__bridge CFStringRef)name, NULL, NULL, true);
}

static void GTReport(NSString *event, NSString *details) {
    if (GTIsWebContent()) {
        // Encode the small amount of useful detail into the event name because
        // Darwin notifications cannot carry userInfo across processes.
        NSString *combined = details.length ? [NSString stringWithFormat:@"%@__%@", event, details] : event;
        GTPostToSafariMain(combined);
        return;
    }
    if (GTIsSafariMain() || GTIsBilibili()) GTMarkAndShowLocal(event, details ?: @"");
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
    NSMutableArray<NSString *> *events = [NSMutableArray arrayWithArray:@[
        @"AVPlayer_setRate",
        @"AVPlayer_playImmediatelyAtRate",
        @"AVPlayer_setRate_time_atHostTime"
    ]];
    NSArray<NSString *> *algorithms = @[@"DefaultNil", @"LowQualityZeroLatency", @"TimeDomain", @"Spectral", @"Varispeed", @"Other"];
    for (NSString *alg in algorithms) {
        [events addObject:[NSString stringWithFormat:@"AVPlayerItem_setAudioTimePitchAlgorithm__%@", alg]];
        [events addObject:[NSString stringWithFormat:@"AVSampleBufferAudioRenderer_setAudioTimePitchAlgorithm__%@", alg]];
    }
    for (NSString *event in events) {
        NSString *name = [GTEventPrefix stringByAppendingString:event];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        GTDarwinEventCallback, (__bridge CFStringRef)name, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

%hook AVPlayer
- (void)setRate:(float)rate {
    if (rate > 1.01f || (rate > 0.0f && rate < 0.99f))
        GTReport(@"AVPlayer_setRate", [NSString stringWithFormat:@"rate=%.3f", rate]);
    %orig(rate);
}
- (void)playImmediatelyAtRate:(float)rate {
    if (rate > 1.01f || (rate > 0.0f && rate < 0.99f))
        GTReport(@"AVPlayer_playImmediatelyAtRate", [NSString stringWithFormat:@"rate=%.3f", rate]);
    %orig(rate);
}
- (void)setRate:(float)rate time:(CMTime)itemTime atHostTime:(CMTime)hostClockTime {
    if (rate > 1.01f || (rate > 0.0f && rate < 0.99f))
        GTReport(@"AVPlayer_setRate_time_atHostTime", [NSString stringWithFormat:@"rate=%.3f", rate]);
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

%ctor {
    @autoreleasepool {
        GTReportedEvents = [NSMutableSet set];
        if (GTIsSafariMain()) {
            GTRegisterSafariEventObservers();
            GTPresentMessage(@"0.3.2 Safe Probe 已加载。\n\n请打开视频，先 1×，再切 2×。", 8);
        } else if (GTIsBilibili()) {
            GTPresentMessage(@"0.3.2 Safe Probe 已加载。\n\n已移除可能导致旧版 B站闪退的低层 AudioUnit/AudioQueue 探针。", 8);
        }
    }
}
