#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <substrate.h>

static dispatch_queue_t gLogQueue;
static NSString *gLogPath;

static NSString *FourCC(UInt32 x) {
    char s[5];
    s[0] = (char)((x >> 24) & 0xff);
    s[1] = (char)((x >> 16) & 0xff);
    s[2] = (char)((x >> 8) & 0xff);
    s[3] = (char)(x & 0xff);
    s[4] = 0;
    for (int i = 0; i < 4; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 32 || c > 126) s[i] = '.';
    }
    return [NSString stringWithUTF8String:s];
}

static void ProbeLog(NSString *fmt, ...) {
    if (!gLogQueue || !gLogPath) return;
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSTimeInterval t = [NSDate date].timeIntervalSince1970;
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n", t, body ?: @""];
    dispatch_async(gLogQueue, ^{
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        } @catch (__unused NSException *e) {}
    });
}

static NSString *AlgName(NSString *alg) {
    if (!alg) return @"(nil)";
    return alg;
}

%hook AVPlayer
- (void)setRate:(float)rate {
    ProbeLog(@"AVPlayer setRate %.3f", rate);
    %orig;
}
- (void)setRate:(float)rate time:(CMTime)itemTime atHostTime:(CMTime)hostClockTime {
    ProbeLog(@"AVPlayer setRate:time:atHostTime %.3f", rate);
    %orig;
}
%end

%hook AVPlayerItem
- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm {
    ProbeLog(@"AVPlayerItem setAudioTimePitchAlgorithm %@", AlgName(algorithm));
    %orig;
}
%end

%hook AVSampleBufferAudioRenderer
- (void)setAudioTimePitchAlgorithm:(AVAudioTimePitchAlgorithm)algorithm {
    ProbeLog(@"AVSampleBufferAudioRenderer setAudioTimePitchAlgorithm %@", AlgName(algorithm));
    %orig;
}
%end

%hook AVAudioUnitTimePitch
- (void)setRate:(float)rate {
    ProbeLog(@"AVAudioUnitTimePitch setRate %.3f", rate);
    %orig;
}
- (void)setPitch:(float)pitch {
    ProbeLog(@"AVAudioUnitTimePitch setPitch %.3f", pitch);
    %orig;
}
- (void)setOverlap:(float)overlap {
    ProbeLog(@"AVAudioUnitTimePitch setOverlap %.3f", overlap);
    %orig;
}
%end

%hook AVAudioUnitVarispeed
- (void)setRate:(float)rate {
    ProbeLog(@"AVAudioUnitVarispeed setRate %.3f", rate);
    %orig;
}
%end

static OSStatus (*orig_AudioQueueSetProperty)(AudioQueueRef, AudioQueuePropertyID, const void *, UInt32);
static OSStatus repl_AudioQueueSetProperty(AudioQueueRef aq, AudioQueuePropertyID pid, const void *data, UInt32 size) {
    if (pid == kAudioQueueProperty_EnableTimePitch ||
        pid == kAudioQueueProperty_TimePitchAlgorithm ||
        pid == kAudioQueueProperty_TimePitchBypass) {
        UInt32 v = 0;
        if (data && size >= sizeof(UInt32)) memcpy(&v, data, sizeof(UInt32));
        if (pid == kAudioQueueProperty_TimePitchAlgorithm) {
            ProbeLog(@"AudioQueueSetProperty TimePitchAlgorithm 0x%08x '%@'", (unsigned)v, FourCC(v));
        } else if (pid == kAudioQueueProperty_EnableTimePitch) {
            ProbeLog(@"AudioQueueSetProperty EnableTimePitch %u", (unsigned)v);
        } else {
            ProbeLog(@"AudioQueueSetProperty TimePitchBypass %u", (unsigned)v);
        }
    }
    return orig_AudioQueueSetProperty(aq, pid, data, size);
}

static OSStatus (*orig_AudioQueueSetParameter)(AudioQueueRef, AudioQueueParameterID, AudioQueueParameterValue);
static OSStatus repl_AudioQueueSetParameter(AudioQueueRef aq, AudioQueueParameterID pid, AudioQueueParameterValue value) {
    if (pid == kAudioQueueParam_PlayRate || pid == kAudioQueueParam_Pitch) {
        ProbeLog(@"AudioQueueSetParameter id=%u value=%.3f", (unsigned)pid, (double)value);
    }
    return orig_AudioQueueSetParameter(aq, pid, value);
}

