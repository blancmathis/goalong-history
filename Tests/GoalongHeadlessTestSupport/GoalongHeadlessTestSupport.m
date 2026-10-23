// Test-only: keeps `swift test` invisible to the person working on this Mac.
// While the xctest process runs, every NSWindow stays at real alpha 0 and ignores the mouse,
// the app never activates, never gets a Dock icon, never changes the system presentation
// options, and NSWorkspace opens nothing. Getters return the logical values the code set, so
// assertions and cacheDisplay snapshots stay unchanged; system frameworks get the real values. GOALONG_TESTS_VISIBLE=1 disables it.
#import "GoalongHeadlessTestSupport.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <pwd.h>
#import <unistd.h>
#import <objc/runtime.h>

static const void *kLogicalAlpha = &kLogicalAlpha;
static const void *kLogicalIgnoresMouse = &kLogicalIgnoresMouse;
static NSNumber *logicalPolicy;
static NSNumber *logicalPresentation;

static void headlessLog(NSString *kind, NSString *detail) {
    fprintf(stderr, "[headless-tests] blocked %s: %s\n", kind.UTF8String, detail.UTF8String);
}

// AppKit reads these getters itself (for example to fade a sheet or its parent window in) and
// pushes the result to the window server: system callers must see the real value.
static BOOL calledBySystem(const void *returnAddress) {
    Dl_info info;
    if (!dladdr(returnAddress, &info) || !info.dli_fname) return YES;
    return strncmp(info.dli_fname, "/System/", 8) == 0 || strncmp(info.dli_fname, "/usr/lib/", 9) == 0;
}

static IMP replace(Class cls, SEL sel, id block) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
    return original;
}

static void runCompletion(void (^completion)(NSRunningApplication *, NSError *)) {
    if (!completion) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(NSRunningApplication.currentApplication, nil);
    });
}

static void (*setAlpha)(id, SEL, CGFloat);
static CGFloat (*getAlpha)(id, SEL);
static void (*setIgnores)(id, SEL, BOOL);
static BOOL (*getIgnores)(id, SEL);

