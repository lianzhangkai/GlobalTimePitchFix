#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

// 0.2.5 INJECTION PROBE ONLY.
// This build does NOT change playback rate or audio quality.
// It only proves whether libhooker actually loads this dylib into:
//   1) Safari main process
//   2) Safari WebKit WebContent process
//   3) Bilibili main process

static NSString * const GTWebContentNotification = @"com.chatgpt.globaltimepitchfix.webcontent-loaded";
static BOOL GTDidShowWebAlert = NO;

static void GTShowAlertLater(NSString *message, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            UIAlertView *alert = [[UIAlertView alloc]
                initWithTitle:@"GTPF Injection Probe"
                message:message
                delegate:nil
                cancelButtonTitle:@"OK"
                otherButtonTitles:nil];
            [alert show];
        } @catch (__unused NSException *e) {
        }
    });
}

static void GTDarwinCallback(CFNotificationCenterRef center,
                             void *observer,
                             CFStringRef name,
                             const void *object,
                             CFDictionaryRef userInfo) {
    if (GTDidShowWebAlert) return;
    GTDidShowWebAlert = YES;
    GTShowAlertLater(@"Safari WebContent 已成功加载 GlobalTimePitchFix。", 0.2);
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";

        if ([bundleID isEqualToString:@"com.apple.mobilesafari"]) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL,
                                            GTDarwinCallback,
                                            (__bridge CFStringRef)GTWebContentNotification,
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
            GTShowAlertLater(@"Safari 主进程已成功加载 GlobalTimePitchFix。\n\n点 OK 后打开/刷新一个网页；如果 WebContent 也成功注入，会再弹一次提示。", 2.0);
        }
        else if ([bundleID isEqualToString:@"com.apple.WebKit.WebContent"]) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 (__bridge CFStringRef)GTWebContentNotification,
                                                 NULL,
                                                 NULL,
                                                 true);
        }
        else if ([bundleID isEqualToString:@"tv.danmaku.bilianime"]) {
            GTShowAlertLater(@"哔哩哔哩主进程已成功加载 GlobalTimePitchFix。", 2.0);
        }
    }
}
