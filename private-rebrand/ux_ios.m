#import "REAUXHooks.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <math.h>
extern BOOL REAEnsureContinuousCapture(id);

static IMP mainAppear, pageAppear, pageEndEditing, previewAppear, previewUpdate;
static IMP editorAppear, multiEditorAppear, cameraAppear, shutterAction, photoArrived, willCapture;
static char pageMenuKey, viewerButtonKey, photoBadgeKey, captureStatsKey;
static NSString *const pagesIdentifier = @"scannerrea.pages";
static NSString *const editIdentifier = @"scannerrea.edit";

static id getObject(id object, const char *name) {
    SEL selector = sel_registerName(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}
static void onMain(dispatch_block_t work) {
    if (NSThread.isMainThread) work(); else dispatch_async(dispatch_get_main_queue(), work);
}
static NSMutableDictionary *stats(id camera) {
    NSMutableDictionary *value = objc_getAssociatedObject(camera, &captureStatsKey);
    if (!value) {
        value = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(camera, &captureStatsKey, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return value;
}
NSDictionary *REAReadCaptureMetrics(id camera) {
    return [objc_getAssociatedObject(camera, &captureStatsKey) copy] ?: @{};
}
static NSArray<UIBarButtonItem *> *rightItems(UIViewController *vc) {
    return vc.navigationItem.rightBarButtonItems ?: @[];
}
BOOL REAInvokeNativeObjectAction(id target, SEL selector, id sender) {
    if (!target || ![target respondsToSelector:selector]) return NO;
    Method method = class_getInstanceMethod([target class], selector);
    if (!REASignature(method, "v", @[@"@"])) return NO;
    if ([sender isKindOfClass:[UIControl class]] &&
        (![(UIControl *)sender isEnabled] || [(UIControl *)sender isHidden])) return NO;
    if ([sender isKindOfClass:[UIBarButtonItem class]] && ![(UIBarButtonItem *)sender isEnabled]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(target, selector, sender);
    return YES;
}
static id findOriginalSender(UIViewController *vc, SEL selector) {
    for (UIBarButtonItem *item in rightItems(vc)) {
        if (item.target == vc && item.action == selector) return item;
    }
    if (!vc.isViewLoaded) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:vc.view];
    for (NSUInteger i = 0; i < queue.count && i < 512; i++) {
        UIView *view = queue[i];
        if ([view isKindOfClass:[UIControl class]]) {
            NSArray *actions = [(UIControl *)view actionsForTarget:vc forControlEvent:UIControlEventAllEvents];
            if ([actions containsObject:NSStringFromSelector(selector)]) return view;
        }
        if (queue.count < 512) [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}
static BOOL senderEnabled(id sender) {
    if ([sender isKindOfClass:[UIControl class]])
        return [(UIControl *)sender isEnabled] && ![(UIControl *)sender isHidden];
    if ([sender isKindOfClass:[UIBarButtonItem class]]) return [(UIBarButtonItem *)sender isEnabled];
    return NO;
}

void REAUpdatePageActions(UIViewController *vc) {
    if (!vc.isViewLoaded) return;
    UIBarButtonItem *own = objc_getAssociatedObject(vc, &pageMenuKey);
    NSMutableArray *items = [rightItems(vc) mutableCopy];
    UICollectionView *collection = getObject(vc, "collectionView");
    BOOL nativeSelection = [collection isKindOfClass:[UICollectionView class]] && collection.allowsMultipleSelection;
    if (nativeSelection) {
        if (own && [items containsObject:own]) { [items removeObject:own]; vc.navigationItem.rightBarButtonItems = items; }
        return;
    }
    if (own && [items containsObject:own]) return;
    if (items.count >= 3) return; // Do not crowd existing native actions.
    __weak UIViewController *weakVC = vc;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    for (NSArray<NSString *> *entry in @[
        @[@"Reordenar páginas", @"arrow.up.arrow.down", @"beginDragSort:"],
        @[@"Selecionar páginas", @"checkmark.circle", @"selectButtonClick:"]
    ]) {
        SEL selector = NSSelectorFromString(entry[2]);
        if (!REASignature(class_getInstanceMethod(vc.class, selector), "v", @[@"@"])) continue;
        UIAction *action = [UIAction actionWithTitle:entry[0] image:[UIImage systemImageNamed:entry[1]]
            identifier:entry[2] handler:^(__kindof UIAction *unused) {
                UIViewController *strongVC = weakVC;
                if (REAInvokeNativeObjectAction(strongVC, selector, nil)) REAUpdatePageActions(strongVC);
            }];
        [actions addObject:action];
    }
    if (!actions.count) return;
    own = [[UIBarButtonItem alloc] initWithTitle:@"Páginas" style:UIBarButtonItemStylePlain target:nil action:nil];
    own.accessibilityIdentifier = pagesIdentifier;
    own.accessibilityLabel = @"Organizar páginas";
    own.menu = [UIMenu menuWithTitle:@"Páginas do documento" children:actions];
    objc_setAssociatedObject(vc, &pageMenuKey, own, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [items insertObject:own atIndex:0];
    vc.navigationItem.rightBarButtonItems = items;
}
void REAUpdateViewer(UIViewController *vc) {
    if (!vc.isViewLoaded) return;
    SEL selector = sel_registerName("editingPage:");
    id sender = findOriginalSender(vc, selector);
    UIBarButtonItem *own = objc_getAssociatedObject(vc, &viewerButtonKey);
    if (own) {
        own.enabled = senderEnabled(sender);
        if ([rightItems(vc) containsObject:own]) return;
        if (sender && ![sender isKindOfClass:[UIBarButtonItem class]] && rightItems(vc).count < 3) {
            NSMutableArray *restored = [rightItems(vc) mutableCopy];
            [restored insertObject:own atIndex:0];
            vc.navigationItem.rightBarButtonItems = restored;
            return;
        }
    }
    if (!sender) return;
    if ([sender isKindOfClass:[UIBarButtonItem class]]) {
        [(UIBarButtonItem *)sender setAccessibilityLabel:@"Editar página"];
        return;
    }
    NSMutableArray *items = [rightItems(vc) mutableCopy];
    if (items.count >= 3) return;
    __weak UIViewController *weakVC = vc;
    UIAction *action = [UIAction actionWithTitle:@"Editar" image:nil identifier:editIdentifier
        handler:^(__kindof UIAction *unused) {
            UIViewController *strongVC = weakVC;
            REAInvokeNativeObjectAction(strongVC, selector, findOriginalSender(strongVC, selector));
        }];
    own = [[UIBarButtonItem alloc] initWithTitle:@"Editar" image:nil primaryAction:action menu:nil];
    own.accessibilityIdentifier = editIdentifier;
    own.accessibilityLabel = @"Editar página atual";
    own.enabled = senderEnabled(sender);
    objc_setAssociatedObject(vc, &viewerButtonKey, own, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [items insertObject:own atIndex:0];
    vc.navigationItem.rightBarButtonItems = items;
}
void REAUpdateEditor(UIViewController *vc) {
    NSMutableArray *items = [rightItems(vc) mutableCopy];
    [items addObjectsFromArray:vc.navigationItem.leftBarButtonItems ?: @[]];
    for (UIBarButtonItem *item in items) {
        if (item.target != vc) continue;
        NSString *name = NSStringFromSelector(item.action);
        if ([name isEqual:@"save:"] || [name isEqual:@"done:"]) {
            item.image = nil; item.title = @"Salvar";
            item.accessibilityLabel = @"Salvar alterações";
        } else if ([name isEqual:@"back:"]) {
            item.accessibilityLabel = @"Voltar ao documento";
        }
    }
}
void REAHideMarketingEntry(UIViewController *vc) {
    SEL selector = sel_registerName("loadPremiumAccountBuyViewController");
    NSMutableArray *items = [rightItems(vc) mutableCopy];
    NSIndexSet *matches = [items indexesOfObjectsPassingTest:^BOOL(UIBarButtonItem *item, NSUInteger idx, BOOL *stop) {
        return item.target == vc && item.action == selector;
    }];
    if (matches.count) { [items removeObjectsAtIndexes:matches]; vc.navigationItem.rightBarButtonItems = items; }
    if (!vc.isViewLoaded) return;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:vc.view];
    for (NSUInteger i = 0; i < queue.count && i < 512; i++) {
        UIView *view = queue[i];
        if ([view isKindOfClass:[UIControl class]]) {
            NSArray *actions = [(UIControl *)view actionsForTarget:vc forControlEvent:UIControlEventAllEvents];
            if ([actions containsObject:NSStringFromSelector(selector)]) {
                view.hidden = YES; view.accessibilityElementsHidden = YES;
            }
        }
        if (queue.count < 512) [queue addObjectsFromArray:view.subviews];
    }
}
static CGRect previewFrame(UIViewController *camera) {
    CGRect frame = camera.view.bounds;
    SEL selector = sel_registerName("previewLayerFrame");
    NSMethodSignature *signature = [camera methodSignatureForSelector:selector];
    if (signature && signature.numberOfArguments == 2 && signature.methodReturnLength == sizeof(CGRect)) {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:signature];
        inv.target = camera; inv.selector = selector; [inv invoke];
        CGRect candidate; [inv getReturnValue:&candidate];
        if (isfinite(candidate.origin.x) && isfinite(candidate.origin.y) &&
            isfinite(candidate.size.width) && isfinite(candidate.size.height) &&
            candidate.size.width > 0 && candidate.size.height > 0) {
            CGRect intersection = CGRectIntersection(candidate, camera.view.bounds);
            if (!CGRectIsNull(intersection) && !CGRectIsEmpty(intersection)) frame = intersection;
        }
    }
    return frame;
}
static void pulse(UIViewController *camera) {
    UIView *toolbar = getObject(camera, "toolbarView");
    UIView *button = getObject(toolbar, "cameraButton");
    if (![button isKindOfClass:[UIView class]] || button.bounds.size.width <= 0) return;
    NSMutableDictionary *metric = stats(camera);
    metric[@"pressFeedbackCount"] = @([metric[@"pressFeedbackCount"] unsignedIntegerValue] + 1);
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(button.bounds, 3, 3)].CGPath;
    ring.fillColor = UIColor.clearColor.CGColor;
    ring.strokeColor = UIColor.systemTealColor.CGColor;
    ring.lineWidth = 3; ring.opacity = 0;
    [button.layer addSublayer:ring];
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    animation.fromValue = @1; animation.toValue = @0; animation.duration = .18;
    [ring addAnimation:animation forKey:@"scannerrea.press"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 220 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [ring removeFromSuperlayer]; });
}
static void capturedFeedback(UIViewController *camera) {
    if (!camera.isViewLoaded || !camera.view.window) return;
    NSMutableDictionary *metric = stats(camera);
    metric[@"photoFeedbackCount"] = @([metric[@"photoFeedbackCount"] unsignedIntegerValue] + 1);
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
    CGRect frame = previewFrame(camera);
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        UIView *flash = [[UIView alloc] initWithFrame:frame];
        flash.backgroundColor = UIColor.whiteColor; flash.alpha = .16;
        flash.userInteractionEnabled = NO; flash.accessibilityElementsHidden = YES;
        [camera.view addSubview:flash];
        [UIView animateWithDuration:.14 animations:^{ flash.alpha = 0; } completion:^(BOOL finished) { [flash removeFromSuperview]; }];
    }
    UILabel *previous = objc_getAssociatedObject(camera, &photoBadgeKey);
    [previous removeFromSuperview];
    CGFloat width = MIN(210, MAX(1, frame.size.width - 24));
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(CGRectGetMidX(frame) - width / 2, frame.origin.y + 14, width, 34)];
    label.text = @"Foto capturada"; label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor; label.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:.78];
    label.layer.cornerRadius = 17; label.clipsToBounds = YES; label.userInteractionEnabled = NO;
    label.accessibilityIdentifier = @"scannerrea.capture-feedback";
    [camera.view addSubview:label];
    objc_setAssociatedObject(camera, &photoBadgeKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (UIAccessibilityIsVoiceOverRunning()) UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Foto capturada");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 650 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [label removeFromSuperview];
        if (objc_getAssociatedObject(camera, &photoBadgeKey) == label)
            objc_setAssociatedObject(camera, &photoBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}
static void mainWillAppear(id self, SEL s, BOOL a) {
    ((void (*)(id, SEL, BOOL))mainAppear)(self, s, a); REAHideMarketingEntry(self);
}
static void pagesWillAppear(id self, SEL s, BOOL a) {
    ((void (*)(id, SEL, BOOL))pageAppear)(self, s, a); REAUpdatePageActions(self);
}
static void pagesEndEditing(id self, SEL s, id sender) {
    ((void (*)(id, SEL, id))pageEndEditing)(self, s, sender); REAUpdatePageActions(self);
}
static void viewerWillAppear(id self, SEL s, BOOL a) {
    ((void (*)(id, SEL, BOOL))previewAppear)(self, s, a); REAUpdateViewer(self);
}
static void viewerUpdate(id self, SEL s) {
    ((void (*)(id, SEL))previewUpdate)(self, s); REAUpdateViewer(self);
}
static void editWillAppear(id self, SEL s, BOOL a) {
    ((void (*)(id, SEL, BOOL))editorAppear)(self, s, a); REAUpdateEditor(self);
}
static void multiEditWillAppear(id self, SEL s, BOOL a) {
    ((void (*)(id, SEL, BOOL))multiEditorAppear)(self, s, a); REAUpdateEditor(self);
}
static void cameraWillAppear(id self, SEL s, BOOL a) {
    ((void (*)(id, SEL, BOOL))cameraAppear)(self, s, a);
    REAEnsureContinuousCapture(self);
    onMain(^{ [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] prepare]; });
}
static void shutter(id self, SEL s, id sender) {
    REAEnsureContinuousCapture(self);
    __weak UIViewController *weakCamera = self;
    onMain(^{
        UIViewController *camera = weakCamera; if (!camera) return;
        stats(camera)[@"start"] = @(NSDate.timeIntervalSinceReferenceDate);
        stats(camera)[@"startOrigin"] = @"manual_press";
        pulse(camera);
    });
    ((void (*)(id, SEL, id))shutterAction)(self, s, sender);
}
static void cameraWillCapture(id self, SEL s, id manager) {
    REAEnsureContinuousCapture(self);
    __weak id weakCamera = self;
    onMain(^{
        id camera = weakCamera; if (!camera) return;
        double now = NSDate.timeIntervalSinceReferenceDate;
        NSNumber *start = stats(camera)[@"start"];
        if (!start || now - start.doubleValue > 5) {
            stats(camera)[@"start"] = @(now);
            stats(camera)[@"startOrigin"] = @"will_capture_after_focus";
        }
    });
    ((void (*)(id, SEL, id))willCapture)(self, s, manager);
}
static void photo(id self, SEL s, id manager, id data) {
    REAEnsureContinuousCapture(self);
    BOOL validData = [data isKindOfClass:[NSData class]] && [data length] > 0;
    double received = NSDate.timeIntervalSinceReferenceDate;
    __weak UIViewController *weakCamera = self;
    if (validData) onMain(^{
        UIViewController *camera = weakCamera; if (!camera) return;
        NSNumber *start = stats(camera)[@"start"];
        if (start) stats(camera)[@"requestToImageMs"] = @(MAX(0, received - start.doubleValue) * 1000);
        capturedFeedback(camera);
    });
    ((void (*)(id, SEL, id, id))photoArrived)(self, s, manager, data);
    double duration = (NSDate.timeIntervalSinceReferenceDate - received) * 1000;
    if (validData) onMain(^{
        id camera = weakCamera; if (!camera) return;
        stats(camera)[@"nativeHandlerMs"] = @(duration);
        [stats(camera) removeObjectForKey:@"start"];
    });
}
static void omitPageBanner(id self, SEL s, NSInteger animated) {}

static const char *guideNames[] = {
    "CSCameraPurchaseIDCardGuideView", "CSCameraPurchaseOcrGuideView",
    "CSCameraPurchaseExcelGuideView", "CSCameraPurchaseCertifcationGuideView"
};
static IMP guideOriginals[4], guideWindowOriginals[4];
static void quietGuideHidden(id self, SEL s, BOOL hidden) {
    for (unsigned i = 0; i < 4; i++) {
        Class cls = objc_getClass(guideNames[i]);
        if (cls && [self isKindOfClass:cls] && guideOriginals[i]) {
            ((void (*)(id, SEL, BOOL))guideOriginals[i])(self, s, YES);
            [(UIView *)self setUserInteractionEnabled:NO];
            [(UIView *)self setAccessibilityElementsHidden:YES];
            return;
        }
    }
}
static void quietGuideWindow(id self, SEL s) {
    for (unsigned i = 0; i < 4; i++) {
        Class cls = objc_getClass(guideNames[i]);
        if (cls && [self isKindOfClass:cls] && guideWindowOriginals[i]) {
            ((void (*)(id, SEL))guideWindowOriginals[i])(self, s);
            [(UIView *)self setHidden:YES];
            [(UIView *)self setUserInteractionEnabled:NO];
            [(UIView *)self setAccessibilityElementsHidden:YES];
            return;
        }
    }
}
int REAInstallUXHooks(void) {
    int count = 0;
#define HOOK(cls, name, ret, args, fn, original) \
    if (REAHook(objc_getClass(cls), name, ret, args, (IMP)fn, &original)) count++;
    HOOK("CSMainViewController", "viewWillAppear:", "v", (@[@"Bc"]), mainWillAppear, mainAppear)
    HOOK("PageListViewController", "viewWillAppear:", "v", (@[@"Bc"]), pagesWillAppear, pageAppear)
    HOOK("PageListViewController", "endEditingTableView:", "v", (@[@"@"]), pagesEndEditing, pageEndEditing)
    HOOK("CSPagePreviewViewController", "viewWillAppear:", "v", (@[@"Bc"]), viewerWillAppear, previewAppear)
    HOOK("CSPagePreviewViewController", "updateToolbarEnabled", "v", (@[]), viewerUpdate, previewUpdate)
    HOOK("CSEditViewController", "viewWillAppear:", "v", (@[@"Bc"]), editWillAppear, editorAppear)
    HOOK("CSMultiEditPageViewController", "viewWillAppear:", "v", (@[@"Bc"]), multiEditWillAppear, multiEditorAppear)
    HOOK("ISCustomCameraImagePickerController", "viewWillAppear:", "v", (@[@"Bc"]), cameraWillAppear, cameraAppear)
    HOOK("ISCustomCameraImagePickerController", "cameraButtonDidClicked:", "v", (@[@"@"]), shutter, shutterAction)
    HOOK("ISCustomCameraImagePickerController", "captureManagerWillCaptureStillImage:", "v", (@[@"@"]), cameraWillCapture, willCapture)
    HOOK("ISCustomCameraImagePickerController", "captureManager:didCaptureStillImage:", "v", (@[@"@", @"@"]), photo, photoArrived)
#undef HOOK
    if (REAHook(objc_getClass("PageListViewController"), "createAndLayoutAdBannerContainerView:",
                "v", @[@"BcqQiI"], (IMP)omitPageBanner, NULL)) count++;
    for (unsigned i = 0; i < 4; i++)
        if (REAHook(objc_getClass(guideNames[i]), "setHidden:", "v", @[@"Bc"],
                    (IMP)quietGuideHidden, &guideOriginals[i])) count++;
    for (unsigned i = 0; i < 4; i++)
        if (REAHook(objc_getClass(guideNames[i]), "didMoveToWindow", "v", @[],
                    (IMP)quietGuideWindow, &guideWindowOriginals[i])) count++;
    return count;
}
#ifndef REA_FLOW_TESTING
@interface ScannerREAUXBootstrap : NSObject @end
@implementation ScannerREAUXBootstrap
+ (void)load {
    REAInstallUXHooks();
    dispatch_async(dispatch_get_main_queue(), ^{ REAInstallUXHooks(); });
}
@end
#endif
