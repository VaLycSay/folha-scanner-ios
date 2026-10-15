#import <Foundation/Foundation.h>
#include <math.h>
extern double REAEffectiveFocusWait(BOOL, uintptr_t, double);
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
        while (elapsed < 1.0) { elapsed += REAEffectiveFocusWait(YES, site, 10000); polls++; }
        check(elapsed < 1.011 && polls <= 101, @"existing 1s focus deadline can be reevaluated");
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
        printf("PASS %u policy assertions; focus simulation, not physical capture latency.\n", checks);
    }
    return 0;
}
