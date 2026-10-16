#import "REAUXHooks.h"
#import <objc/message.h>
static char explicitSingleKey;
static IMP originalSingle, originalMulti;
static BOOL getter(id target, const char *name, const char *type) {
    return target && REASignature(class_getInstanceMethod([target class], sel_registerName(name)), type, @[]);
}
static NSInteger number(id object, const char *name) {
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}
static void single(id self, SEL s, id sender) {
    objc_setAssociatedObject(self, &explicitSingleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))originalSingle)(self, s, sender);
}
static void multi(id self, SEL s, id sender) {
    objc_setAssociatedObject(self, &explicitSingleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))originalMulti)(self, s, sender);
}
BOOL REAEnsureContinuousCapture(id camera) {
    // Native camera UI must stay on the main thread. Never move its UIKit handler to a worker.
    if (!NSThread.isMainThread || !camera || [objc_getAssociatedObject(camera, &explicitSingleKey) boolValue]) return NO;
    if (!getter(camera, "currentImagePickerMode", "qQiI") ||
        !getter(camera, "imagePickerModeMask", "qQiI") ||
        !getter(camera, "isRetakeMode", "Bc") ||
        !getter(camera, "imagePickerDelegate", "@")) return NO;
    NSInteger mode = number(camera, "currentImagePickerMode");
    BOOL retake = ((BOOL (*)(id, SEL))objc_msgSend)(camera, sel_registerName("isRetakeMode"));
    if (retake || (number(camera, "imagePickerModeMask") & 2) == 0 || (mode != 1 && mode != 2)) return NO;
    id delegate = ((id (*)(id, SEL))objc_msgSend)(camera, sel_registerName("imagePickerDelegate"));
    SEL completion = sel_registerName("customImagePickerController:didFinishPickingMultiImages:");
    if (![delegate respondsToSelector:completion]) return NO;
    if (mode == 2) return YES;
    SEL action = sel_registerName("multiModeButtonDidClicked:");
    if (!REASignature(class_getInstanceMethod([camera class], action), "v", @[@"@"])) return NO;
    // Reuse native mode transition, including toolbar, auto-crop state and page count.
    // nil sender is supported by the original action (only its optional logging uses it).
    ((void (*)(id, SEL, id))objc_msgSend)(camera, action, nil);
    return number(camera, "currentImagePickerMode") == 2;
}
int REAInstallContinuousHooks(void) {
    int count = 0;
    Class camera = objc_getClass("ISCustomCameraImagePickerController");
    if (REAHook(camera, "singleModeButtonDidClicked:", "v", @[@"@"], (IMP)single, &originalSingle)) count++;
    if (REAHook(camera, "multiModeButtonDidClicked:", "v", @[@"@"], (IMP)multi, &originalMulti)) count++;
    return count;
}
#ifndef REA_FLOW_TESTING
@interface ScannerREAContinuousBootstrap : NSObject @end
@implementation ScannerREAContinuousBootstrap
+ (void)load {
    REAInstallContinuousHooks();
    dispatch_async(dispatch_get_main_queue(), ^{ REAInstallContinuousHooks(); });
}
@end
#endif
