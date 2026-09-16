#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

final class GoalongFinalUXTests: XCTestCase {
    func testModalPresentationCarriesItsDateAndDoesNotReuseIdentity() {
        let day = Date(timeIntervalSince1970: 1788307200)
        let first = GoalongWebsitePresentation(day: day)
        let second = GoalongWebsitePresentation(day: day.addingTimeInterval(-86400))
        XCTAssertEqual(first.day, day)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNil(GoalongWebsitePresentation(day: nil).day)
        XCTAssertEqual(GoalongAnalysisPresentation(tab: 1).tab, 1)
        XCTAssertEqual(GoalongAnalysisPresentation(tab: 2).tab, 2)
    }
    func testSettingsSearchFindsAdvancedToolsAndIgnoresWhitespace() {
        XCTAssertTrue(SettingsPane.matches(" terminal ").contains(.advanced))
        XCTAssertTrue(SettingsPane.matches("JSON").contains(.advanced))
        XCTAssertTrue(SettingsPane.matches("remplacement").contains(.chatGPT))
        XCTAssertTrue(SettingsPane.matches("quotidien").contains(.website))
        XCTAssertEqual(SettingsPane.matches("  \n "), [.applications, .permissions, .storage])
        XCTAssertTrue(SettingsPane.matches("fichier signé").contains(.tools))
    }
    func testIncompleteReplacementCannotBeSavedSilently() {
        var choice = GoalongAnalysisSelection()
        choice.version = 1
        choice.replacements = [GoalongTextReplacement(search: "", replacement: "Projet A")]
        XCTAssertThrowsError(try choice.validate())
        choice.replacements = [GoalongTextReplacement(search: "Nom confidentiel", replacement: "")]
        XCTAssertNoThrow(try choice.validate(), "Empty replacement deliberately removes a phrase")
        choice.replacements = [GoalongTextReplacement()]
        XCTAssertNoThrow(try choice.validate(), "Untouched blank row is harmless")
    }
    func testAnEmptyOptionalGroupDoesNotBlockTheOtherSelectedGroup() {
        var draft = GoalongWebsiteShareDraft()
        draft.deviceIDs = ["device"]
        draft.applicationIDs = ["editor"]
        draft.includeWebsites = true
        XCTAssertNil(draft.validationMessage)
        XCTAssertEqual(draft.options.selectedWebsiteDomains, [], "An empty group never expands to all websites")
        draft.applicationIDs = []
        draft.websiteDomains = ["example.org"]
        XCTAssertNil(draft.validationMessage)
        XCTAssertEqual(draft.options.selectedApplicationIDs, [])
        draft.websiteDomains = []
        XCTAssertNotNil(draft.validationMessage, "A fully empty selection must still be rejected")
    }

    func testFrenchDateDoesNotDependOnSystemLanguage() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 12))!
        XCTAssertEqual(GoalongUIFormat.day(date), "2 juillet 2026")
    }
}
#endif
