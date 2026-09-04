#if os(macOS)
    import Carbon.HIToolbox
    import CoreFoundation
    import Foundation

    /// A deliberately write-only clipboard boundary for explicit user copy actions.
    ///
    /// This type exposes no pasteboard reference and calls no clipboard read API. Keeping the
    /// boundary separate lets the privacy audit reject clipboard reads everywhere in the app.
    enum GoalongClipboardWriter {
        static func copy(_ text: String) -> Bool {
            guard let data = text.data(using: .utf8) else { return false }

            var clipboard: Pasteboard?
            guard PasteboardCreate(kPasteboardClipboard as CFString, &clipboard) == noErr,
                let clipboard,
                PasteboardClear(clipboard) == noErr
            else { return false }

            return PasteboardPutItemFlavor(
                clipboard,
                UnsafeMutableRawPointer(bitPattern: 1)!,
                "public.utf8-plain-text" as CFString,
                data as CFData,
                PasteboardFlavorFlags(rawValue: 0)
            ) == noErr
        }
    }
#endif
