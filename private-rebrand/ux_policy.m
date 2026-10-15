#import "REAUXHooks.h"
#import <mach-o/dyld.h>
#include <math.h>
#include <stdatomic.h>

static IMP originalCapture, originalRunMode;
static _Thread_local unsigned captureDepth;
static atomic_ulong boundedWaits;
static const uintptr_t nativeFocusWaitReturnOffset = 0x000f6f68;

double REAEffectiveFocusWait(BOOL inCapture, uintptr_t callerOffset, double requested) {
    if (inCapture && callerOffset == nativeFocusWaitReturnOffset &&
        isfinite(requested) && requested > 0.010) return 0.010;
    return requested;
}
unsigned long REABoundedFocusWaitCount(void) { return atomic_load(&boundedWaits); }

static void capture(id self, SEL selector) {
    captureDepth++;
    @try { ((void (*)(id, SEL))originalCapture)(self, selector); }
    @finally { captureDepth--; }
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