static BOOL IsInterestingAudioUnit(AudioUnit unit, AudioComponentDescription *outDesc) {
    if (!unit) return NO;
    AudioComponent comp = AudioComponentInstanceGetComponent(unit);
    if (!comp) return NO;
    AudioComponentDescription d;
    memset(&d, 0, sizeof(d));
    if (AudioComponentGetDescription(comp, &d) != noErr) return NO;
    if (outDesc) *outDesc = d;
    return (d.componentSubType == kAudioUnitSubType_NewTimePitch ||
            d.componentSubType == kAudioUnitSubType_Varispeed ||
            d.componentSubType == kAudioUnitSubType_TimePitch);
}

static OSStatus (*orig_AudioUnitSetParameter)(AudioUnit, AudioUnitParameterID, AudioUnitScope, AudioUnitElement, AudioUnitParameterValue, UInt32);
static OSStatus repl_AudioUnitSetParameter(AudioUnit unit, AudioUnitParameterID pid, AudioUnitScope scope, AudioUnitElement element, AudioUnitParameterValue value, UInt32 offset) {
    AudioComponentDescription d;
    if (IsInterestingAudioUnit(unit, &d)) {
        ProbeLog(@"AudioUnitSetParameter subtype='%@' pid=%u scope=%u elem=%u value=%.3f", FourCC(d.componentSubType), (unsigned)pid, (unsigned)scope, (unsigned)element, (double)value);
    }
    return orig_AudioUnitSetParameter(unit, pid, scope, element, value, offset);
}

// Optional direct hooks if APlayer contains/exported Sonic symbols.
typedef void (*SonicSetSpeedFn)(void *, float);
static SonicSetSpeedFn orig_sonicSetSpeed = NULL;
static void repl_sonicSetSpeed(void *stream, float speed) {
    ProbeLog(@"sonicSetSpeed %.3f", speed);
    orig_sonicSetSpeed(stream, speed);
}

typedef void (*STDoubleSetterFn)(void *, double);
static STDoubleSetterFn orig_stSetTempo = NULL;
static STDoubleSetterFn orig_stSetRate = NULL;
static STDoubleSetterFn orig_stSetPitch = NULL;
static void repl_stSetTempo(void *self, double v) { ProbeLog(@"SoundTouch::setTempo %.3f", v); orig_stSetTempo(self, v); }
static void repl_stSetRate(void *self, double v)  { ProbeLog(@"SoundTouch::setRate %.3f", v);  orig_stSetRate(self, v); }
static void repl_stSetPitch(void *self, double v) { ProbeLog(@"SoundTouch::setPitch %.3f", v); orig_stSetPitch(self, v); }

static void InstallOptionalSymbolHooks(void) {
    void *p = dlsym(RTLD_DEFAULT, "sonicSetSpeed");
    ProbeLog(@"symbol sonicSetSpeed %@", p ? @"FOUND" : @"not found");
    if (p) MSHookFunction(p, (void *)&repl_sonicSetSpeed, (void **)&orig_sonicSetSpeed);

    p = dlsym(RTLD_DEFAULT, "_ZN10soundtouch10SoundTouch8setTempoEd");
    ProbeLog(@"symbol SoundTouch::setTempo %@", p ? @"FOUND" : @"not found");
    if (p) MSHookFunction(p, (void *)&repl_stSetTempo, (void **)&orig_stSetTempo);

    p = dlsym(RTLD_DEFAULT, "_ZN10soundtouch10SoundTouch7setRateEd");
    ProbeLog(@"symbol SoundTouch::setRate %@", p ? @"FOUND" : @"not found");
    if (p) MSHookFunction(p, (void *)&repl_stSetRate, (void **)&orig_stSetRate);

    p = dlsym(RTLD_DEFAULT, "_ZN10soundtouch10SoundTouch8setPitchEd");
    ProbeLog(@"symbol SoundTouch::setPitch %@", p ? @"FOUND" : @"not found");
    if (p) MSHookFunction(p, (void *)&repl_stSetPitch, (void **)&orig_stSetPitch);
}

