#!/bin/bash
# Self test: the headless test hook removes the suite plists it recorded when the test process
# is killed by a signal or crashes (SIGTERM, SIGABRT, SIGSEGV, SIGTRAP). Builds a tiny host with
# clang (no swift build). Plists are UUID-named and deleted at the end even if the test fails.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$(mktemp -d /tmp/goalong-signal-selftest-XXXXXX)"
real_home="$(python3 -c 'import pwd,os;print(pwd.getpwuid(os.getuid()).pw_dir)')"
prefs="$real_home/Library/Preferences"
trap 'rm -rf "$dir"; rm -f "$prefs"/goalong-signal-selftest-*.plist' EXIT
cat > "$dir/host.m" <<'M'
#import <Foundation/Foundation.h>
#import "GoalongHeadlessTestSupport.h"
#import <signal.h>
#import <stdlib.h>
#import <string.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *suite = [@"goalong-signal-selftest-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults setObject:@"v" forKey:@"k"];
        [defaults synchronize];
        // T-043 T1 tour 3: the hook keeps a bare suite name in the throwaway HOME; this is where its plist goes.
        NSString *path = GoalongHeadlessSuitePlistPath(suite);
        NSString *real = [NSString stringWithFormat:@"%@/Library/Preferences/%@.plist", [NSString stringWithUTF8String:argv[2]], suite];
        if ([path isEqualToString:real]) { fprintf(stderr, "suite not isolated: %s\n", real.UTF8String); return 4; }
        for (int i = 0; i < 300 && ![NSFileManager.defaultManager fileExistsAtPath:path]; i++) [NSThread sleepForTimeInterval:0.05];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) { fprintf(stderr, "plist never written\n"); return 3; }
        printf("%s\n", path.UTF8String); fflush(stdout);
        if (!strcmp(argv[1], "abort")) abort();
        if (!strcmp(argv[1], "trap")) __builtin_trap();
        if (!strcmp(argv[1], "segv")) { volatile int *p = 0; *p = 1; }
        if (!strcmp(argv[1], "term")) { raise(SIGTERM); }
    }
    return 0;
}
M
if ! clang -fobjc-arc -framework Foundation -framework AppKit -I "$ROOT/Tests/GoalongHeadlessTestSupport/include" \
    "$dir/host.m" "$ROOT/Tests/GoalongHeadlessTestSupport/GoalongHeadlessTestSupport.m" -o "$dir/host" 2>"$dir/cc.log"; then
  cat "$dir/cc.log" >&2; echo "FAIL: could not build the host" >&2; exit 1
fi
fail=0
for how in abort trap segv term; do
  path="$(XCTestConfigurationFilePath=/nonexistent GOALONG_TEST_HOME="$dir/home-$how" "$dir/host" "$how" "$real_home" 2>"$dir/$how.err")"
  if [[ -z "$path" ]]; then echo "FAIL: $how: host did not report a plist ($(cat "$dir/$how.err"))" >&2; fail=1; continue; fi
  if [[ "$path" != "$dir/home-$how/"* ]]; then echo "FAIL: $how: plist outside the throwaway HOME: $path" >&2; fail=1; continue; fi
  if [[ -e "$path" ]]; then echo "FAIL: $how left $path" >&2; rm -f "$path"; fail=1; else echo "ok: $how leaves no suite plist"; fi
  real="$prefs/$(basename "$path")"
  if [[ -e "$real" ]]; then echo "FAIL: $how wrote $real" >&2; fail=1; fi
done
exit "$fail"
