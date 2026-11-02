// Linked into the test bundles only. Its +load hook keeps test windows invisible and
// blocks activation and LaunchServices opens.
#import <Foundation/Foundation.h>

// Deletes the UserDefaults suite plists this test process created (also runs at exit).
// Suites whose plist existed before the process made them are never touched.
FOUNDATION_EXPORT void GoalongHeadlessCleanLeakedDefaultSuites(void);

// Same, for one suite name, and only when this process created it (other suites stay tracked).
FOUNDATION_EXPORT void GoalongHeadlessCleanLeakedDefaultSuite(NSString * _Nonnull name);

// Path of the plist cfprefsd writes for a suite. A bare test suite name lives in the throwaway HOME
// (`<HOME>/goalong-test-preferences/<name>.plist`, T-043 T1 tour 3); `com.apple.*` and the global
// domains stay in the account's real ~/Library/Preferences (not CFFIXED_USER_HOME).
FOUNDATION_EXPORT NSString * _Nullable GoalongHeadlessSuitePlistPath(NSString * _Nonnull name);

// Deletes ~/Library/Preferences/goalong-tests-defaults-*.plist left by test processes that are gone:
// `goalong-tests-defaults-<pid>-…` whose pid is dead, and the older UUID-only names (untouched for 2 minutes).
// Runs once at load. Unlinks the file only: emptying the domain through cfprefsd re-creates it seconds later.
// Returns the number of files removed.
FOUNDATION_EXPORT NSInteger GoalongHeadlessSweepOrphanedTestPreferences(void);

// Gallery guards: from Begin to Take, ordering windows on screen, sheets, modals, status items,
// URL requests, NSTask launches and +standardUserDefaults from the test bundle are refused and
// counted. Take ends the session and returns {violations: [String], network, tasks,
// standardDefaults: Int, standardStack: String}. Not installed when GOALONG_TESTS_VISIBLE=1.
FOUNDATION_EXPORT void GoalongGalleryGuardsBegin(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nonnull GoalongGalleryGuardsTake(void);
FOUNDATION_EXPORT BOOL GoalongGalleryGuardsInstalled(void);

// Visible-window watchdog (on unless GOALONG_TESTS_VISIBLE=1). A CGWindowList entry counts as
// visible when it belongs to `pid`, has alpha > 0, is at least 2x2 points and meets a display.
FOUNDATION_EXPORT BOOL GoalongHeadlessActive(void);
FOUNDATION_EXPORT BOOL GoalongHeadlessWindowInfoIsVisible(NSDictionary * _Nonnull info, pid_t pid, NSArray<NSValue *> * _Nonnull displays);
FOUNDATION_EXPORT NSArray<NSValue *> * _Nonnull GoalongHeadlessDisplayBounds(void);
// Windows of this process the watchdog found really visible so far (any > 0 fails the run at exit).
FOUNDATION_EXPORT NSInteger GoalongHeadlessVisibleWindowCount(void);
