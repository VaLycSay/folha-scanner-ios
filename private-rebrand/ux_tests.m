#import <UIKit/UIKit.h>
#import <objc/runtime.h>
extern int REAInstallUXHooks(void);
extern int REAInstallContinuousHooks(void);
extern BOOL REAEnsureContinuousCapture(id);
extern BOOL REAInvokeNativeObjectAction(id, SEL, id);
extern NSDictionary *REAReadCaptureMetrics(id);
static NSUInteger checks;
static NSMutableArray *failures;
static void check(BOOL value, NSString *label) { checks++; if (!value) [failures addObject:label]; }

@interface CSMainViewController : UIViewController
@property NSUInteger purchases;
- (void)loadPremiumAccountBuyViewController;
@end
@implementation CSMainViewController
- (void)loadPremiumAccountBuyViewController { self.purchases++; }
@end
@interface PageListViewController : UIViewController
@property(strong) UICollectionView *collectionView;
@property NSUInteger dragCalls;
@property NSUInteger selectionCalls;
@property NSUInteger bannerCalls;
- (void)beginDragSort:(id)sender;
- (void)selectButtonClick:(id)sender;
- (void)endEditingTableView:(id)sender;
- (void)createAndLayoutAdBannerContainerView:(BOOL)animated;
@end
@implementation PageListViewController
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:[UICollectionViewFlowLayout new]];
    [self.view addSubview:self.collectionView];
}
- (void)beginDragSort:(id)sender { self.dragCalls++; self.collectionView.allowsMultipleSelection = YES; }
- (void)selectButtonClick:(id)sender { self.selectionCalls++; self.collectionView.allowsMultipleSelection = YES; }
- (void)endEditingTableView:(id)sender { self.collectionView.allowsMultipleSelection = NO; }
- (void)createAndLayoutAdBannerContainerView:(BOOL)animated { self.bannerCalls++; }
@end
@interface CSPagePreviewViewController : UIViewController
@property(strong) UIButton *nativeEdit;
@property NSUInteger editCalls;
@property NSInteger currentPageIndex;
- (void)editingPage:(id)sender;
- (void)updateToolbarEnabled;
@end
@implementation CSPagePreviewViewController
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.nativeEdit = [UIButton buttonWithType:UIButtonTypeSystem];
    self.nativeEdit.frame = CGRectMake(20, 180, 120, 44);
    [self.nativeEdit setTitle:@"Native edit" forState:UIControlStateNormal];
    [self.nativeEdit addTarget:self action:@selector(editingPage:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.nativeEdit];
}
- (void)editingPage:(id)sender { if (sender == self.nativeEdit) self.editCalls++; }
- (void)updateToolbarEnabled {}
@end
@interface CSEditViewController : UIViewController
@property NSUInteger saveCalls;
- (void)done:(id)sender;
- (void)back:(id)sender;
@end
@implementation CSEditViewController
- (void)done:(id)sender { self.saveCalls++; }
- (void)back:(id)sender {}
@end
@interface CSMultiEditPageViewController : UIViewController
- (void)save:(id)sender;
@end
@implementation CSMultiEditPageViewController
- (void)save:(id)sender {}
@end
@interface TestToolbar : UIView
@property(strong) UIButton *cameraButton;
@end
@implementation TestToolbar
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.cameraButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.cameraButton.frame = CGRectMake(20, 10, 64, 64); [self addSubview:self.cameraButton];
    }
    return self;
}
@end
@interface ISCustomCameraImagePickerController : UIViewController
@property(strong) TestToolbar *toolbarView;
@property NSUInteger requested;
@property NSUInteger delivered;
@property NSUInteger willCount;
@property NSInteger currentImagePickerMode;
@property NSInteger imagePickerModeMask;
@property(getter=isRetakeMode) BOOL retakeMode;
@property(strong) id imagePickerDelegate;
@property(strong) NSMutableArray *selectedImagePaths;
@property NSUInteger modeTransitions;
@property NSUInteger editorOpenCount;
- (void)singleModeButtonDidClicked:(id)sender;
- (void)multiModeButtonDidClicked:(id)sender;
- (void)cameraButtonDidClicked:(id)sender;
- (void)captureManagerWillCaptureStillImage:(id)manager;
- (void)captureManager:(id)manager didCaptureStillImage:(id)data;
- (CGRect)previewLayerFrame;
@end
@implementation ISCustomCameraImagePickerController
- (instancetype)init {
    if ((self = [super init])) {
        self.currentImagePickerMode = 1; self.imagePickerModeMask = 3;
        self.selectedImagePaths = [NSMutableArray array];
    }
    return self;
}
- (void)singleModeButtonDidClicked:(id)sender { self.currentImagePickerMode = 1; }
- (void)multiModeButtonDidClicked:(id)sender { self.currentImagePickerMode = 2; self.modeTransitions++; }
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.toolbarView = [[TestToolbar alloc] initWithFrame:CGRectMake(0, 300, 220, 90)];
    [self.view addSubview:self.toolbarView];
}
- (void)cameraButtonDidClicked:(id)sender { self.requested++; }
- (void)captureManagerWillCaptureStillImage:(id)manager { self.willCount++; }
- (void)captureManager:(id)manager didCaptureStillImage:(id)data {
    self.delivered++;
    if (![data length]) return;
    if (self.currentImagePickerMode == 2) [self.selectedImagePaths addObject:data];
    else if (self.currentImagePickerMode == 1) self.editorOpenCount++;
}
- (CGRect)previewLayerFrame { return CGRectMake(0, 90, self.view.bounds.size.width, 300); }
@end
@interface TestBatchReceiver : NSObject
- (void)customImagePickerController:(id)camera didFinishPickingMultiImages:(id)images;
@end
@implementation TestBatchReceiver
- (void)customImagePickerController:(id)camera didFinishPickingMultiImages:(id)images {}
@end
@interface CSCameraPurchaseIDCardGuideView : UIView @end
@implementation CSCameraPurchaseIDCardGuideView @end
@interface CSCameraPurchaseOcrGuideView : UIView @end
@implementation CSCameraPurchaseOcrGuideView @end
@interface CSCameraPurchaseExcelGuideView : UIView @end
@implementation CSCameraPurchaseExcelGuideView @end
@interface CSCameraPurchaseCertifcationGuideView : UIView @end
@implementation CSCameraPurchaseCertifcationGuideView @end

