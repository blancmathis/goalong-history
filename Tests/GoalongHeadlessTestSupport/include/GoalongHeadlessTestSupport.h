// Linked into the test bundles only. Its +load hook keeps test windows invisible and
// blocks activation and LaunchServices opens; no public API.
#import <Foundation/Foundation.h>

// Deletes the UserDefaults suite plists this test process created (also runs at exit).
// Suites whose plist existed before the process made them are never touched.
FOUNDATION_EXPORT void GoalongHeadlessCleanLeakedDefaultSuites(void);
