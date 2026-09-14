#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

// 0.2.6 INJECTION PROBE ONLY.
// This build does NOT change playback rate or audio quality.
// It only proves whether libhooker actually loads this dylib into:
//   1) Safari main process
//   2) Safari WebKit WebContent process
//   3) Bilibili main process
//
// Uses UIAlertController (not deprecated UIAlertView) so the build remains
// clean with Theos' -Werror setting against the iOS 13.7 SDK.

static NSString * const GTWebContentNotification = @"com.chatgpt.globaltimepitchfix.webcontent-loaded";
static BOOL GTDidShowWebAlert = NO;

static UIViewController *GTTopViewController(UIViewController *controller) {
    if (!controller) return nil;

    UIViewController *presented = controller.presentedViewController;
    if (presented) {
        return GTTopViewController(presented);
    }

    if ([controller isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = [(UINavigationController *)controller visibleViewController];
        return GTTopViewController(visible ?: controller);
    }

    if ([controller isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = [(UITabBarController *)controller selectedViewController];
        return GTTopViewController(selected ?: controller);
    }

    return controller;
}

static UIWindow *GTKeyWindow(void) {
    UIApplication *application = [UIApplication sharedApplication];
    for (UIWindow *window in application.windows) {
        if (window.isKeyWindow) return window;
    }
    return application.windows.firstObject;
}

static void GTPresentAlert(NSString *message, NSUInteger retriesLeft) {
    UIWindow *window = GTKeyWindow();
    UIViewController *presenter = GTTopViewController(window.rootViewController);

    if (!presenter || !presenter.view.window) {
        if (retriesLeft > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                GTPresentAlert(message, retriesLeft - 1);
            });
        }
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"GTPF Injection Probe"
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void GTShowAlertLater(NSString *message, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            GTPresentAlert(message, 10);
        } @catch (__unused NSException *exception) {
        }
    });
}

static void GTDarwinCallback(__unused CFNotificationCenterRef center,
                             __unused void *observer,
                             __unused CFStringRef name,
                             __unused const void *object,
                             __unused CFDictionaryRef userInfo) {
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