static BOOL ContainsKeyword(NSString *s) {
    if (!s) return NO;
    NSString *x = s.lowercaseString;
    NSArray *keys = @[@"alook", @"aplayer", @"player", @"audio", @"soundtouch", @"tdstretch", @"sonic", @"pitch", @"ffmpeg", @"libav", @"ijk", @"vlc", @"ksy", @"media"];
    for (NSString *k in keys) if ([x containsString:k]) return YES;
    return NO;
}

static void DumpInterestingImagesAndClasses(void) {
    ProbeLog(@"---- loaded non-system images ----");
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *cname = _dyld_get_image_name(i);
        if (!cname) continue;
        NSString *path = [NSString stringWithUTF8String:cname];
        if ([path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/lib/"]) continue;
        ProbeLog(@"IMAGE %@", path.lastPathComponent);
    }

    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (Class *)calloc((size_t)n, sizeof(Class));
    if (!classes) return;
    n = objc_getClassList(classes, n);
    ProbeLog(@"---- interesting app/framework classes ----");
    for (int i = 0; i < n; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        const char *img = class_getImageName(c);
        if (!cn || !img) continue;
        NSString *name = [NSString stringWithUTF8String:cn];
        NSString *image = [NSString stringWithUTF8String:img];
        if ([image hasPrefix:@"/System/"] || [image hasPrefix:@"/usr/lib/"]) continue;
        if (ContainsKeyword(name) || ContainsKeyword(image.lastPathComponent)) {
            ProbeLog(@"CLASS %@ [%@]", name, image.lastPathComponent);
        }
    }
    free(classes);
}

static void ScanExecutableKeywords(void) {
    NSString *exe = [NSBundle mainBundle].executablePath;
    NSData *data = [NSData dataWithContentsOfFile:exe options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return;
    const char *bytes = (const char *)data.bytes;
    NSUInteger len = data.length;
    NSArray *keys = @[@"SoundTouch", @"TDStretch", @"sonicSetSpeed", @"RubberBand", @"libavcodec", @"FFmpeg", @"AVAudioUnitTimePitch", @"NewTimePitch"];
    ProbeLog(@"---- executable keyword scan ----");
    for (NSString *key in keys) {
        NSData *needleData = [key dataUsingEncoding:NSUTF8StringEncoding];
        const char *needle = (const char *)needleData.bytes;
        NSUInteger nlen = needleData.length;
        BOOL found = NO;
        if (nlen > 0 && len >= nlen) {
            for (NSUInteger i = 0; i <= len - nlen; i++) {
                if (memcmp(bytes + i, needle, nlen) == 0) { found = YES; break; }
            }
        }
        ProbeLog(@"KEYWORD %@ %@", key, found ? @"FOUND" : @"not found");
    }
}

%ctor {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"com.alookbrowser.player"]) return;

        gLogQueue = dispatch_queue_create("com.chatgpt.aplayeraudioprobe.log", DISPATCH_QUEUE_SERIAL);
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        gLogPath = [docs stringByAppendingPathComponent:@"APlayerAudioProbe.log"];
        [[NSFileManager defaultManager] removeItemAtPath:gLogPath error:nil];
        ProbeLog(@"APlayerAudioProbe 0.8.0 START bundle=%@ executable=%@ home=%@", bid, [NSBundle mainBundle].executablePath.lastPathComponent, NSHomeDirectory());

        MSHookFunction((void *)AudioQueueSetProperty, (void *)&repl_AudioQueueSetProperty, (void **)&orig_AudioQueueSetProperty);
        MSHookFunction((void *)AudioQueueSetParameter, (void *)&repl_AudioQueueSetParameter, (void **)&orig_AudioQueueSetParameter);
        MSHookFunction((void *)AudioUnitSetParameter, (void *)&repl_AudioUnitSetParameter, (void **)&orig_AudioUnitSetParameter);

        InstallOptionalSymbolHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DumpInterestingImagesAndClasses();
            ScanExecutableKeywords();
            ProbeLog(@"---- READY: now test 1x -> 2x -> 3x -> 1x ----");
        });
    }
}
