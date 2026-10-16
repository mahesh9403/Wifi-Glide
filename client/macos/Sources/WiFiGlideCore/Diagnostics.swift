import Foundation

public enum CredentialAvailability: String, Sendable, Equatable {
    case available
    case missing
    case interactionRequired
    case interactionNotAllowed
    case authorizationFailed
    case unknown
}

public struct CredentialDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public let ssid: String
    public let domain: String
    public let status: Int32
    public let availability: CredentialAvailability

    public init(
        ssid: String,
        domain: String = "user",
        status: Int32,
        availability: CredentialAvailability
    ) {
        self.ssid = ssid
        self.domain = domain
        self.status = status
        self.availability = availability
    }

    public var description: String {
        "credential_lookup stage=credential_lookup ssid=\(ssid) domain=\(domain) status=\(status) classification=\(availability.rawValue)"
    }
}

public enum AssociationFailureClassification: String, Sendable, Equatable {
    case invalidParameter
    case timeout
    case associationDenied
    case invalidPMK
    case supplicantTimeout
    case ipcFailure
    case operationNotPermitted
    case unspecifiedFailure
    case unknown
}

public enum WiFiFailureClassifier {
    public static func credentialAvailability(status: Int32) -> CredentialAvailability {
        switch status {
        case 0:
            return .available
        case -25300: // errSecItemNotFound
            return .missing
        case -25315: // errSecInteractionRequired
            return .interactionRequired
        case -25308: // errSecInteractionNotAllowed
            return .interactionNotAllowed
        case -25293: // errSecAuthFailed
            return .authorizationFailed
        default:
            return .unknown
        }
    }

    public static func associationFailure(domain: String, code: Int32) -> AssociationFailureClassification {
        guard domain == "CWErrorDomain" || domain.localizedCaseInsensitiveContains("CoreWLAN") else {
            return .unknown
        }
        switch code {
        case -3900:
            return .invalidParameter
        case -3905:
            return .timeout
        case -3906:
            return .unspecifiedFailure
        case -3909:
            return .associationDenied
        case -3924:
            return .invalidPMK
        case -3925:
            return .supplicantTimeout
        case -3929:
            return .ipcFailure
        case -3930:
            return .operationNotPermitted
        default:
            return .unknown
        }
    }
}
