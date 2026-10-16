#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#include <string.h>

static id (*originalFactory)(id, SEL, NSInteger, id, id);
static void (*originalDone)(id, SEL, id);
static BOOL has(id object, const char *name) {
    return object && [object respondsToSelector:sel_registerName(name)];
}
static NSInteger integer(id object, const char *name) {
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}
static BOOL boolean(id object, const char *name) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}
static id factory(id self, SEL selector, NSInteger mode, id controller, id extra) {
    id config = originalFactory(self, selector, mode, controller, extra);
    if (has(config, "currentModel") && has(config, "retakeMode") &&
        has(config, "modeMask") && has(config, "setCurrentModel:")) {
        if (integer(config, "currentModel") <= 1 &&
            !boolean(config, "retakeMode") && (integer(config, "modeMask") & 2) != 0) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                config, sel_registerName("setCurrentModel:"), 2);
        }
    }
    return config;
}
static void done(id self, SEL selector, id sender) {
    if (has(self, "currentImagePickerMode") && has(self, "isRetakeMode") &&
        has(self, "selectedImagePaths") && has(self, "setNeedPreviewInMultiTake:") &&
        integer(self, "currentImagePickerMode") == 2 &&
        !boolean(self, "isRetakeMode")) {
        id pages = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("selectedImagePaths"));
        if ([pages respondsToSelector:@selector(count)] && [pages count] > 0) {
            // Follow native saving; do not force another confirmation screen.
            // Native thumbnail and editing actions remain untouched.
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                self, sel_registerName("setNeedPreviewInMultiTake:"), NO);
        }
    }
    originalDone(self, selector, sender);
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
    if (!valid(factoryMethod, 5, "@", "qQiI") || !valid(doneMethod, 3, "v", "@")) return 0;
    originalFactory = (void *)method_getImplementation(factoryMethod);
    originalDone = (void *)method_getImplementation(doneMethod);
    method_setImplementation(factoryMethod, (IMP)factory);
    method_setImplementation(doneMethod, (IMP)done);
    installed = YES;
    return 1;
}
#ifndef REA_FLOW_TESTING
@interface ScannerREAFlowBootstrap : NSObject @end
@implementation ScannerREAFlowBootstrap
+ (void)load { REAInstallFlowHooks(); }
@end
#endif

