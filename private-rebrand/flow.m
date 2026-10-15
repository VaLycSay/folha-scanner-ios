#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#include <string.h>

// Own flow adaptation. No detector, OCR, networking or purchase-state hooks.
static id (*originalFactory)(id, SEL, NSInteger, id, id);
static void (*originalDone)(id, SEL, id);
static void (*originalFinish)(id, SEL, id, id);
static char finishingReviewKey;

static BOOL has(id object, const char *name) {
    return object && [object respondsToSelector:sel_registerName(name)];
}
static NSInteger integer(id object, const char *name) {
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}
static BOOL boolean(id object, const char *name) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}
static void setBool(id object, const char *name, BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, sel_registerName(name), value);
}
static BOOL batchCamera(id camera) {
    return has(camera, "currentImagePickerMode") && has(camera, "isRetakeMode") &&
        has(camera, "setNeedPreviewInMultiTake:") &&
        integer(camera, "currentImagePickerMode") == 2 &&
        !boolean(camera, "isRetakeMode");
}
static id factory(id self, SEL selector, NSInteger mode, id controller, id extra) {
    id config = originalFactory(self, selector, mode, controller, extra);
    if (has(config, "currentModel") && has(config, "retakeMode") &&
        has(config, "modeMask") && has(config, "setCurrentModel:")) {
        NSInteger selected = integer(config, "currentModel");
        if (selected <= 1 && !boolean(config, "retakeMode") &&
            (integer(config, "modeMask") & 2) != 0) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                config, sel_registerName("setCurrentModel:"), 2);
        }
    }
    return config;
}
static void done(id self, SEL selector, id sender) {
    if (batchCamera(self) && !objc_getAssociatedObject(self, &finishingReviewKey) &&
        has(self, "selectedImagePaths")) {
        id pages = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("selectedImagePaths"));
        if ([pages respondsToSelector:@selector(count)] && [pages count] > 0) {
            setBool(self, "setNeedPreviewInMultiTake:", YES);
        }
    }
    originalDone(self, selector, sender);
}
static void finish(id self, SEL selector, id preview, id pages) {
    BOOL adapting = batchCamera(self);
    if (adapting) {
        objc_setAssociatedObject(self, &finishingReviewKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        setBool(self, "setNeedPreviewInMultiTake:", NO);
    }
    @try {
        originalFinish(self, selector, preview, pages);
    } @finally {
        if (adapting) objc_setAssociatedObject(self, &finishingReviewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
static BOOL typeMatches(char *type, const char *allowed) {
    BOOL match = type && strchr(allowed, type[0]) != NULL;
    free(type);
    return match;
}
static BOOL valid(Method method, unsigned argc, const char *result, const char *argument2) {
    if (!method || method_getNumberOfArguments(method) != argc) return NO;
    if (!typeMatches(method_copyReturnType(method), result)) return NO;
    if (!typeMatches(method_copyArgumentType(method, 2), argument2)) return NO;
    for (unsigned i = 3; i < argc; i++) {
        if (!typeMatches(method_copyArgumentType(method, i), "@")) return NO;
    }
    return YES;
}
int REAInstallFlowHooks(void) {
    static BOOL installed;
    if (installed) return 1;
    Class camera = objc_getClass("ISCustomCameraImagePickerController");
    Class maker = objc_getClass("CSImagePickerCameraFactory");
    Method factoryMethod = class_getInstanceMethod(maker, sel_registerName("createConfigurationWithMode:fromController:extra:"));
    Method doneMethod = class_getInstanceMethod(camera, sel_registerName("doneButtonDidClicked:"));
    Method finishMethod = class_getInstanceMethod(camera, sel_registerName("previewController:finishMultiTakePhoto:"));
    if (!valid(factoryMethod, 5, "@", "qQiI") ||
        !valid(doneMethod, 3, "v", "@") || !valid(finishMethod, 4, "v", "@")) return 0;
    originalFactory = (void *)method_getImplementation(factoryMethod);
    originalDone = (void *)method_getImplementation(doneMethod);
    originalFinish = (void *)method_getImplementation(finishMethod);
    method_setImplementation(factoryMethod, (IMP)factory);
    method_setImplementation(doneMethod, (IMP)done);
    method_setImplementation(finishMethod, (IMP)finish);
    installed = YES;
    return 1;
}
#ifndef REA_FLOW_TESTING
@interface ScannerREAFlowBootstrap : NSObject @end
@implementation ScannerREAFlowBootstrap
+ (void)load { REAInstallFlowHooks(); }
@end
#endif
