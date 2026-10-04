import XCTest
import OndeCore
import OndeDSP

/// Gravity, Orbit and Sonar are pure synthesis: they must play with no sample bank.
final class AmbianceBassLedScoresTests: XCTestCase {
    func testBassLedScoresRenderWithoutSamples() throws {
        for (id, score) in [("gravite", 13), ("orbit", 14), ("sonar", 15)] {
            let profile = try XCTUnwrap(FocusCompositions.profiles.first { $0.id == id })
            let config = try profile.configuration.validated()
            let dsp = try XCTUnwrap(onde_dsp_create(44_100, profile.mode.dspMode, config.seed))
            defer { onde_dsp_destroy(dsp) }
            for (index, value) in config.values.enumerated() { onde_dsp_set(dsp, GenerativeSettings.dspIndex(index), Float(value)) }
            onde_dsp_set(dsp, Int32(ONDE_GAIN), 1)
            var left = [Float](repeating: 0, count: 2048), right = left
            var peak: Float = 0, energy: Double = 0, frames = 0
            while frames < 44_100 * 20 {
                onde_dsp_render(dsp, &left, &right, 2048); frames += 2048
                for i in 0..<2048 {
                    XCTAssertTrue(left[i].isFinite && right[i].isFinite, id)
                    peak = max(peak, abs(left[i]), abs(right[i])); energy += Double(left[i] * left[i] + right[i] * right[i])
                }
            }
            XCTAssertEqual(onde_dsp_composition(dsp), Int32(score), id)
            XCTAssertEqual(onde_dsp_orchestra_samples(dsp), 0, id)
            XCTAssertGreaterThan(sqrt(energy / Double(frames * 2)), 0.01, "\(id) must be audible")
            XCTAssertLessThanOrEqual(peak, 1, id)
        }
    }
}
