#if os(macOS)
    import AppKit

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
#else
    import Foundation
    fputs("LocalHistory is a macOS-only application.\n", stderr)
#endif
