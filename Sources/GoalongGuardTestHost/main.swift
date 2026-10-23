#if os(macOS)
import Darwin
import Foundation
import XPC

// Test host for scripts/test_guard_launchd.sh only; never embedded in Goalong. It proves the launchd
// behaviour the real guard relies on, without Goalong, without a window:
//   --label L --dir D : writes "<pid>\n" to D/started-<n>, listens on Mach service L, then
//   - exits 0 when D/exit-zero exists (launchd must not respawn),
//   - exits 75 when its own binary changes (launchd must start the new one),
//   - otherwise waits (a kill -9 must be respawned by KeepAlive SuccessfulExit=false).
let arguments = CommandLine.arguments
guard arguments.count == 5, arguments[1] == "--label", arguments[3] == "--dir" else { exit(64) }
let label = arguments[2]
let directory = URL(fileURLWithPath: arguments[4], isDirectory: true)
var size: UInt32 = 0
_NSGetExecutablePath(nil, &size)
var buffer = [CChar](repeating: 0, count: Int(size))
guard _NSGetExecutablePath(&buffer, &size) == 0 else { exit(65) }
let executable = String(cString: buffer)
func stamp() -> ino_t? { var info = stat(); return stat(executable, &info) == 0 ? info.st_ino : nil }
let initial = stamp()

let count = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("started-") }.count
try? Data("\(getpid())\n".utf8).write(to: directory.appendingPathComponent("started-\(count + 1)"))

let listener = xpc_connection_create_mach_service(label, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
xpc_connection_set_event_handler(listener) { peer in
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
    xpc_connection_set_event_handler(peer) { message in
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(message) else { return }
        xpc_dictionary_set_int64(reply, "pid", Int64(getpid()))
        xpc_connection_send_message(peer, reply)
    }
    xpc_connection_resume(peer)
}
xpc_connection_resume(listener)

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
timer.setEventHandler {
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("exit-zero").path) { exit(0) }
    if stamp() != initial { exit(75) }
}
timer.activate()
dispatchMain()
#else
import Foundation
exit(0)
#endif
