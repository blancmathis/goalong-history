#if os(macOS)
import AppKit
import XCTest
@testable import LocalHistoryApp

/// Goalong's field style, chrome and surface set the text font themselves: a `.font(` on the field, before or after the
/// style, is overridden (the text stays 13 pt while the caller meant 14, 15 or 17). A custom text font goes through
/// `GoalongFieldStyle(textFont:)`, and its declared line height must be the real one.
final class GoalongFieldFontTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Lines (1-based) of a `.font(` in the modifier chain of a field that has a Goalong field style, surface or text area.
    /// The chain is the anchor's line, then the lines before and after it, at the chain's indent, that continue it:
    /// modifiers (`.x`), closure ends (`}`) and comments. Deeper lines are closure bodies: a font there is the content's own.
    static func overriddenFontLines(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        let anchors = ["GoalongFieldStyle(", "GoalongFieldSurface(", "GoalongTextArea("]
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        var found = Set<Int>()
        for (i, line) in lines.enumerated() where anchors.contains(where: { line.contains($0) }) {
            if line.contains(".font(") { found.insert(i + 1) }
            let isModifier = trimmed(line).hasPrefix(".")
            // The chain's indent: the anchor's own when it is a modifier line, else that of the modifier lines under it.
            var chain = indent(line)
            if !isModifier, i + 1 < lines.count, trimmed(lines[i + 1]).hasPrefix("."), indent(lines[i + 1]) > chain {
                chain = indent(lines[i + 1])
            }
            func walk(_ step: Int) {
                var j = i + step
                while j >= 0, j < lines.count {
                    let text = trimmed(lines[j])
                    if text.isEmpty || indent(lines[j]) < chain { return }
                    if indent(lines[j]) == chain {
                        guard text.hasPrefix(".") || text.hasPrefix("}") || text.hasPrefix("//") else { return }
                        if text.hasPrefix(".font(") { found.insert(j + 1) }
                    }
                    j += step
                }
            }
            walk(1)
            // The lines above belong to the same field only when the anchor is itself a modifier line.
            if isModifier { walk(-1) }
        }
        return found.sorted()
    }

    func testScannerFlagsAFontOnAStyledField() {
        // The caller of 77c27a54: a 14 pt monospaced font after the Goalong field style (drawn at 13 pt).
        let old = """
                TextField("Recopiez ici", text: $typed)
                    .textFieldStyle(GoalongFieldStyle())
                    .font(.system(size: 14, design: .monospaced))
                    .accessibilityIdentifier("blocking-typing-field")
        """
        XCTAssertEqual(Self.overriddenFontLines(in: old), [3])
        let sameLine = #"TextField("a", text: $a).textFieldStyle(GoalongFieldStyle()).font(.system(size: 15))"#
        XCTAssertEqual(Self.overriddenFontLines(in: sameLine), [1])
        // Before the style, after a comment and a closure, under the field's line, on a text area: overridden too.
        let before = """
            TextField("a", text: $a)
                .font(.system(size: 15))
                .textFieldStyle(GoalongFieldStyle())
        """
        XCTAssertEqual(Self.overriddenFontLines(in: before), [2])
        let afterClosure = """
            TextField("a", text: $a)
                .textFieldStyle(GoalongFieldStyle())
                // a note
                .onChange(of: a) { _ in
                    Text("x").font(.caption)
                }
                .font(.system(size: 15))
        """
        XCTAssertEqual(Self.overriddenFontLines(in: afterClosure), [7])
        let underFieldLine = """
            TextField("a", text: $a).textFieldStyle(GoalongFieldStyle())
                .font(.system(size: 15))
            GoalongTextArea(text: $b).font(.system(size: 15))
        """
        XCTAssertEqual(Self.overriddenFontLines(in: underFieldLine), [2, 3])
        let fine = """
            TextField("a", text: $a)
                .textFieldStyle(GoalongFieldStyle(textFont: .semibold15))
                .onChange(of: a) { _ in
                    Text("x").font(.caption)
                }
            Text("b").font(.caption)
        """
        XCTAssertEqual(Self.overriddenFontLines(in: fine), [])
    }

    func testNoCallerOverridesTheFieldFont() throws {
        let base = root.appendingPathComponent("Sources/LocalHistoryApp")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            offenders += Self.overriddenFontLines(in: text).map { "\(file.lastPathComponent):\($0)" }
        }
        XCTAssertEqual(offenders, [], "Pass the font to GoalongFieldStyle(textFont:); a .font( on the field is ignored")
    }

    func testEveryCustomFieldFontDeclaresItsRealLineHeight() {
        for preset in GoalongFieldStyle.TextFont.allCases {
            XCTAssertEqual(preset.lineHeight, NSLayoutManager().defaultLineHeight(for: preset.nsFont), "\(preset)")
            XCTAssertEqual(preset.lineHeight, preset.lineHeight.rounded(), "\(preset): the text stays on whole points")
        }
    }
}
#endif
