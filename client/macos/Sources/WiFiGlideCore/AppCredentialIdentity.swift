import Foundation

public enum AppCredentialIdentity {
    public static let service = "ai.omnirush.wifi-glide.credentials.v1"

    public static func account(for ssidData: Data) -> String {
        "ssid." + ssidData.base64EncodedString()
    }
}
