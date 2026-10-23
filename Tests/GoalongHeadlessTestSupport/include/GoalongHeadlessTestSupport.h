// Linked into the test bundles only. Its +load hook keeps test windows invisible and
// blocks activation and LaunchServices opens; no public API.
#import <Foundation/Foundation.h>

// Deletes the UserDefaults suite plists this test process created (also runs at exit).
// Suites whose plist existed before the process made them are never touched.
FOUNDATION_EXPORT void GoalongHeadlessCleanLeakedDefaultSuites(void);

// Same, for one suite name, and only when this process created it (other suites stay tracked).
FOUNDATION_EXPORT void GoalongHeadlessCleanLeakedDefaultSuite(NSString * _Nonnull name);

// Real path of the plist cfprefsd writes for a suite (the account home, not CFFIXED_USER_HOME).
FOUNDATION_EXPORT NSString * _Nullable GoalongHeadlessSuitePlistPath(NSString * _Nonnull name);

// Gallery guards: from Begin to Take, ordering windows on screen, sheets, modals, status items,
// URL requests, NSTask launches and +standardUserDefaults from the test bundle are refused and
// counted. Take ends the session and returns {violations: [String], network, tasks,
// standardDefaults: Int, standardStack: String}. Not installed when GOALONG_TESTS_VISIBLE=1.
FOUNDATION_EXPORT void GoalongGalleryGuardsBegin(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nonnull GoalongGalleryGuardsTake(void);
FOUNDATION_EXPORT BOOL GoalongGalleryGuardsInstalled(void);
