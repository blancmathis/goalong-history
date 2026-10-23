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
