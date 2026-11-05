import CoreGraphics
import Foundation

/// T-048 C4: wire format between Goalong and its menu bar helper.
///
/// Control Centre (macOS 26) can block every status item of one bundle id, with no way back from
/// the app. A small helper app nested in Goalong (`Contents/Helpers/Goalong Menu Bar.app`, bundle id
/// `<host>.menubar`) then shows the same icon and hands each click back to Goalong.
/// Messages travel as distributed notifications: the name carries the host bundle id, the object is a
/// token made fresh at each launch, the payload holds only property-list values (no history data).
public enum MenuBarRelay {
    public static let helperBundleName = "Goalong Menu Bar.app"
    public static let helperExecutableName = "goalong-menubar-helper"
    public static let knownHosts: Set<String> = ["ai.goalong.localhistory", "ai.goalong.localhistory.dev"]

    public static func helperBundleID(host: String) -> String { host + ".menubar" }

    public static func helperURL(inApp app: URL) -> URL {
        app.appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperBundleName, isDirectory: true)
    }

    /// The app that contains this helper bundle (`<app>/Contents/Helpers/<helper>`), or nil for any other place.
    public static func hostAppURL(ofHelper helper: URL) -> URL? {
        let helpers = helper.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helper.lastPathComponent == helperBundleName, helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return app
    }

    public static func toHelper(host: String) -> Notification.Name { Notification.Name(host + ".menubar-relay.to-helper") }
    public static func toApp(host: String) -> Notification.Name { Notification.Name(host + ".menubar-relay.to-app") }

    /// What the helper shows: the same template image, focus text, tooltip and accessibility text.
    public struct State: Equatable {
        public var image: Data
        public var title: String
        public var toolTip: String
        public var help: String
        public var development: Bool
        public init(image: Data, title: String, toolTip: String, help: String, development: Bool) {
            self.image = image; self.title = title; self.toolTip = toolTip; self.help = help; self.development = development
        }
    }

    public enum Message: Equatable {
        /// helper → app: observing, waiting for the first state.
        case ready
        /// app → helper: draw this.
        case state(State)
        /// helper → app: a click, and the helper button's window frame in screen coordinates.
        case click(menu: Bool, frame: CGRect)
        /// helper → app: where the helper button sits now (the app logs whether it is visible).
        case placed(frame: CGRect)
        /// app → helper: leave now.
        case quit

        public var userInfo: [String: Any] {
            switch self {
            case .ready: return ["kind": "ready"]
            case .quit: return ["kind": "quit"]
            case let .state(s):
                return ["kind": "state", "image": s.image, "title": s.title, "toolTip": s.toolTip, "help": s.help,
                        "development": s.development]
            case let .click(menu, frame): return ["kind": "click", "menu": menu, "frame": Self.encode(frame)]
            case let .placed(frame): return ["kind": "placed", "frame": Self.encode(frame)]
            }
        }

        public init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo, let kind = info["kind"] as? String else { return nil }
            switch kind {
            case "ready": self = .ready
            case "quit": self = .quit
            case "state":
                guard let image = info["image"] as? Data, image.count <= 512 * 1024,
                      let title = info["title"] as? String, let toolTip = info["toolTip"] as? String,
                      let help = info["help"] as? String, let development = info["development"] as? Bool else { return nil }
                self = .state(State(image: image, title: String(title.prefix(40)), toolTip: String(toolTip.prefix(300)),
                                    help: String(help.prefix(300)), development: development))
            case "click":
                guard let menu = info["menu"] as? Bool, let frame = Self.decode(info["frame"]) else { return nil }
                self = .click(menu: menu, frame: frame)
            case "placed":
                guard let frame = Self.decode(info["frame"]) else { return nil }
                self = .placed(frame: frame)
            default: return nil
            }
        }

        static func encode(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        static func decode(_ value: Any?) -> CGRect? {
            guard let v = value as? [Double], v.count == 4, v.allSatisfy(\.isFinite), v[2] >= 0, v[3] >= 0 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
    }

    /// The helper's command line: `--host-pid <pid> --token <uuid> --item <autosave name>`.
    public struct Launch: Equatable {
        public var hostPID: Int32
        public var token: String
        public var itemName: String
        public init(hostPID: Int32, token: String, itemName: String) {
            self.hostPID = hostPID; self.token = token; self.itemName = itemName
        }
        public var arguments: [String] { ["--host-pid", String(hostPID), "--token", token, "--item", itemName] }
        public init?(arguments: [String]) {
            guard arguments.count == 6, arguments[0] == "--host-pid", arguments[2] == "--token", arguments[4] == "--item",
                  let pid = Int32(arguments[1]), pid > 1, UUID(uuidString: arguments[3]) != nil,
                  !arguments[5].isEmpty, arguments[5].count <= 64,
                  arguments[5].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
            self.init(hostPID: pid, token: arguments[3], itemName: arguments[5])
        }
    }
}