// Remembers the values the code asked for, then makes the window really transparent and click-through.
static void hide(NSWindow *w) {
    if (!w || objc_getAssociatedObject(w, kLogicalAlpha)) return;
    objc_setAssociatedObject(w, kLogicalAlpha, @(getAlpha(w, @selector(alphaValue))), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(w, kLogicalIgnoresMouse, @(getIgnores(w, @selector(ignoresMouseEvents))), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    setAlpha(w, @selector(setAlphaValue:), 0);
    setIgnores(w, @selector(setIgnoresMouseEvents:), YES);
}

static void hideWindows(void) {
    static id (*initRect)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL);
    static id (*initRectScreen)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL, NSScreen *);
    Class window = NSWindow.class;

    getAlpha = (void *)replace(window, @selector(alphaValue), ^CGFloat(NSWindow *w) {
        NSNumber *logical = calledBySystem(__builtin_return_address(0)) ? nil : objc_getAssociatedObject(w, kLogicalAlpha);
        return logical ? logical.doubleValue : getAlpha(w, @selector(alphaValue));
    });
    setAlpha = (void *)replace(window, @selector(setAlphaValue:), ^(NSWindow *w, CGFloat value) {
        objc_setAssociatedObject(w, kLogicalAlpha, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        setAlpha(w, @selector(setAlphaValue:), 0);
    });
    getIgnores = (void *)replace(window, @selector(ignoresMouseEvents), ^BOOL(NSWindow *w) {
        NSNumber *logical = calledBySystem(__builtin_return_address(0)) ? nil : objc_getAssociatedObject(w, kLogicalIgnoresMouse);
        return logical ? logical.boolValue : getIgnores(w, @selector(ignoresMouseEvents));
    });
    setIgnores = (void *)replace(window, @selector(setIgnoresMouseEvents:), ^(NSWindow *w, BOOL value) {
        objc_setAssociatedObject(w, kLogicalIgnoresMouse, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        setIgnores(w, @selector(setIgnoresMouseEvents:), YES);
    });
    initRect = (void *)replace(window, @selector(initWithContentRect:styleMask:backing:defer:),
        ^id(NSWindow *w, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing, BOOL deferred) {
            NSWindow *result = initRect(w, @selector(initWithContentRect:styleMask:backing:defer:), rect, style, backing, deferred);
            hide(result);
            return result;
        });
    initRectScreen = (void *)replace(window, @selector(initWithContentRect:styleMask:backing:defer:screen:),
        ^id(NSWindow *w, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing, BOOL deferred, NSScreen *screen) {
            NSWindow *result = initRectScreen(w, @selector(initWithContentRect:styleMask:backing:defer:screen:), rect, style, backing, deferred, screen);
            hide(result);
            return result;
        });
}

static void blockActivation(void) {
    static BOOL (*setPolicy)(id, SEL, NSApplicationActivationPolicy);
    static NSApplicationActivationPolicy (*getPolicy)(id, SEL);
    static NSApplicationPresentationOptions (*getPresentation)(id, SEL);
    Class app = NSApplication.class;

    replace(app, @selector(activateIgnoringOtherApps:), ^(NSApplication *a, BOOL flag) {
        headlessLog(@"activation", @"NSApplication activateIgnoringOtherApps:");
    });
    replace(app, NSSelectorFromString(@"activate"), ^(NSApplication *a) {
        headlessLog(@"activation", @"NSApplication activate");
    });
    // A Dock icon is visible too: .regular really becomes .accessory.
    setPolicy = (void *)replace(app, @selector(setActivationPolicy:), ^BOOL(NSApplication *a, NSApplicationActivationPolicy policy) {
        logicalPolicy = @(policy);
        NSApplicationActivationPolicy real = policy == NSApplicationActivationPolicyRegular ? NSApplicationActivationPolicyAccessory : policy;
        setPolicy(a, @selector(setActivationPolicy:), real);
        return YES;
    });
    getPolicy = (void *)replace(app, @selector(activationPolicy), ^NSApplicationActivationPolicy(NSApplication *a) {
        if (calledBySystem(__builtin_return_address(0))) return getPolicy(a, @selector(activationPolicy));
        return logicalPolicy ? (NSApplicationActivationPolicy)logicalPolicy.integerValue : getPolicy(a, @selector(activationPolicy));
    });
    // Kiosk options (hidden Dock and menu bar) are system-wide: keep them logical only.
    replace(app, @selector(setPresentationOptions:), ^(NSApplication *a, NSApplicationPresentationOptions options) {
        logicalPresentation = @(options);
    });
    getPresentation = (void *)replace(app, @selector(presentationOptions), ^NSApplicationPresentationOptions(NSApplication *a) {
        if (calledBySystem(__builtin_return_address(0))) return getPresentation(a, @selector(presentationOptions));
        return logicalPresentation ? (NSApplicationPresentationOptions)logicalPresentation.unsignedIntegerValue
                                   : getPresentation(a, @selector(presentationOptions));
    });

    Class running = NSRunningApplication.class;
    replace(running, @selector(activateWithOptions:), ^BOOL(NSRunningApplication *r, NSApplicationActivationOptions options) {
        headlessLog(@"activation", [NSString stringWithFormat:@"NSRunningApplication activateWithOptions: %@", r.bundleIdentifier]);
        return YES;
    });
    replace(running, NSSelectorFromString(@"activateFromApplication:options:"), ^BOOL(NSRunningApplication *r, id from, NSApplicationActivationOptions options) {
        headlessLog(@"activation", [NSString stringWithFormat:@"NSRunningApplication activateFromApplication:options: %@", r.bundleIdentifier]);
        return YES;
    });
}

static void blockLaunchServices(void) {
    Class ws = NSWorkspace.class;
    replace(ws, @selector(openURL:), ^BOOL(NSWorkspace *w, NSURL *url) {
        headlessLog(@"open", [NSString stringWithFormat:@"openURL: %@", url]);
        return YES;
    });
    replace(ws, @selector(openURL:configuration:completionHandler:),
        ^(NSWorkspace *w, NSURL *url, id configuration, void (^completion)(NSRunningApplication *, NSError *)) {
            headlessLog(@"open", [NSString stringWithFormat:@"openURL:configuration: %@", url]);
            runCompletion(completion);
        });
    replace(ws, @selector(openURLs:withApplicationAtURL:configuration:completionHandler:),
        ^(NSWorkspace *w, NSArray<NSURL *> *urls, NSURL *application, id configuration, void (^completion)(NSRunningApplication *, NSError *)) {
            headlessLog(@"open", [NSString stringWithFormat:@"openURLs:withApplicationAtURL: %@ %@", urls, application]);
            runCompletion(completion);
        });
    replace(ws, @selector(openApplicationAtURL:configuration:completionHandler:),
        ^(NSWorkspace *w, NSURL *application, id configuration, void (^completion)(NSRunningApplication *, NSError *)) {
            headlessLog(@"open", [NSString stringWithFormat:@"openApplicationAtURL: %@", application]);
            runCompletion(completion);
        });
    replace(ws, @selector(activateFileViewerSelectingURLs:), ^(NSWorkspace *w, NSArray<NSURL *> *urls) {
        headlessLog(@"open", [NSString stringWithFormat:@"activateFileViewerSelectingURLs: %@", urls]);
    });
    replace(ws, @selector(selectFile:inFileViewerRootedAtPath:), ^BOOL(NSWorkspace *w, NSString *path, NSString *root) {
        headlessLog(@"open", [NSString stringWithFormat:@"selectFile: %@", path]);
        return YES;
    });
    replace(ws, NSSelectorFromString(@"openFile:"), ^BOOL(NSWorkspace *w, NSString *path) {
        headlessLog(@"open", [NSString stringWithFormat:@"openFile: %@", path]);
        return YES;
    });
    replace(ws, NSSelectorFromString(@"openFile:withApplication:"), ^BOOL(NSWorkspace *w, NSString *path, NSString *application) {
        headlessLog(@"open", [NSString stringWithFormat:@"openFile:withApplication: %@ %@", path, application]);
        return YES;
    });
    replace(ws, NSSelectorFromString(@"launchApplication:"), ^BOOL(NSWorkspace *w, NSString *application) {
        headlessLog(@"open", [NSString stringWithFormat:@"launchApplication: %@", application]);
        return YES;
    });
}

// Test suites: every `UserDefaults(suiteName:)` made while the tests run is remembered when its
// plist did not exist yet. At exit (and on demand) the plist is deleted again, so a bare
// `swift test` leaves no `<suite>.plist` in ~/Library/Preferences. A plist that already existed
// (the owner's real suites) is never recorded and never touched, and only UUID-named suites are
// recorded at all. SIGINT, SIGTERM, SIGHUP and crashes (SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL) clean too through an async-signal-safe handler; SIGKILL cannot be caught: use scripts/clean_leaked_test_prefs.sh.
static NSMutableSet<NSString *> *createdSuites;
static NSLock *suiteLock;
// The same plist paths as plain C strings, for the crash handler: it may only call
// async-signal-safe functions (unlink), never Objective-C, malloc or locks.
#define kMaxCrashPaths 4096
static char *crashPaths[kMaxCrashPaths];
static volatile int crashPathCount;

// Only names a test made unique with a UUID are ever recorded. A real domain name (an app bundle
// id, a production suite) never matches, so the hook can never delete the owner's real defaults.
static BOOL isTestSuiteName(NSString *name) {
    static NSRegularExpression *uuid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uuid = [NSRegularExpression regularExpressionWithPattern:@"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
                                                         options:0 error:nil];
    });
    return [uuid firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

// cfprefsd ignores CFFIXED_USER_HOME: suite plists land in the account's real home, so that is
// the folder to look at (NSHomeDirectory() would point at the throwaway home and see nothing).
static NSString *realHomeDirectory(void) {
    struct passwd *entry = getpwuid(getuid());
    return entry && entry->pw_dir ? [NSString stringWithUTF8String:entry->pw_dir] : NSHomeDirectory();
}

static NSString *suitePlistPath(NSString *name) {
    if ([name containsString:@"/"] || name.length == 0) return nil;
    return [[realHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"]
        stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]];
}

static void trackSuites(void) {
    createdSuites = [NSMutableSet set];
    suiteLock = [[NSLock alloc] init];
    static id (*initSuite)(id, SEL, NSString *);
    initSuite = (void *)replace(NSUserDefaults.class, @selector(initWithSuiteName:), ^id(NSUserDefaults *d, NSString *name) {
        NSString *path = (name && isTestSuiteName(name)) ? suitePlistPath(name) : nil;
        if (path && ![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [suiteLock lock];
            [createdSuites addObject:name];
            if (crashPathCount < kMaxCrashPaths) {
                crashPaths[crashPathCount] = strdup(path.fileSystemRepresentation);
                __sync_synchronize();   // the pointer is written before the count that publishes it
                crashPathCount++;
            }
            [suiteLock unlock];
        }
        return initSuite(d, @selector(initWithSuiteName:), name);
    });
}

NSString *GoalongHeadlessSuitePlistPath(NSString *name) { return suitePlistPath(name); }

// Deletes the plist files only. Asking cfprefsd to remove the domain (removePersistentDomain) makes it
// write the empty domain back a moment later, which re-creates the file after the cleanup.
static void unlinkSuitePlists(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        NSString *path = suitePlistPath(name);
        if (path) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
}

void GoalongHeadlessCleanLeakedDefaultSuites(void) {
    [suiteLock lock];
    NSArray<NSString *> *names = createdSuites.allObjects;
    [createdSuites removeAllObjects];
    [suiteLock unlock];
    unlinkSuitePlists(names);
}

// At exit a write already queued in cfprefsd can still land: look again once after a short pause.
static void cleanAtExit(void) {
    [suiteLock lock];
    NSArray<NSString *> *names = createdSuites.allObjects;
    [suiteLock unlock];
    unlinkSuitePlists(names);
    if (names.count > 0) { usleep(300 * 1000); unlinkSuitePlists(names); }
}

// Only this suite, and only when this run created it: other tests' suites stay tracked.
void GoalongHeadlessCleanLeakedDefaultSuite(NSString *name) {
    [suiteLock lock];
    // Stays recorded: a queued cfprefsd write can re-create the file, the exit cleanup removes it again.
    BOOL tracked = [createdSuites containsObject:name];
    [suiteLock unlock];
    if (tracked) unlinkSuitePlists(@[name]);
}

// Ctrl-C, a timeout kill or a crash: delete the recorded plists with unlink() only (async-signal-safe),
// then let the default action end the process.
static void cleanOnSignal(int sig) {
    int count = crashPathCount;
    for (int i = 0; i < count && i < kMaxCrashPaths; i++) {
        if (crashPaths[i]) unlink(crashPaths[i]);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

// Gallery guards (`make gallery`, `GallerySmokeTests`). Installed once at load, active only between
// GoalongGalleryGuardsBegin() and GoalongGalleryGuardsTake(). While active: ordering a window
// on screen, presenting a sheet or a modal and creating a status item are refused and recorded;
// every URL request fails and is counted; launching an NSTask is refused and counted; and
// +[NSUserDefaults standardUserDefaults] called from the test bundle returns a throwaway suite and
// is counted, with the stack of the first call. Outside a session every method behaves as before.
static volatile BOOL galleryActive;
static NSMutableArray<NSString *> *galleryViolations;
static NSInteger galleryNetwork, galleryTasks, galleryStandard;
static NSString *galleryStandardStack;
static NSUserDefaults *galleryStandardSuite;
static NSLock *galleryLock;
static const char *ownImage;

static void galleryRecord(NSString *kind, NSString *detail) {
    [galleryLock lock];
    [galleryViolations addObject:[NSString stringWithFormat:@"%@: %@", kind, detail]];
    [galleryLock unlock];
    fprintf(stderr, "[gallery-guard] refused %s: %s\n", kind.UTF8String, detail.UTF8String);
}

static BOOL calledByTestBundle(const void *returnAddress) {
    Dl_info info;
    if (!ownImage || !dladdr(returnAddress, &info) || !info.dli_fname) return NO;
    return strcmp(info.dli_fname, ownImage) == 0;
}

@interface GoalongGalleryURLProtocol : NSURLProtocol
@end
@implementation GoalongGalleryURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!galleryActive) return NO;
    [galleryLock lock]; galleryNetwork++; [galleryLock unlock];
    fprintf(stderr, "[gallery-guard] refused request: %s\n", request.URL.absoluteString.UTF8String);
    return YES;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
}
- (void)stopLoading {}
@end

static NSURLSessionConfiguration *guardedConfiguration(NSURLSessionConfiguration *configuration) {
    if (!configuration) return configuration;
    NSMutableArray *classes = [configuration.protocolClasses mutableCopy] ?: [NSMutableArray array];
    if (![classes containsObject:GoalongGalleryURLProtocol.class]) [classes insertObject:GoalongGalleryURLProtocol.class atIndex:0];
    configuration.protocolClasses = classes;
    return configuration;
}

static IMP replaceClassMethod(Class cls, SEL sel, id block) {
    return replace(object_getClass(cls), sel, block);
}

static void installGalleryGuards(void) {
    galleryViolations = [NSMutableArray array];
    galleryLock = [[NSLock alloc] init];
    Dl_info info;
    if (dladdr((const void *)&installGalleryGuards, &info) && info.dli_fname) ownImage = strdup(info.dli_fname);
    [NSURLProtocol registerClass:GoalongGalleryURLProtocol.class];

    Class window = NSWindow.class;
    static void (*orderFront)(id, SEL, id);
    static void (*orderFrontRegardless)(id, SEL);
    static void (*makeKeyAndOrderFront)(id, SEL, id);
    static void (*beginSheet)(id, SEL, NSWindow *, id);
    static void (*beginCriticalSheet)(id, SEL, NSWindow *, id);
    orderFront = (void *)replace(window, @selector(orderFront:), ^(NSWindow *w, id sender) {
        if (galleryActive) { galleryRecord(@"orderFront:", NSStringFromClass(w.class)); return; }
        orderFront(w, @selector(orderFront:), sender);
    });
    orderFrontRegardless = (void *)replace(window, @selector(orderFrontRegardless), ^(NSWindow *w) {
        if (galleryActive) { galleryRecord(@"orderFrontRegardless", NSStringFromClass(w.class)); return; }
        orderFrontRegardless(w, @selector(orderFrontRegardless));
    });
    makeKeyAndOrderFront = (void *)replace(window, @selector(makeKeyAndOrderFront:), ^(NSWindow *w, id sender) {
        if (galleryActive) { galleryRecord(@"makeKeyAndOrderFront:", NSStringFromClass(w.class)); return; }
        makeKeyAndOrderFront(w, @selector(makeKeyAndOrderFront:), sender);
    });
    beginSheet = (void *)replace(window, @selector(beginSheet:completionHandler:), ^(NSWindow *w, NSWindow *sheet, id handler) {
        if (galleryActive) { galleryRecord(@"beginSheet:completionHandler:", NSStringFromClass(sheet.class)); return; }
        beginSheet(w, @selector(beginSheet:completionHandler:), sheet, handler);
    });
    beginCriticalSheet = (void *)replace(window, @selector(beginCriticalSheet:completionHandler:), ^(NSWindow *w, NSWindow *sheet, id handler) {
        if (galleryActive) { galleryRecord(@"beginCriticalSheet:completionHandler:", NSStringFromClass(sheet.class)); return; }
        beginCriticalSheet(w, @selector(beginCriticalSheet:completionHandler:), sheet, handler);
    });

    static NSModalResponse (*runModalForWindow)(id, SEL, NSWindow *);
    runModalForWindow = (void *)replace(NSApplication.class, @selector(runModalForWindow:), ^NSModalResponse(NSApplication *a, NSWindow *w) {
        if (galleryActive) { galleryRecord(@"runModalForWindow:", NSStringFromClass(w.class)); return NSModalResponseAbort; }
        return runModalForWindow(a, @selector(runModalForWindow:), w);
    });
    static NSModalResponse (*alertRunModal)(id, SEL);
    static void (*alertBeginSheet)(id, SEL, NSWindow *, id);
    alertRunModal = (void *)replace(NSAlert.class, @selector(runModal), ^NSModalResponse(NSAlert *alert) {
        if (galleryActive) { galleryRecord(@"NSAlert runModal", alert.messageText ?: @""); return NSAlertFirstButtonReturn; }
        return alertRunModal(alert, @selector(runModal));
    });
    alertBeginSheet = (void *)replace(NSAlert.class, @selector(beginSheetModalForWindow:completionHandler:), ^(NSAlert *alert, NSWindow *w, id handler) {
        if (galleryActive) { galleryRecord(@"NSAlert beginSheetModalForWindow:", alert.messageText ?: @""); return; }
        alertBeginSheet(alert, @selector(beginSheetModalForWindow:completionHandler:), w, handler);
    });
    static id (*statusItem)(id, SEL, CGFloat);
    statusItem = (void *)replace(NSStatusBar.class, @selector(statusItemWithLength:), ^id(NSStatusBar *bar, CGFloat length) {
        if (galleryActive) { galleryRecord(@"NSStatusBar statusItemWithLength:", @"menu bar item"); return nil; }
        return statusItem(bar, @selector(statusItemWithLength:), length);
    });

    static BOOL (*launchAndReturnError)(id, SEL, NSError **);
    static void (*launch)(id, SEL);
    launchAndReturnError = (void *)replace(NSTask.class, @selector(launchAndReturnError:), ^BOOL(NSTask *task, NSError **error) {
        if (galleryActive) {
            [galleryLock lock]; galleryTasks++; [galleryLock unlock];
            fprintf(stderr, "[gallery-guard] refused NSTask: %s\n", task.executableURL.path.UTF8String ?: "?");
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil];
            return NO;
        }
        return launchAndReturnError(task, @selector(launchAndReturnError:), error);
    });
    launch = (void *)replace(NSTask.class, @selector(launch), ^(NSTask *task) {
        if (galleryActive) {
            [galleryLock lock]; galleryTasks++; [galleryLock unlock];
            fprintf(stderr, "[gallery-guard] refused NSTask launch: %s\n", task.launchPath.UTF8String ?: "?");
            return;
        }
        launch(task, @selector(launch));
    });

    static id (*sessionWithConfiguration)(id, SEL, NSURLSessionConfiguration *);
    static id (*sessionWithConfigurationDelegate)(id, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *);
    sessionWithConfiguration = (void *)replaceClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:),
        ^id(id cls, NSURLSessionConfiguration *configuration) {
            return sessionWithConfiguration(cls, @selector(sessionWithConfiguration:), galleryActive ? guardedConfiguration(configuration) : configuration);
        });
    sessionWithConfigurationDelegate = (void *)replaceClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:delegate:delegateQueue:),
        ^id(id cls, NSURLSessionConfiguration *configuration, id delegate, NSOperationQueue *queue) {
            return sessionWithConfigurationDelegate(cls, @selector(sessionWithConfiguration:delegate:delegateQueue:),
                galleryActive ? guardedConfiguration(configuration) : configuration, delegate, queue);
        });

    static id (*standardDefaults)(id, SEL);
    standardDefaults = (void *)replaceClassMethod(NSUserDefaults.class, @selector(standardUserDefaults), ^id(id cls) {
        if (galleryActive && calledByTestBundle(__builtin_return_address(0))) {
            [galleryLock lock];
            galleryStandard++;
            if (!galleryStandardStack) galleryStandardStack = [NSThread.callStackSymbols componentsJoinedByString:@"\n"];
            NSUserDefaults *suite = galleryStandardSuite;
            [galleryLock unlock];
            if (suite) return suite;
        }
        return standardDefaults(cls, @selector(standardUserDefaults));
    });
}

