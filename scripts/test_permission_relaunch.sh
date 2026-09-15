#!/bin/bash
# Exercises the actual parent handshake and helper across real process exits.
# Only the bundle identifier is substituted to avoid touching the installed app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/goalong-relaunch-e2e.XXXXXX)"
export TEST_ROOT ROOT
python3 - <<'PY'
import os, pathlib, plistlib
root=pathlib.Path(os.environ['ROOT']); target=pathlib.Path(os.environ['TEST_ROOT'])
identifier='ai.goalong.relaunch-fixture.'+target.name.split('.')[-1]
for source,name in [('Sources/LocalHistoryApp/PermissionRecovery.swift','PermissionRecovery.swift'),('Sources/GoalongRelauncher/main.swift','helper.swift')]:
 (target/name).write_text((root/source).read_text().replace('ai.goalong.localhistory',identifier))
app=target/'Goalong Relaunch Fixture.app'; (app/'Contents/MacOS').mkdir(parents=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier,'CFBundleName':'Goalong Relaunch Fixture','CFBundleExecutable':'fixture','CFBundlePackageType':'APPL','LSUIElement':True,'NSPrincipalClass':'NSApplication'}))
(target/'main.swift').write_text(r'''import AppKit
import Foundation
import Darwin

enum GoalongCapability: String { case localComputerHistory, appleScreenTime, aiConversations, chatGPTAnalysis }
let base = Bundle.main.bundleURL.deletingLastPathComponent()
let events = base.appendingPathComponent("events.jsonl")
func log(_ kind: String) {
    let value: [String: Any] = ["event": kind, "pid": getpid(), "time": Date().timeIntervalSince1970]
    let bytes = try! JSONSerialization.data(withJSONObject: value) + Data([10])
    if !FileManager.default.fileExists(atPath: events.path) { FileManager.default.createFile(atPath: events.path, contents: Data()) }
    let handle = try! FileHandle(forWritingTo: events); try! handle.seekToEnd(); try! handle.write(contentsOf: bytes); try! handle.close()
}
final class Fixture: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("started")
        let all = (try? String(contentsOf: events)) ?? ""
        let starts = all.split(separator: "\n").filter { $0.contains("started") }.count
        if CommandLine.arguments.contains("--failure") {
            PermissionRecovery.restart { error in
                log(error == nil ? "unexpected-success" : "failure-kept-parent-alive")
                NSApplication.shared.terminate(nil)
            }
        } else if starts < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                log("restart-request")
                PermissionRecovery.restart { error in
                    if error != nil { log("restart-error"); NSApplication.shared.terminate(nil) }
                    else { log("helper-ready") }
                }
            }
        } else {
            log("normal-quit")
            NSApplication.shared.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        log("draining")
        Thread.sleep(forTimeInterval: 0.65)
        log("drained")
    }
}
let app = NSApplication.shared
let delegate = Fixture(); app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
''')
PY
xcrun swiftc -swift-version 5 "$TEST_ROOT/PermissionRecovery.swift" "$TEST_ROOT/main.swift" -o "$TEST_ROOT/Goalong Relaunch Fixture.app/Contents/MacOS/fixture"
xcrun swiftc -swift-version 5 "$TEST_ROOT/helper.swift" -o "$TEST_ROOT/Goalong Relaunch Fixture.app/Contents/MacOS/goalong-relauncher"
codesign --force --sign - "$TEST_ROOT/Goalong Relaunch Fixture.app/Contents/MacOS/goalong-relauncher" >/dev/null 2>&1
codesign --force --sign - "$TEST_ROOT/Goalong Relaunch Fixture.app" >/dev/null 2>&1
open -g -n "$TEST_ROOT/Goalong Relaunch Fixture.app"
for ((i=0;i<160;i++)); do
  if [[ -f "$TEST_ROOT/events.jsonl" ]] && grep -q 'normal-quit' "$TEST_ROOT/events.jsonl"; then break; fi
  if [[ -f "$TEST_ROOT/events.jsonl" ]] && grep -q 'restart-error' "$TEST_ROOT/events.jsonl"; then cat "$TEST_ROOT/events.jsonl"; exit 1; fi
  sleep 0.5
done
sleep 2
python3 - <<'PY'
import json,os,pathlib
p=pathlib.Path(os.environ['TEST_ROOT'])/'events.jsonl'
events=[json.loads(line) for line in p.read_text().splitlines()]
starts=[e for e in events if e['event']=='started']
assert len(starts)==4,events
assert len({s['pid'] for s in starts})==4
assert sum(e['event']=='helper-ready' for e in events)==3
for previous,current in zip(starts,starts[1:]):
 drained=next(e for e in events if e['pid']==previous['pid'] and e['event']=='drained')
 assert current['time']>drained['time'],events
assert events[-1]['event']=='drained',events
print('PASS: three real quit/reopen cycles; four distinct PIDs; each old process drained before the next start; ordinary Quit stayed quit.')
PY
# Missing component must leave the app alive long enough to report the error.
rm "$TEST_ROOT/Goalong Relaunch Fixture.app/Contents/MacOS/goalong-relauncher"
codesign --force --sign - "$TEST_ROOT/Goalong Relaunch Fixture.app" >/dev/null 2>&1
open -g -n "$TEST_ROOT/Goalong Relaunch Fixture.app" --args --failure
for ((i=0;i<30;i++)); do
  grep -q 'failure-kept-parent-alive' "$TEST_ROOT/events.jsonl" && break
  sleep 0.5
done
grep -q 'failure-kept-parent-alive' "$TEST_ROOT/events.jsonl"
echo 'PASS: missing helper reported a failure without silently quitting the parent.'
echo "Evidence: $TEST_ROOT/events.jsonl"
