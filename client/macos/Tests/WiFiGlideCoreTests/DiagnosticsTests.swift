import XCTest
@testable import WiFiGlideCore

final class DiagnosticsTests: XCTestCase {
    func testCredentialStatusesAreClassifiedWithoutSecrets() {
        XCTAssertEqual(WiFiFailureClassifier.credentialAvailability(status: 0), .available)
        XCTAssertEqual(WiFiFailureClassifier.credentialAvailability(status: -25300), .missing)
        XCTAssertEqual(WiFiFailureClassifier.credentialAvailability(status: -25315), .interactionRequired)
        XCTAssertEqual(WiFiFailureClassifier.credentialAvailability(status: -25308), .interactionNotAllowed)
        XCTAssertEqual(WiFiFailureClassifier.credentialAvailability(status: -25293), .authorizationFailed)
        XCTAssertEqual(WiFiFailureClassifier.credentialAvailability(status: 4097), .unknown)
    }

    func testCoreWLANAssociationErrorsAreClassified() {
        XCTAssertEqual(
            WiFiFailureClassifier.associationFailure(domain: "CWErrorDomain", code: -3909),
            .associationDenied
        )
        XCTAssertEqual(
            WiFiFailureClassifier.associationFailure(domain: "CWErrorDomain", code: -3924),
            .invalidPMK
        )
        XCTAssertEqual(
            WiFiFailureClassifier.associationFailure(domain: "CWErrorDomain", code: -3925),
            .supplicantTimeout
        )
        XCTAssertEqual(
            WiFiFailureClassifier.associationFailure(domain: "wifi-glide.CLIError", code: 1),
            .unknown
        )
    }

    func testCredentialDiagnosticNeverContainsPasswordFields() {
        let diagnostic = CredentialDiagnostic(
            ssid: "Amma",
            status: 4097,
            availability: .unknown
        )
        XCTAssertTrue(diagnostic.description.contains("classification=unknown"))
        XCTAssertFalse(diagnostic.description.lowercased().contains("password"))
    }
}
