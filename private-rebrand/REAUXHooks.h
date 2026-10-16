#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

static inline BOOL REAType(char *type, const char *allowed) {
    BOOL ok = type && type[0] && strchr(allowed, type[0]);
    free(type);
    return ok;
}
static inline BOOL REASignature(Method method, const char *result, NSArray<NSString *> *arguments) {
    if (!method || method_getNumberOfArguments(method) != arguments.count + 2) return NO;
    if (!REAType(method_copyReturnType(method), result)) return NO;
    for (unsigned i = 0; i < arguments.count; i++)
        if (!REAType(method_copyArgumentType(method, i + 2), arguments[i].UTF8String)) return NO;
    return YES;
}
static inline BOOL REAHook(Class cls, const char *name, const char *result,
                           NSArray<NSString *> *arguments, IMP replacement, IMP *original) {
    if (!cls) return NO;
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!REASignature(method, result, arguments)) return NO;
    IMP current = method_getImplementation(method);
    if (current == replacement) return YES;
    if (original && *original) return NO;
    if (original) *original = current;
    // Add an override for inherited methods; never replace the superclass globally.
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
    return YES;
}

