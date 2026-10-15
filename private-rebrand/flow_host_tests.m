#import <Foundation/Foundation.h>
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
@property NSArray *selectedImagePaths;
@property NSUInteger previews;
@property NSUInteger saves;
@property NSUInteger captures;
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
        check(REAInstallFlowHooks() == 1, @"install all verified hooks");
        check(REAInstallFlowHooks() == 1, @"idempotent installation");
        CSImagePickerCameraFactory *maker = [CSImagePickerCameraFactory new];
        for (NSInteger mode = -1; mode <= 13; mode++) {
            TestConfiguration *config = [maker createConfigurationWithMode:mode fromController:nil extra:@{}];
            check(config.currentModel == (mode <= 1 ? 2 : mode), @"normal entry defaults and explicit modes");
            config = [maker createConfigurationWithMode:mode fromController:nil extra:@{@"retake":@YES}];
            check(config.currentModel == mode, @"retakes preserve their mode");
        }
        check(maker.originalCalls == 30, @"original factory called once per entry");
        TestConfiguration *singleOnly = [maker createConfigurationWithMode:1 fromController:nil extra:@{@"mask":@1}];
        check(singleOnly.currentModel == 1, @"single-only mask preserved");
        check([maker createConfigurationWithMode:1 fromController:nil extra:@{@"nil":@YES}] == nil, @"nil configuration preserved");
        ISCustomCameraImagePickerController *camera = [ISCustomCameraImagePickerController new];
        camera.currentImagePickerMode = 2;
        camera.selectedImagePaths = @[@"page1", @"page2", @"page3"];
        check(camera.previews == 0 && camera.originalDoneCalls == 0, @"no review before explicit completion");
        [camera doneButtonDidClicked:nil];
        check(camera.previews == 1 && camera.saves == 0, @"done enters review instead of saving");
        [camera previewController:nil finishMultiTakePhoto:camera.selectedImagePaths];
        check(camera.originalFinishCalls == 1 && camera.saves == 1 && camera.previews == 1, @"finish saves once without reopening review");
        [camera doneButtonDidClicked:nil];
        check(camera.previews == 2, @"next batch may review again");
        camera.needPreviewInMultiTake = NO;
        camera.currentImagePickerMode = 1;
        [camera doneButtonDidClicked:nil];
        check(!camera.needPreviewInMultiTake, @"single mode unchanged");
        camera.currentImagePickerMode = 2; camera.retakeMode = YES;
        [camera doneButtonDidClicked:nil];
        check(!camera.needPreviewInMultiTake, @"retake review unchanged");
        camera.retakeMode = NO; camera.selectedImagePaths = @[];
        [camera doneButtonDidClicked:nil];
        check(!camera.needPreviewInMultiTake, @"empty batch validation left to original");
        camera.selectedImagePaths = @[@"page4"];
        [camera doneButtonDidClicked:nil];
        check(camera.needPreviewInMultiTake, @"one-page batch still reviews");
        check(camera.originalDoneCalls == 7, @"exactly one original call per action");
        printf("PASS %u own-adapter assertions; original application and camera not executed.\n", checks);
    }
    return 0;
}
