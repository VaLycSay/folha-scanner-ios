#import <Foundation/Foundation.h>
#import <objc/runtime.h>
extern int REAInstallFlowHooks(void);
static unsigned checks;
static void check(BOOL value, NSString *name) {
    checks++;
    if (!value) { NSLog(@"FAIL: %@", name); exit(1); }
}
@interface TestConfiguration : NSObject
@property NSInteger currentModel;
@property NSInteger modeMask;
@property BOOL retakeMode;
@end
@implementation TestConfiguration @end
@interface CSImagePickerCameraFactory : NSObject
@property NSUInteger originalCalls;
- (id)createConfigurationWithMode:(NSInteger)mode fromController:(id)controller extra:(id)extra;
@end
@implementation CSImagePickerCameraFactory
- (id)createConfigurationWithMode:(NSInteger)mode fromController:(id)controller extra:(id)extra {
    self.originalCalls++;
    if ([extra[@"nil"] boolValue]) return nil;
    TestConfiguration *result = [TestConfiguration new];
    result.currentModel = mode;
    result.modeMask = extra[@"mask"] ? [extra[@"mask"] integerValue] : 0x2e3;
    result.retakeMode = [extra[@"retake"] boolValue];
    return result;
}
@end
@interface ISCustomCameraImagePickerController : NSObject
@property NSInteger currentImagePickerMode;
@property(getter=isRetakeMode) BOOL retakeMode;
@property BOOL needPreviewInMultiTake;
@property(strong) NSArray *selectedImagePaths;
@property NSUInteger previews;
@property NSUInteger saves;
@property NSUInteger originalDoneCalls;
@property NSUInteger originalFinishCalls;
- (void)doneButtonDidClicked:(id)sender;
- (void)previewController:(id)controller finishMultiTakePhoto:(id)pages;
@end
@implementation ISCustomCameraImagePickerController
- (void)doneButtonDidClicked:(id)sender {
    self.originalDoneCalls++;
    if (self.needPreviewInMultiTake) self.previews++; else self.saves++;
}
- (void)previewController:(id)controller finishMultiTakePhoto:(id)pages {
    self.originalFinishCalls++;
    [self doneButtonDidClicked:nil];
}
@end
int main(void) {
    @autoreleasepool {
        Method finish = class_getInstanceMethod([ISCustomCameraImagePickerController class], @selector(previewController:finishMultiTakePhoto:));
        IMP originalFinish = method_getImplementation(finish);
        check(REAInstallFlowHooks() == 1, @"install the two flow hooks");
        check(REAInstallFlowHooks() == 1, @"idempotent installation");
        check(method_getImplementation(finish) == originalFinish, @"optional native review callback not hooked");
        CSImagePickerCameraFactory *maker = [CSImagePickerCameraFactory new];
        for (NSInteger mode = -1; mode <= 13; mode++) {
            TestConfiguration *config = [maker createConfigurationWithMode:mode fromController:nil extra:@{}];
            check(config.currentModel == (mode <= 1 ? 2 : mode), @"normal entry and explicit modes");
            config = [maker createConfigurationWithMode:mode fromController:nil extra:@{@"retake":@YES}];
            check(config.currentModel == mode, @"retake keeps original mode");
        }
        check(maker.originalCalls == 30, @"original factory called once per entry");
        TestConfiguration *singleOnly = [maker createConfigurationWithMode:1 fromController:nil extra:@{@"mask":@1}];
        check(singleOnly.currentModel == 1, @"single-only camera preserved");
        check([maker createConfigurationWithMode:1 fromController:nil extra:@{@"nil":@YES}] == nil, @"nil config preserved");
        ISCustomCameraImagePickerController *camera = [ISCustomCameraImagePickerController new];
        camera.currentImagePickerMode = 2;
        camera.selectedImagePaths = @[@"one", @"two", @"three"];
        camera.needPreviewInMultiTake = YES;
        [camera doneButtonDidClicked:nil];
        check(camera.saves == 1 && camera.previews == 0, @"batch goes directly to native save path");
        check(camera.originalDoneCalls == 1, @"single completion dispatch");
        [camera doneButtonDidClicked:nil];
        check(camera.saves == 2 && camera.previews == 0, @"subsequent batch does not force review");
        [camera previewController:nil finishMultiTakePhoto:camera.selectedImagePaths];
        check(camera.originalFinishCalls == 1 && camera.saves == 3, @"manually entered review can still finish");
        camera.currentImagePickerMode = 1; camera.needPreviewInMultiTake = YES;
        [camera doneButtonDidClicked:nil];
        check(camera.needPreviewInMultiTake, @"single-image flow unchanged");
        camera.currentImagePickerMode = 2; camera.retakeMode = YES;
        [camera doneButtonDidClicked:nil];
        check(camera.needPreviewInMultiTake, @"retake flow unchanged");
        camera.retakeMode = NO; camera.selectedImagePaths = @[];
        [camera doneButtonDidClicked:nil];
        check(camera.needPreviewInMultiTake, @"empty batch left to original validation");
        camera.selectedImagePaths = @[@"one"];
        [camera doneButtonDidClicked:nil];
        check(!camera.needPreviewInMultiTake, @"one-page batch also uses direct save path");
        check(camera.originalDoneCalls == 7, @"one original call for each requested completion");
        printf("PASS %u own-adapter assertions; original iPhone application not executed.\n", checks);
    }
    return 0;
}

