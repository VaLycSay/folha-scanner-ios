#import "REAUXHooks.h"
#import <mach-o/dyld.h>
#include <math.h>
#include <stdatomic.h>

static IMP originalCapture, originalRunMode, originalAdjustingFocus;
static _Thread_local unsigned captureDepth;
static _Thread_local unsigned capturePollCount;
static atomic_ulong boundedWaits;
static const uintptr_t nativeFocusWaitReturnOffset = 0x000f6f68;
static const unsigned maxCaptureFocusPolls = 5; // 5 * 10ms = 50ms max focus wait instead of 1000ms

double REAEffectiveFocusWait(BOOL inCapture, uintptr_t callerOffset, double requested) {
    if (inCapture && callerOffset == nativeFocusWaitReturnOffset &&
        isfinite(requested) && requested > 0.010) return 0.010;
    return requested;
}

BOOL REAShouldContinueFocusWait(BOOL inCapture, unsigned polls, BOOL hardwareAdjusting) {
    if (!hardwareAdjusting) return NO;
    if (inCapture && polls >= maxCaptureFocusPolls) return NO;
    return YES;
}

NSString *REASanitizeBrandString(NSString *input) {
    if (![input isKindOfClass:[NSString class]] || input.length == 0) return input;
    if ([input rangeOfString:@"CamScanner" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return input;
    }
    // Preserve technical URL schemes or domains if the entire string is a URL/identifier
    NSString *trimmed = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"] ||
        [trimmed hasPrefix:@"camscanner"] || [trimmed containsString:@"camscanner.com"] ||
        [trimmed containsString:@"intsig.net"]) {
        if ([trimmed rangeOfString:@"Scanned with CamScanner" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [trimmed rangeOfString:@"Digitalizado com" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return @"";
        }
        return input;
    }
    if ([input rangeOfString:@"Scanned with CamScanner" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [input rangeOfString:@"Digitalizado com CamScanner" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [input rangeOfString:@"Digitalizado com o CamScanner" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return @"";
    }
    NSString *result = input;
    for (NSString *target in @[@"CamScanner+", @"CamScanner +", @"CamScanner", @"Camscanner", @"CAMSCANNER"]) {
        result = [result stringByReplacingOccurrencesOfString:target withString:@"DocScan Pro"];
    }
    return result;
}

unsigned long REABoundedFocusWaitCount(void) { return atomic_load(&boundedWaits); }

static void capture(id self, SEL selector) {
    captureDepth++;
    capturePollCount = 0;
    @try { ((void (*)(id, SEL))originalCapture)(self, selector); }
    @finally {
        capturePollCount = 0;
        captureDepth--;
    }
}

static BOOL adjustingFocus(id self, SEL selector) {
    BOOL hw = ((BOOL (*)(id, SEL))originalAdjustingFocus)(self, selector);
    return REAShouldContinueFocusWait(captureDepth != 0, capturePollCount, hw);
}

__attribute__((noinline))
static BOOL runMode(id self, SEL selector, id mode, NSDate *deadline) {
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    uintptr_t base = (uintptr_t)_dyld_get_image_header(0);
    uintptr_t offset = caller >= base ? caller - base : UINTPTR_MAX;
    NSDate *effective = deadline;
    if (deadline) {
        double now = NSDate.timeIntervalSinceReferenceDate;
        double requested = deadline.timeIntervalSinceReferenceDate - now;
        double bounded = REAEffectiveFocusWait(captureDepth != 0, offset, requested);
        if (bounded < requested) {
            effective = [NSDate dateWithTimeIntervalSinceReferenceDate:now + bounded];
            atomic_fetch_add(&boundedWaits, 1);
            if (captureDepth != 0) capturePollCount++;
        }
    }
    return ((BOOL (*)(id, SEL, id, NSDate *))originalRunMode)(self, selector, mode, effective);
}

static BOOL noPromotion(id self, SEL selector) { return NO; }
static void omitPromotion(id self, SEL selector) {}

int REAInstallPolicyHooks(void) {
    int count = 0;
    Class manager = objc_getClass("ISAVFoundationCaptureManager");
    if (REAHook(manager, "captureStillImage", "v", @[], (IMP)capture, &originalCapture)) {
        count++;
        if (REAHook([NSRunLoop class], "runMode:beforeDate:", "Bc", @[@"@", @"@"],
                    (IMP)runMode, &originalRunMode)) count++;
    }
    Class avDevice = objc_getClass("AVCaptureDevice");
    if (avDevice) {
        REAHook(avDevice, "isAdjustingFocus", "Bc", @[], (IMP)adjustingFocus, &originalAdjustingFocus);
    }
    // Display-frequency policy only. No premium/account/receipt getters are changed.
    Class promoMeta = object_getClass(objc_getClass("CSNewPremiumAccountHandler"));
    for (NSString *name in @[@"popFrequencyShow", @"popRecallViewShow"])
        if (REAHook(promoMeta, name.UTF8String, "BcqQiI", @[], (IMP)noPromotion, NULL)) count++;
    Class main = objc_getClass("CSMainViewController");
    for (NSString *name in @[@"showPremiumAccountIntroduction",
                             @"addProductPromotionBubbleView",
                             @"loadPremiumAccountBuyViewController"])
        if (REAHook(main, name.UTF8String, "v", @[], (IMP)omitPromotion, NULL)) count++;
    return count;
}
#ifndef REA_FLOW_TESTING
@interface ScannerREAPolicyBootstrap : NSObject @end
@implementation ScannerREAPolicyBootstrap
+ (void)load {
    REAInstallPolicyHooks();
    dispatch_async(dispatch_get_main_queue(), ^{ REAInstallPolicyHooks(); });
}
@end
#endif
