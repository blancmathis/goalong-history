#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    final class BuildIdentityReaderTests: XCTestCase {
        func testClassifiesCertificateBackedAppleSignaturesPrecisely() {
            XCTAssertEqual(
                classify(team: "TEAM", receipt: true, summary: "Apple Development: Example"),
                .appStore
            )
            XCTAssertEqual(
                classify(team: "TEAM", summary: "Developer ID Application: Example"),
                .developerID
            )
            XCTAssertEqual(
                classify(team: "TEAM", summary: "Apple Development: Example"),
                .appleDevelopment
            )
            XCTAssertEqual(
                classify(team: "TEAM", summary: "Apple Distribution: Example"),
                .other
            )
        }

        func testClassifiesAdHocOtherAndUnsignedWithoutGuessing() {
            XCTAssertEqual(classify(hash: true, certificates: 0), .adHoc)
            XCTAssertEqual(classify(hash: true, certificates: 1), .other)
            XCTAssertEqual(classify(hash: false, certificates: 0), .unsigned)
        }

        private func classify(
            team: String? = nil,
            receipt: Bool = false,
            summary: String? = nil,
            hash: Bool = true,
            certificates: Int = 1
        ) -> BuildSignatureKind {
            BuildIdentityReader.signatureKind(
                teamIdentifier: team,
                hasAppStoreReceipt: receipt,
                leafCertificateSummary: summary,
                hasCodeDirectoryHash: hash,
                certificateCount: certificates
            )
        }
    }
#endif
