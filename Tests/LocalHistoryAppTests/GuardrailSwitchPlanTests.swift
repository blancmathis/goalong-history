#if os(macOS)
import XCTest
@testable import LocalHistoryApp

@MainActor final class GuardrailSwitchPlanTests: XCTestCase {
    private let parts = GoalongModule.guardrailParts

    func testTurningOffStartsWithConcentrationThenBlocking() {
        let plan = GuardrailSwitchPlan.plan(parts: parts, turningOn: false, isEnabled: { _ in true }, refuses: { _ in false }, step: { _ in .allow })
        XCTAssertEqual(plan, .go(stops: [], parts: [.concentration, .blocking]))
    }

    func testTurningOnStartsWithBlockingAndAsksNothing() {
        let plan = GuardrailSwitchPlan.plan(parts: parts, turningOn: true, isEnabled: { _ in false }, refuses: { _ in true }, step: { _ in .password })
        XCTAssertEqual(plan, .go(stops: [], parts: [.blocking, .concentration]))
    }

    func testEachDistinctStopIsAskedOnce() {
        let same = GuardrailSwitchPlan.plan(parts: parts, turningOn: false, isEnabled: { _ in true }, refuses: { _ in false }, step: { _ in .password })
        XCTAssertEqual(same, .go(stops: [.password], parts: [.concentration, .blocking]))
        let two = GuardrailSwitchPlan.plan(parts: parts, turningOn: false, isEnabled: { _ in true }, refuses: { _ in false },
                                           step: { $0 == .concentration ? .password : .refused("x") })
        XCTAssertEqual(two, .go(stops: [.password, .refused("x")], parts: [.concentration, .blocking]))
    }

    func testRefusalByOnePartChangesNothingAndAsksNothing() {
        let plan = GuardrailSwitchPlan.plan(parts: parts, turningOn: false, isEnabled: { _ in true }, refuses: { $0 == .blocking }, step: { _ in .password })
        XCTAssertEqual(plan, .refused(by: .blocking))
        XCTAssertEqual(GuardrailSwitchPlan.parts(plan, stopAnswers: []), [])
    }

    func testACancelledStopChangesNothing() {
        let plan = GuardrailSwitchPlan.plan(parts: parts, turningOn: false, isEnabled: { _ in true }, refuses: { _ in false }, step: { _ in .password })
        XCTAssertEqual(GuardrailSwitchPlan.parts(plan, stopAnswers: [false]), [])
        XCTAssertEqual(GuardrailSwitchPlan.parts(plan, stopAnswers: [true]), [.concentration, .blocking])
    }

    func testMixedStateTurnsOnTheMissingPartOnly() {
        XCTAssertEqual(GuardrailSwitchPlan.partsToTurnOn(enabled: [.blocking]), [.concentration])
        XCTAssertEqual(GuardrailSwitchPlan.partsToTurnOn(enabled: [.concentration, .ambiance]), [.blocking])
        XCTAssertEqual(GuardrailSwitchPlan.partsToTurnOn(enabled: [.blocking, .concentration]), [])
        XCTAssertEqual(GuardrailSwitchPlan.partsToTurnOn(enabled: [.ambiance]), [])
    }

    func testMixedStateOnlyLightsUp() {
        let defaults = UserDefaults(suiteName: "guardrail-align-\(UUID().uuidString)")!
        defaults.set(true, forKey: GoalongModule.concentration.defaultsKey)
        let store = GoalongModuleStore(defaults: defaults)
        store.alignGuardrailParts()
        XCTAssertTrue(store.isEnabled(.blocking)); XCTAssertTrue(store.isEnabled(.concentration))
        let off = GoalongModuleStore(defaults: UserDefaults(suiteName: "guardrail-align-\(UUID().uuidString)")!)
        off.alignGuardrailParts()
        XCTAssertFalse(off.isEnabled(.blocking)); XCTAssertFalse(off.isEnabled(.concentration))
    }
}
#endif
