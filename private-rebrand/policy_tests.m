#import <Foundation/Foundation.h>
#include <math.h>
extern double REAEffectiveFocusWait(BOOL, uintptr_t, double);
extern BOOL REAShouldContinueFocusWait(BOOL, unsigned, BOOL);
extern NSString *REASanitizeBrandString(NSString *);
extern int REAInstallPolicyHooks(void);
static unsigned checks;
static void check(BOOL ok, NSString *label) { checks++; if (!ok) { NSLog(@"FAIL %@", label); exit(1); } }
@interface CSNewPremiumAccountHandler : NSObject
+ (BOOL)popFrequencyShow;
+ (BOOL)popRecallViewShow;
+ (BOOL)isPremiumAccount;
@end
@implementation CSNewPremiumAccountHandler
+ (BOOL)popFrequencyShow { return YES; }
+ (BOOL)popRecallViewShow { return YES; }
+ (BOOL)isPremiumAccount { return NO; }
@end
@interface CSMainViewController : NSObject
@property NSUInteger promotions;
@property NSUInteger transactionErrors;
- (void)showPremiumAccountIntroduction;
- (void)addProductPromotionBubbleView;
- (void)loadPremiumAccountBuyViewController;
- (void)purchaseAppstoreFailed:(id)error;
@end
@implementation CSMainViewController
- (void)showPremiumAccountIntroduction { self.promotions++; }
- (void)addProductPromotionBubbleView { self.promotions++; }
- (void)loadPremiumAccountBuyViewController { self.promotions++; }
- (void)purchaseAppstoreFailed:(id)error { self.transactionErrors++; }
@end
int main(void) {
    @autoreleasepool {
        const uintptr_t site = 0xf6f68;
        for (double wait = 0.02; wait <= 10.01; wait += 0.5) {
            check(fabs(REAEffectiveFocusWait(YES, site, wait) - .010) < .000001, @"owned wait bounded");
            check(REAEffectiveFocusWait(NO, site, wait) == wait, @"outside capture unchanged");
            check(REAEffectiveFocusWait(YES, site + 4, wait) == wait, @"other call site unchanged");
        }
        check(REAEffectiveFocusWait(YES, site, .001) == .001, @"shorter deadline retained");
        check(REAEffectiveFocusWait(YES, site, -.1) == -.1, @"elapsed deadline retained");
        check(isnan(REAEffectiveFocusWait(YES, site, NAN)), @"invalid interval not invented");
        double elapsed = 0; unsigned polls = 0;
        while (elapsed < 1.0 && REAShouldContinueFocusWait(YES, polls, YES)) {
            elapsed += REAEffectiveFocusWait(YES, site, 10000);
            polls++;
        }
        check(polls == 5 && elapsed <= 0.051, @"focus wait loop exits within 50ms when hardware is micro-adjusting");
        check(!REAShouldContinueFocusWait(YES, 0, NO), @"already focused exits immediately in 0ms");
        check(REAShouldContinueFocusWait(NO, 99, YES), @"outside capture hardware focus state untouched");
        check([REASanitizeBrandString(@"Welcome to CamScanner+") isEqualToString:@"Welcome to DocScan Pro"], @"brand replaced in display text");
        check([REASanitizeBrandString(@"Scanned with CamScanner (http://cc.co/16Wpvz)") isEqualToString:@""], @"share watermark stripped");
        check([REASanitizeBrandString(@"https://www.camscanner.com/user/privacy") isEqualToString:@"https://www.camscanner.com/user/privacy"], @"technical URL preserved");
        check(REAInstallPolicyHooks() == 5, @"only available promotion surfaces installed");
        check(REAInstallPolicyHooks() == 5, @"repeat install is idempotent");
        check(![CSNewPremiumAccountHandler popFrequencyShow], @"automatic promotion off");
        check(![CSNewPremiumAccountHandler popRecallViewShow], @"price recall promotion off");
        check(![CSNewPremiumAccountHandler isPremiumAccount], @"paid account not fabricated");
        CSMainViewController *main = [CSMainViewController new];
        [main showPremiumAccountIntroduction]; [main addProductPromotionBubbleView];
        [main loadPremiumAccountBuyViewController]; [main purchaseAppstoreFailed:nil];
        check(main.promotions == 0, @"identified promotion entrypoints omitted");
        check(main.transactionErrors == 1, @"transaction errors remain");
        printf("PASS %u policy assertions; focus simulation and brand policy verified.\n", checks);
    }
    return 0;
}