static UIBarButtonItem *findItem(UIViewController *vc, NSString *identifier) {
    for (UIBarButtonItem *item in vc.navigationItem.rightBarButtonItems)
        if ([item.accessibilityIdentifier isEqual:identifier]) return item;
    return nil;
}
static void show(UIWindow *window, UIViewController *vc) {
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:vc];
    [window makeKeyAndVisible]; [vc loadViewIfNeeded]; [window layoutIfNeeded];
    [vc viewWillAppear:NO];
}
static void runTests(UIWindow *window) {
    IMP baseAppear = method_getImplementation(class_getInstanceMethod(UIViewController.class, @selector(viewWillAppear:)));
    IMP baseHidden = method_getImplementation(class_getInstanceMethod(UIView.class, @selector(setHidden:)));
    check(REAInstallContinuousHooks() == 2, @"native single/multi choices hooked");
    check(REAInstallUXHooks() >= 15, @"expected native-shaped surfaces available");
    check(REAInstallUXHooks() >= 15, @"idempotent installation");
    check(method_getImplementation(class_getInstanceMethod(UIViewController.class, @selector(viewWillAppear:))) == baseAppear, @"UIViewController not globally hooked");
    check(method_getImplementation(class_getInstanceMethod(UIView.class, @selector(setHidden:))) == baseHidden, @"UIView not globally hooked");

    PageListViewController *pages = [PageListViewController new];
    UIBarButtonItem *original = [[UIBarButtonItem alloc] initWithTitle:@"Original" style:0 target:nil action:nil];
    pages.navigationItem.rightBarButtonItems = @[original]; show(window, pages);
    UIBarButtonItem *menu = findItem(pages, @"scannerrea.pages");
    check(menu && menu.menu.children.count == 2, @"native reorder/select menu exposed");
    check([pages.navigationItem.rightBarButtonItems containsObject:original], @"original action retained");
    [pages viewWillAppear:NO];
    check(pages.navigationItem.rightBarButtonItems.count == 2, @"page menu not duplicated");
    check(REAInvokeNativeObjectAction(pages, @selector(beginDragSort:), nil), @"route native reorder");
    check(pages.dragCalls == 1, @"reorder called exactly once");
    [pages viewWillAppear:NO]; check(!findItem(pages, @"scannerrea.pages"), @"menu yields to native selection UI");
    [pages endEditingTableView:nil]; check(findItem(pages, @"scannerrea.pages") != nil, @"menu restored after native editing");
    check(REAInvokeNativeObjectAction(pages, @selector(selectButtonClick:), nil), @"route native selection");
    check(pages.selectionCalls == 1, @"selection called exactly once");
    [pages createAndLayoutAdBannerContainerView:NO]; check(pages.bannerCalls == 0, @"page advertisement not inserted");
    check(!REAInvokeNativeObjectAction(pages, NSSelectorFromString(@"notARealAction:"), nil), @"unsupported action rejected");

    CSPagePreviewViewController *viewer = [CSPagePreviewViewController new]; viewer.currentPageIndex = 7;
    show(window, viewer);
    UIBarButtonItem *edit = findItem(viewer, @"scannerrea.edit");
    check(edit != nil, @"viewer edit shortcut");
    viewer.nativeEdit.enabled = NO; [viewer updateToolbarEnabled];
    check(!edit.enabled, @"disabled native editor not bypassed");
    check(!REAInvokeNativeObjectAction(viewer, @selector(editingPage:), viewer.nativeEdit), @"disabled action rejected");
    viewer.nativeEdit.enabled = YES; [viewer updateToolbarEnabled];
    check(edit.enabled, @"native editor enablement mirrored");
    check(REAInvokeNativeObjectAction(viewer, @selector(editingPage:), viewer.nativeEdit), @"route original sender");
    check(viewer.editCalls == 1 && viewer.currentPageIndex == 7, @"page identity and handler retained");
    viewer.navigationItem.rightBarButtonItems = @[original]; [viewer viewWillAppear:NO];
    check(findItem(viewer, @"scannerrea.edit") != nil, @"shortcut survives native bar reconstruction");

    CSEditViewController *editor = [CSEditViewController new];
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"] style:0 target:editor action:@selector(done:)];
    save.enabled = NO; editor.navigationItem.rightBarButtonItems = @[save]; show(window, editor);
    check([save.title isEqual:@"Salvar"] && !save.image, @"explicit editor save label");
    check(save.target == editor && save.action == @selector(done:), @"native save action retained");
    check(!save.enabled, @"processing state not overridden");
    CSMultiEditPageViewController *multi = [CSMultiEditPageViewController new];
    UIBarButtonItem *multiSave = [[UIBarButtonItem alloc] initWithTitle:@"OK" style:0 target:multi action:@selector(save:)];
    multi.navigationItem.rightBarButtonItems = @[multiSave]; show(window, multi);
    check([multiSave.title isEqual:@"Salvar"], @"batch editor save label");

    CSMainViewController *main = [CSMainViewController new];
    UIBarButtonItem *buy = [[UIBarButtonItem alloc] initWithTitle:@"Offer" style:0 target:main action:@selector(loadPremiumAccountBuyViewController)];
    main.navigationItem.rightBarButtonItems = @[original, buy]; show(window, main);
    check(![main.navigationItem.rightBarButtonItems containsObject:buy], @"identified marketing action removed");
    check([main.navigationItem.rightBarButtonItems containsObject:original], @"unrelated navigation retained");
    for (Class cls in @[CSCameraPurchaseIDCardGuideView.class, CSCameraPurchaseOcrGuideView.class,
                       CSCameraPurchaseExcelGuideView.class, CSCameraPurchaseCertifcationGuideView.class]) {
        UIView *guide = [[cls alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
        [main.view addSubview:guide];
        check(guide.hidden, @"offer hidden on first window insertion");
        guide.hidden = NO;
        check(guide.hidden && !guide.userInteractionEnabled, @"offer cannot reappear via native visibility update");
        [guide removeFromSuperview];
    }
    UIView *ordinary = [UIView new]; ordinary.hidden = NO; check(!ordinary.hidden, @"ordinary views remain visible");

    ISCustomCameraImagePickerController *camera = [ISCustomCameraImagePickerController new];
    camera.imagePickerDelegate = [TestBatchReceiver new];
    show(window, camera);
    check(camera.currentImagePickerMode == 2 && camera.modeTransitions == 1, @"direct camera entry starts native batch without factory");
    [camera viewWillAppear:NO];
    check(camera.modeTransitions == 1, @"reappearing camera does not reset existing batch");
    [camera cameraButtonDidClicked:camera.toolbarView.cameraButton];
    check(camera.requested == 1, @"native shutter called exactly once");
    check([REAReadCaptureMetrics(camera)[@"pressFeedbackCount"] integerValue] == 1, @"immediate shutter response");
    [camera captureManagerWillCaptureStillImage:nil]; check(camera.willCount == 1, @"native pre-capture callback retained");
    [camera captureManager:nil didCaptureStillImage:[NSData data]];
    check(!REAReadCaptureMetrics(camera)[@"photoFeedbackCount"], @"empty photo does not announce success");
    [camera captureManager:nil didCaptureStillImage:[@"synthetic callback" dataUsingEncoding:NSUTF8StringEncoding]];
    NSDictionary *metrics = REAReadCaptureMetrics(camera);
    check(camera.delivered == 2, @"both native callbacks retained");
    check([metrics[@"photoFeedbackCount"] integerValue] == 1, @"valid photo confirmation");
    check(metrics[@"requestToImageMs"] && metrics[@"nativeHandlerMs"], @"separate local timing stages recorded");
    for (NSUInteger i = 0; i < 5; i++) {
        [camera cameraButtonDidClicked:camera.toolbarView.cameraButton];
        [camera captureManager:nil didCaptureStillImage:[NSData dataWithBytes:&i length:sizeof(i)]];
    }
    check(camera.selectedImagePaths.count == 6 && camera.editorOpenCount == 0, @"six continuous photos without opening editor");
    camera.currentImagePickerMode = 1;
    [camera captureManagerWillCaptureStillImage:nil];
    check(camera.currentImagePickerMode == 2, @"auto entry repairs later mode reset before native capture");
    [camera singleModeButtonDidClicked:nil]; [camera viewWillAppear:NO];
    check(camera.currentImagePickerMode == 1, @"explicit single choice respected on return");
    [camera multiModeButtonDidClicked:nil];
    check(REAEnsureContinuousCapture(camera), @"explicit batch choice restored");
    for (NSUInteger scenario = 0; scenario < 4; scenario++) {
        ISCustomCameraImagePickerController *guard = [ISCustomCameraImagePickerController new];
        guard.imagePickerDelegate = [TestBatchReceiver new];
        if (scenario == 0) guard.retakeMode = YES;
        if (scenario == 1) guard.imagePickerModeMask = 1;
        if (scenario == 2) guard.currentImagePickerMode = 3;
        if (scenario == 3) guard.imagePickerDelegate = [NSObject new];
        NSInteger before = guard.currentImagePickerMode; show(window, guard);
        check(guard.currentImagePickerMode == before && guard.modeTransitions == 0,
              @[@"retake unchanged", @"single-only unchanged", @"special mode unchanged", @"incompatible completion delegate unchanged"][scenario]);
    }
}
static void finishTests(void) {
    NSDictionary *result = @{@"status": failures.count ? @"failed" : @"passed", @"assertions": @(checks),
        @"failures": failures, @"scope": @"UIKit simulator with native-shaped test doubles; original app and physical camera not executed"};
    NSURL *dir = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[dir URLByAppendingPathComponent:@"ux-tests.json"] atomically:YES];
    NSLog(@"REA UIKit tests: %@", result);
    exit(failures.count ? 1 : 0);
}
@interface TestSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(strong) UIWindow *window;
@end
@implementation TestSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new]; [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        failures = [NSMutableArray array];
        @try { runTests(self.window); } @catch (NSException *exception) { [failures addObject:exception.description]; }
        finishTests();
    });
}
@end
@interface TestAppDelegate : UIResponder <UIApplicationDelegate> @end
@implementation TestAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TestAppDelegate.class)); }
}
