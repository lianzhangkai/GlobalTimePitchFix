#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

// Bilibili-only probe. No AVFoundation hooks.
// Goal: detect whether this old Bilibili build uses ijkplayer's playbackRate path.

static NSMutableSet<NSString *> *GTShown;

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

static void GTPresentOnce(NSString *key, NSString *message) {
    if (!key || !message) return;
    @synchronized (GTShown) {
        if ([GTShown containsObject:key]) return;
        [GTShown addObject:key];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = GTKeyWindow();
        UIViewController *presenter = GTTopViewController(window.rootViewController);
        if (!presenter || !presenter.view.window) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"GTPF Bili IJK Probe"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

typedef void (*RateSetterIMP)(id, SEL, float);
static RateSetterIMP orig_IJKFF_setPlaybackRate = NULL;
static RateSetterIMP orig_IJKAV_setPlaybackRate = NULL;
static RateSetterIMP orig_IJKAudioQ_setPlaybackRate = NULL;
static RateSetterIMP orig_IJKMP_setPlaybackRate = NULL;

static void hook_IJKFF_setPlaybackRate(id self, SEL _cmd, float rate) {
    NSString *key = [NSString stringWithFormat:@"IJKFF_%.3f", rate];
    NSString *msg = [NSString stringWithFormat:@"命中 IJKFFMoviePlayerController setPlaybackRate:\nrate = %.3f", rate];
    GTPresentOnce(key, msg);
    if (orig_IJKFF_setPlaybackRate) orig_IJKFF_setPlaybackRate(self, _cmd, rate);
}

static void hook_IJKAV_setPlaybackRate(id self, SEL _cmd, float rate) {
    NSString *key = [NSString stringWithFormat:@"IJKAV_%.3f", rate];
    NSString *msg = [NSString stringWithFormat:@"命中 IJKAVMoviePlayerController setPlaybackRate:\nrate = %.3f", rate];
    GTPresentOnce(key, msg);
    if (orig_IJKAV_setPlaybackRate) orig_IJKAV_setPlaybackRate(self, _cmd, rate);
}

static void hook_IJKAudioQ_setPlaybackRate(id self, SEL _cmd, float rate) {
    NSString *key = [NSString stringWithFormat:@"IJKAudioQ_%.3f", rate];
    NSString *msg = [NSString stringWithFormat:@"命中 IJKSDLAudioQueueController setPlaybackRate:\nrate = %.3f", rate];
    GTPresentOnce(key, msg);
    if (orig_IJKAudioQ_setPlaybackRate) orig_IJKAudioQ_setPlaybackRate(self, _cmd, rate);
}

static void hook_IJKMP_setPlaybackRate(id self, SEL _cmd, float rate) {
    NSString *key = [NSString stringWithFormat:@"IJKMP_%.3f", rate];
    NSString *msg = [NSString stringWithFormat:@"命中 IJKMPMoviePlayerController setPlaybackRate:\nrate = %.3f", rate];
    GTPresentOnce(key, msg);
    if (orig_IJKMP_setPlaybackRate) orig_IJKMP_setPlaybackRate(self, _cmd, rate);
}

static BOOL GTHookRateSetter(NSString *className, RateSetterIMP replacement, RateSetterIMP *originalOut) {
    Class cls = NSClassFromString(className);
    if (!cls) return NO;
    SEL sel = @selector(setPlaybackRate:);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    MSHookMessageEx(cls, sel, (IMP)replacement, (IMP *)originalOut);
    return YES;
}

static void GTInstallIJKHooks(void) {
    BOOL ff = GTHookRateSetter(@"IJKFFMoviePlayerController", hook_IJKFF_setPlaybackRate, &orig_IJKFF_setPlaybackRate);
    BOOL av = GTHookRateSetter(@"IJKAVMoviePlayerController", hook_IJKAV_setPlaybackRate, &orig_IJKAV_setPlaybackRate);
    BOOL aq = GTHookRateSetter(@"IJKSDLAudioQueueController", hook_IJKAudioQ_setPlaybackRate, &orig_IJKAudioQ_setPlaybackRate);
    BOOL mp = GTHookRateSetter(@"IJKMPMoviePlayerController", hook_IJKMP_setPlaybackRate, &orig_IJKMP_setPlaybackRate);

    NSString *summary = [NSString stringWithFormat:
        @"0.3.3 已加载。\n\n检测到可 hook：\nIJKFFMoviePlayerController: %@\nIJKAVMoviePlayerController: %@\nIJKSDLAudioQueueController: %@\nIJKMPMoviePlayerController: %@\n\n请打开视频后切换 1× → 2×。",
        ff ? @"是" : @"否", av ? @"是" : @"否", aq ? @"是" : @"否", mp ? @"是" : @"否"];
    GTPresentOnce(@"startup_summary", summary);
}

%ctor {
    @autoreleasepool {
        GTShown = [NSMutableSet set];
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"tv.danmaku.bilianime"]) return;

        // Delay so bundled frameworks/classes have finished loading and UIKit is ready.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GTInstallIJKHooks();
        });
    }
}