void GoalongGalleryGuardsBegin(void) {
    // A fresh, empty suite each session (UUID name: the suite tracker deletes its plist).
    NSString *name = [@"goalong-gallery-standard-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:name];
    [galleryLock lock];
    [galleryViolations removeAllObjects];
    galleryNetwork = 0; galleryTasks = 0; galleryStandard = 0; galleryStandardStack = nil;
    galleryStandardSuite = suite;
    [galleryLock unlock];
    galleryActive = YES;
}

NSDictionary<NSString *, id> *GoalongGalleryGuardsTake(void) {
    galleryActive = NO;
    [galleryLock lock];
    NSDictionary *report = @{
        @"violations": [galleryViolations copy] ?: @[],
        @"network": @(galleryNetwork), @"tasks": @(galleryTasks), @"standardDefaults": @(galleryStandard),
        @"standardStack": galleryStandardStack ?: @"",
    };
    [galleryViolations removeAllObjects];
    galleryNetwork = 0; galleryTasks = 0; galleryStandard = 0; galleryStandardStack = nil;
    galleryStandardSuite = nil;
    [galleryLock unlock];
    return report;
}

BOOL GoalongGalleryGuardsInstalled(void) { return galleryLock != nil; }

@interface GoalongHeadlessTestSupport : NSObject
@end

@implementation GoalongHeadlessTestSupport
+ (void)load {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    if (!NSClassFromString(@"XCTestCase") && !environment[@"XCTestConfigurationFilePath"]) return;
    trackSuites();
    atexit(cleanAtExit);
    static const int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL};
    for (size_t i = 0; i < sizeof signals / sizeof signals[0]; i++) signal(signals[i], cleanOnSignal);
    if ([environment[@"GOALONG_TESTS_VISIBLE"] isEqualToString:@"1"]) return;
    installGalleryGuards();
    hideWindows();
    blockActivation();
    blockLaunchServices();
    fprintf(stderr, "[headless-tests] active: windows hidden, activation and LaunchServices opens blocked\n");
}
@end
