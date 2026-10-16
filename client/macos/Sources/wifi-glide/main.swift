import CoreWLAN
@preconcurrency import CoreLocation
import Darwin
import Foundation
import Network
import Security
import WiFiGlideCore

@main
struct WiFiGlideCLI {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                print(Options.help)
                return
            }

            if options.activeSwitching && !options.confirmDisruption {
                fputs("Refusing active switching: add --confirm-disruption after reading the warning.\n", stderr)
                exit(2)
            }

            let location = LocationAuthorization()
            await location.requestIfNeeded()
            let client = try CoreWLANClient()
            let engine = DecisionEngine()
            var state = DecisionState()

            if case .configureCredential(let ssid) = options.mode {
                let wasVisible = try client.configureAppCredential(for: ssid)
                if wasVisible {
                    print("Saved Wi-Fi Glide credential for visible SSID \(ssid) in the user Keychain.")
                } else {
                    print("Saved Wi-Fi Glide credential for \(ssid) in the user Keychain; SSID was not visible during setup.")
                }
                return
            }

            if case .once = options.mode {
                let snapshot = try client.snapshot(activeScan: true, approvedSSIDs: options.approvedSSIDs)
                printSnapshot(
                    snapshot,
                    approvedSSIDs: options.approvedSSIDs,
                    interfaceAvailable: client.interfaceAvailable(),
                    interfaceRSSI: client.interfaceRSSI()
                )
                for diagnostic in snapshot.credentialDiagnostics {
                    print("  \(diagnostic)")
                }
                return
            }

            print("Wi-Fi Glide observe loop started (active switching: \(options.activeSwitching ? "ON" : "OFF"))")
            print("Approved SSIDs: \(options.approvedSSIDs.sorted().joined(separator: ", "))")
            print("Press Control-C to stop.\n")

            let startedAt = Date()
            var lastActiveScanAt: Date?
            var cachedVisibleNetworks: [WiFiObservation] = []
            var cachedCredentialEligibleSSIDs = Set<String>()
            var cachedCredentialDiagnostics: [CredentialDiagnostic] = []
            while Date().timeIntervalSince(startedAt) < options.duration {
                let currentOnly = try client.currentNetwork()
                let interfaceAvailable = client.interfaceAvailable()
                let currentHealth: NetworkHealth
                if currentOnly != nil {
                    currentHealth = await NetworkProbe.run()
                } else {
                    currentHealth = .unknown
                }

                let current = currentOnly.map { CurrentNetwork(observation: $0, health: currentHealth) }
                let now = Date()
                let weakDwellComplete = state.weakSince.map {
                    now.timeIntervalSince($0) >= DecisionPolicy.default.weakDwell
                } ?? false
                let needsCandidateScan = current == nil ||
                    !currentHealth.isUsable ||
                    ((current?.observation.rssi ?? -100) <= DecisionPolicy.default.tooWeakRSSI && weakDwellComplete)
                let scanCooldown = 30.0
                let shouldScan = needsCandidateScan &&
                    (lastActiveScanAt == nil || now.timeIntervalSince(lastActiveScanAt!) >= scanCooldown)
                if shouldScan {
                    let scan = try client.candidateScan(approvedSSIDs: options.approvedSSIDs)
                    cachedVisibleNetworks = scan.observations
                    cachedCredentialEligibleSSIDs = scan.credentialEligibleSSIDs
                    cachedCredentialDiagnostics = scan.credentialDiagnostics
                    lastActiveScanAt = now
                }
                let visible = cachedVisibleNetworks
                let result = engine.evaluate(
                    state: state,
                    current: current,
                    visibleNetworks: visible,
                    approvedSSIDs: options.approvedSSIDs,
                    credentialEligibleSSIDs: cachedCredentialEligibleSSIDs,
                    traffic: .unknown,
                    now: now
                )
                if shouldScan {
                    for diagnostic in cachedCredentialDiagnostics {
                        print("  \(diagnostic)")
                    }
                }
                state = result.0

                printDecision(
                    result.1,
                    current: current,
                    visible: visible,
                    activeScan: shouldScan,
                    interfaceAvailable: interfaceAvailable
                )

                if case .switchTo(let targetSSID, let reason) = result.1.action, options.activeSwitching {
                    if !options.allowUnknownTraffic {
                        print("BLOCKED: traffic state is unknown; add --allow-unknown-traffic only if you accept the risk of interrupting active work")
                    } else {
                        print("ACTION: requesting association with \(targetSSID) — \(reason)")
                        let outcome = await client.associate(
                            to: targetSSID,
                            expectedCurrentSSID: result.1.currentSSID,
                            approvedSSIDs: options.approvedSSIDs
                        )
                        if outcome.attempted {
                            engine.recordSwitchOutcome(
                                state: &state,
                                targetSSID: targetSSID,
                                success: outcome.success,
                                now: Date()
                            )
                        }
                        print(outcome.message)
                    }
                }

                try await Task.sleep(for: .seconds(options.interval))
            }
        } catch let error as OptionsError {
            fputs("Error: \(error.description)\n\n\(Options.help)\n", stderr)
            exit(2)
        } catch let error as CLIError {
            fputs("Wi-Fi Glide stopped: \(error.description)\n", stderr)
            exit(1)
        } catch {
            fputs("Wi-Fi Glide stopped: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

@MainActor
private final class LocationAuthorization: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestIfNeeded() async {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            return
        case .denied, .restricted:
            return
        case .notDetermined:
            break
        @unknown default:
            return
        }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        continuation?.resume()
        continuation = nil
    }
}

private struct Options {
    enum Mode { case once, observe, configureCredential(String) }

    let mode: Mode
    let interval: TimeInterval
    let duration: TimeInterval
    let approvedSSIDs: Set<String>
    let activeSwitching: Bool
    let confirmDisruption: Bool
    let allowUnknownTraffic: Bool
    let showHelp: Bool

    init(arguments: [String]) throws {
        var mode: Mode = .once
        var interval = 15.0
        var duration = 60.0
        var ssids = Set<String>()
        var activeSwitching = false
        var confirmDisruption = false
        var allowUnknownTraffic = false
        var showHelp = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                showHelp = true
            case "--once":
                mode = .once
            case "--observe":
                mode = .observe
            case "--configure-credential":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw OptionsError.invalid("--configure-credential requires a non-empty SSID")
                }
                mode = .configureCredential(arguments[index])
            case "--auto-switch":
                activeSwitching = true
            case "--confirm-disruption":
                confirmDisruption = true
            case "--allow-unknown-traffic":
                allowUnknownTraffic = true
            case "--interval":
                index += 1
                interval = try Self.value(arguments, at: index, named: argument)
                guard interval >= 2 else { throw OptionsError.invalid("--interval must be at least 2 seconds") }
            case "--duration":
                index += 1
                duration = try Self.value(arguments, at: index, named: argument)
                guard duration > 0 else { throw OptionsError.invalid("--duration must be positive") }
            case "--allow-ssid":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw OptionsError.invalid("--allow-ssid requires a non-empty SSID")
                }
                ssids.insert(arguments[index])
            default:
                throw OptionsError.invalid("unknown argument \(argument)")
            }
            index += 1
        }

        self.mode = mode
        self.interval = interval
        self.duration = duration
        self.approvedSSIDs = ssids
        self.activeSwitching = activeSwitching
        self.confirmDisruption = confirmDisruption
        self.allowUnknownTraffic = allowUnknownTraffic
        self.showHelp = showHelp
    }

    private static func value(_ arguments: [String], at index: Int, named name: String) throws -> TimeInterval {
        guard index < arguments.count, let value = Double(arguments[index]) else {
            throw OptionsError.invalid("\(name) requires a number")
        }
        return value
    }

    static let help = """
    Wi-Fi Glide — MacBook proof of concept

    Safe default: print one CoreWLAN snapshot without changing Wi-Fi.

    Usage:
      wifi-glide --once
      wifi-glide --observe --allow-ssid "GroundFloor" --allow-ssid "Bedroom"
      wifi-glide --observe --auto-switch --confirm-disruption --allow-unknown-traffic --allow-ssid "GroundFloor"

    Options:
      --once                    Scan once and print current/eligible saved networks (default)
      --observe                 Run the decision loop until --duration expires
      --configure-credential SSID
                                Securely save an approved network password in Wi-Fi Glide's user Keychain
      --allow-ssid NAME         Approve a target SSID; repeat for each allowed network
      --interval SECONDS        Loop interval, minimum 2 seconds (default: 15)
      --duration SECONDS        Observe duration (default: 60)
      --auto-switch             Permit association requests; still requires confirmation
      --confirm-disruption      Explicitly acknowledge different-SSID interruption risk
      --allow-unknown-traffic   Override the fail-closed traffic guard for active switching
      --help                    Show this help

    Notes:
      - Observe mode never associates or disassociates.
      - Active mode only considers explicitly approved SSIDs and saved macOS credentials.
      - Active mode is blocked unless traffic is explicitly allowed as unknown; the POC has no
        complete traffic classifier yet.
      - The POC controls the Mac only; it cannot control an iPhone.
    """
}

private enum OptionsError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

private struct Snapshot {
    let current: WiFiObservation?
    let visible: [WiFiObservation]
    let credentialDiagnostics: [CredentialDiagnostic]
}

private struct CandidateScan {
    let observations: [WiFiObservation]
    let credentialEligibleSSIDs: Set<String>
    let credentialDiagnostics: [CredentialDiagnostic]
}

private struct AssociationOutcome {
    let attempted: Bool
    let success: Bool
    let message: String
}

private final class CoreWLANClient {
    private let client = CWWiFiClient.shared()
    private let queue = DispatchQueue(label: "wifi-glide.corewlan", qos: .userInitiated)

    init() throws {
        let hasInterface = interfaceAvailable()
        guard hasInterface else {
            throw CLIError.noWiFiInterface
        }
    }

    func interfaceAvailable() -> Bool {
        queue.sync { client.interface() != nil }
    }

    func interfaceRSSI() -> Int? {
        queue.sync {
            guard let interface = client.interface() else { return nil }
            let rssi = interface.rssiValue()
            return rssi == 0 ? nil : rssi
        }
    }

    func snapshot(activeScan: Bool, approvedSSIDs: Set<String>) throws -> Snapshot {
        let current = try currentNetwork()
        let scan = activeScan
            ? try candidateScan(approvedSSIDs: approvedSSIDs)
            : CandidateScan(observations: [], credentialEligibleSSIDs: [], credentialDiagnostics: [])
        return Snapshot(
            current: current,
            visible: scan.observations,
            credentialDiagnostics: scan.credentialDiagnostics
        )
    }

    func configureAppCredential(for ssid: String) throws -> Bool {
        let scannedSSIDData = try rawSSIDData(for: ssid)
        guard let ssidData = scannedSSIDData ?? ssid.data(using: .utf8) else {
            throw CLIError.invalidSSID(ssid)
        }
        guard let password = readHiddenPassword(prompt: "Wi-Fi password for \(ssid): ") else {
            throw CLIError.credentialInputCancelled
        }
        try AppCredentialStore.save(password: password, ssidData: ssidData)
        return scannedSSIDData != nil
    }

    private func rawSSIDData(for ssid: String) throws -> Data? {
        try queue.sync {
            guard let interface = client.interface() else {
                throw CLIError.noWiFiInterface
            }
            let scanned = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
            return scanned.first(where: { $0.ssid == ssid })?.ssidData
        }
    }

    func currentNetwork() throws -> WiFiObservation? {
        queue.sync {
            guard let interface = client.interface(), let ssid = interface.ssid(), !ssid.isEmpty else {
                return nil
            }
            let noise = interface.noiseMeasurement()
            return WiFiObservation(
                ssid: ssid,
                bssid: interface.bssid(),
                rssi: interface.rssiValue(),
                noise: noise == 0 ? nil : noise
            )
        }
    }

    func candidateScan(approvedSSIDs: Set<String>) throws -> CandidateScan {
        guard !approvedSSIDs.isEmpty else {
            return CandidateScan(observations: [], credentialEligibleSSIDs: [], credentialDiagnostics: [])
        }
        return try queue.sync {
            guard let interface = client.interface() else {
                throw CLIError.noWiFiInterface
            }
            let scanned = try interface.scanForNetworks(withSSID: nil)
            var strongestBySSIDData: [Data: CWNetwork] = [:]
            var eligibleSSIDs = Set<String>()
            var diagnostics: [CredentialDiagnostic] = []
            var diagnosticSSIDs = Set<String>()
            for network in scanned {
                guard let ssid = network.ssid,
                      let ssidData = network.ssidData,
                      approvedSSIDs.contains(ssid),
                      isSavedPersonalProfile(network: network, interface: interface) else {
                    continue
                }

                let credential: (status: Int32, availability: CredentialAvailability)
                if AppCredentialStore.hasCredential(ssidData: ssidData) {
                    credential = (0, .available)
                } else {
                    credential = userCredentialStatus(for: ssidData)
                }
                if credential.availability != .available {
                    if diagnosticSSIDs.insert(ssid).inserted {
                        diagnostics.append(
                            CredentialDiagnostic(
                                ssid: ssid,
                                status: credential.status,
                                availability: credential.availability
                            )
                        )
                    }
                    continue
                }
                eligibleSSIDs.insert(ssid)
                if let existing = strongestBySSIDData[ssidData], existing.rssiValue >= network.rssiValue {
                    continue
                }
                strongestBySSIDData[ssidData] = network
            }

            let eligibleNetworks: [WiFiObservation] = strongestBySSIDData.values
                .compactMap { network in
                    guard let ssid = network.ssid, !ssid.isEmpty else { return nil }
                    let noise = network.noiseMeasurement
                    return WiFiObservation(
                        ssid: ssid,
                        bssid: network.bssid,
                        rssi: network.rssiValue,
                        noise: noise == 0 ? nil : noise
                    )
                }
            return CandidateScan(
                observations: eligibleNetworks.sorted {
                    if $0.rssi == $1.rssi { return $0.ssid < $1.ssid }
                    return $0.rssi > $1.rssi
                },
                credentialEligibleSSIDs: eligibleSSIDs,
                credentialDiagnostics: diagnostics.sorted { $0.ssid < $1.ssid }
            )
        }
    }

    func associate(
        to ssid: String,
        expectedCurrentSSID: String?,
        approvedSSIDs: Set<String>
    ) async -> AssociationOutcome {
        var associationStarted = false
        do {
            guard approvedSSIDs.contains(ssid) else {
                return AssociationOutcome(
                    attempted: false,
                    success: false,
                    message: "SKIPPED: target SSID is not explicitly approved"
                )
            }
            guard let expectedCurrentSSID else {
                return AssociationOutcome(
                    attempted: false,
                    success: false,
                    message: "SKIPPED: no current-network identity was available for revalidation"
                )
            }

            let preflightCurrent = try currentNetwork()
            guard let preflightCurrent, preflightCurrent.ssid == expectedCurrentSSID else {
                return AssociationOutcome(
                    attempted: false,
                    success: false,
                    message: "SKIPPED: current network changed before association"
                )
            }
            let preflightHealth = await NetworkProbe.run()
            if preflightCurrent.rssi > DecisionPolicy.default.goodEnoughRSSI && preflightHealth.isUsable {
                return AssociationOutcome(
                    attempted: false,
                    success: false,
                    message: "SKIPPED: current network recovered before association"
                )
            }

            try queue.sync {
                guard let interface = client.interface() else {
                    throw CLIError.noWiFiInterface
                }
                let targetNetworks = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
                guard let target = targetNetworks
                    .filter({
                        $0.ssid == ssid && isSavedPersonalProfile(network: $0, interface: interface)
                    })
                    .sorted(by: { lhs, rhs in lhs.rssiValue > rhs.rssiValue })
                    .first else {
                    throw CLIError.targetNotVisible(ssid)
                }
                let password = try savedPassword(for: ssid)

                // Revalidate the same policy inputs inside the serialized CoreWLAN section
                // immediately before association. The health probe is necessarily a snapshot
                // taken just before this section, so this check is deliberately conservative.
                let currentRSSI = interface.rssiValue()
                guard currentRSSI <= DecisionPolicy.default.tooWeakRSSI || !preflightHealth.isUsable else {
                    throw CLIError.currentRecovered
                }
                let requiredMargin = DecisionPolicy.default.hysteresisMarginDB * 2
                guard target.rssiValue >= DecisionPolicy.default.candidateMinimumRSSI,
                      target.rssiValue - currentRSSI >= requiredMargin else {
                    throw CLIError.targetNoLongerQualifies(ssid)
                }

                // Read the saved user-keychain password only after explicit active-mode opt-in.
                // It is held in memory for this call and never logged or persisted by Wi-Fi Glide.
                associationStarted = true
                try interface.associate(to: target, password: password)
            }

            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if try currentNetwork()?.ssid == ssid {
                    let health = await NetworkProbe.waitUntilUsable()
                    if health.isUsable {
                        return AssociationOutcome(
                            attempted: true,
                            success: true,
                            message: "SUCCESS: joined \(ssid); network-path/TCP/HTTPS readiness passed (\(format(health.latencyMillis)) ms)"
                        )
                    }

                    let rollbackMessage: String
                    if expectedCurrentSSID != ssid {
                        rollbackMessage = await rollback(to: expectedCurrentSSID)
                            ? "; rolled back to \(expectedCurrentSSID)"
                            : "; rollback to \(expectedCurrentSSID) failed"
                    } else {
                        rollbackMessage = ""
                    }
                    return AssociationOutcome(
                        attempted: true,
                        success: false,
                        message: "FAILED: joined \(ssid), but network readiness did not pass\(rollbackMessage)"
                    )
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            let rollbackMessage = associationStarted && expectedCurrentSSID != ssid
                ? (await rollback(to: expectedCurrentSSID)
                    ? "; rolled back to \(expectedCurrentSSID)"
                    : "; rollback to \(expectedCurrentSSID) failed")
                : ""
            return AssociationOutcome(
                attempted: associationStarted,
                success: false,
                message: "FAILED: timed out waiting for \(ssid)\(rollbackMessage)"
            )
        } catch {
            let rollbackMessage: String
            if associationStarted, let expectedCurrentSSID, expectedCurrentSSID != ssid {
                rollbackMessage = await rollback(to: expectedCurrentSSID)
                    ? "; rollback to \(expectedCurrentSSID) succeeded"
                    : "; rollback to \(expectedCurrentSSID) failed"
            } else {
                rollbackMessage = ""
            }
            return AssociationOutcome(
                attempted: associationStarted,
                success: false,
                message: "FAILED: \(nonSecretErrorDescription(error, ssid: ssid, stage: associationStarted ? "association_request" : "preflight"))\(rollbackMessage)"
            )
        }
    }

    private func rollback(to ssid: String) async -> Bool {
        do {
            try queue.sync {
                try performAssociation(to: ssid)
            }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if try currentNetwork()?.ssid == ssid {
                    return (await NetworkProbe.waitUntilUsable()).isUsable
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        } catch {
            return false
        }
        return false
    }

    private func performAssociation(to ssid: String) throws {
        guard let interface = client.interface() else {
            throw CLIError.noWiFiInterface
        }
        let targetNetworks = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
        guard let target = targetNetworks
            .filter({ $0.ssid == ssid && isSavedPersonalProfile(network: $0, interface: interface) })
            .sorted(by: { lhs, rhs in lhs.rssiValue > rhs.rssiValue })
            .first else {
            throw CLIError.targetNotVisible(ssid)
        }
        let password = try savedPassword(for: ssid)
        try interface.associate(to: target, password: password)
    }

    private func isSavedPersonalProfile(network: CWNetwork, interface: CWInterface) -> Bool {
        guard let ssidData = network.ssidData,
              let configuration = interface.configuration() else {
            return false
        }
        let profiles = configuration.networkProfiles.compactMap { $0 as? CWNetworkProfile }

        let matchingProfile = profiles.first { profile in
            guard profile.ssidData == ssidData, isPersonalPasswordSecurity(profile.security) else {
                return false
            }
            return network.supportsSecurity(profile.security)
        }
        return matchingProfile != nil
    }

    private func isPersonalPasswordSecurity(_ security: CWSecurity) -> Bool {
        // CoreWLAN's public enum values: WPA Personal (2), WPA/WPA2 mixed (3), WPA2 Personal
        // (4), generic Personal (5), WPA3 Personal (11), and WPA3 transition (13). Open,
        // enterprise, OWE, unknown, and obsolete WEP profiles are excluded from this POC.
        [2, 3, 4, 5, 11, 13].contains(security.rawValue)
    }

    private func userCredentialStatus(for ssidData: Data) -> (status: Int32, availability: CredentialAvailability) {
        guard let userDomain = CWKeychainDomain(rawValue: 1) else {
            return (-1, .unknown)
        }
        let status = CWKeychainFindWiFiPassword(userDomain, ssidData, nil)
        return (status, WiFiFailureClassifier.credentialAvailability(status: status))
    }

    private func savedPassword(for ssid: String) throws -> String {
        guard let ssidData = ssid.data(using: .utf8) else {
            throw CLIError.noSavedCredential(
                CredentialDiagnostic(ssid: ssid, status: -1, availability: .unknown)
            )
        }
        if let appPassword = AppCredentialStore.password(ssidData: ssidData) {
            return appPassword
        }
        guard let userDomain = CWKeychainDomain(rawValue: 1) else {
            throw CLIError.noSavedCredential(
                CredentialDiagnostic(ssid: ssid, status: -1, availability: .unknown)
            )
        }
        var password: NSString?
        let status = CWKeychainFindWiFiPassword(userDomain, ssidData, &password)
        let availability = WiFiFailureClassifier.credentialAvailability(status: status)
        if availability == .available, let password, password.length > 0 {
            return password as String
        }
        throw CLIError.noSavedCredential(
            CredentialDiagnostic(ssid: ssid, status: status, availability: availability)
        )
    }

    private func nonSecretErrorDescription(_ error: Error, ssid: String, stage: String) -> String {
        if let cliError = error as? CLIError {
            return cliError.description
        }
        let nsError = error as NSError
        let classification = WiFiFailureClassifier.associationFailure(
            domain: nsError.domain,
            code: Int32(nsError.code)
        )
        return "stage=\(stage) target=\(ssid) domain=\(nsError.domain) code=\(nsError.code) classification=\(classification.rawValue)"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.0f", value)
    }
}

private enum AppCredentialStore {
    private static let service = AppCredentialIdentity.service

    static func hasCredential(ssidData: Data) -> Bool {
        password(ssidData: ssidData) != nil
    }

    static func password(ssidData: Data) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: AppCredentialIdentity.account(for: ssidData) as CFString,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: kCFBooleanTrue as Any
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            return nil
        }
        return password
    }

    static func save(password: String, ssidData: Data) throws {
        let account = AppCredentialIdentity.account(for: ssidData)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: account as CFString,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(password.utf8),
            kSecAttrIsInvisible: kCFBooleanTrue as Any
        ]
        let addAttributes = query.merging(attributes) { _, new in new }
        var result: CFTypeRef?
        let addStatus = SecItemAdd(addAttributes as CFDictionary, &result)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw CLIError.keychainFailure(addStatus)
        }
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw CLIError.keychainFailure(updateStatus)
        }
    }
}

private func readHiddenPassword(prompt: String) -> String? {
    guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: 1024)
    defer {
        buffer.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                memset(baseAddress, 0, bytes.count)
            }
        }
    }
    guard let password = buffer.withUnsafeMutableBufferPointer({ pointer in
        readpassphrase(prompt, pointer.baseAddress, pointer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY)
    }) else {
        return nil
    }
    return String(cString: password)
}

private enum CLIError: Error, CustomStringConvertible {
    case noWiFiInterface
    case targetNotVisible(String)
    case noSavedCredential(CredentialDiagnostic)
    case credentialInputCancelled
    case invalidSSID(String)
    case keychainFailure(Int32)
    case currentRecovered
    case targetNoLongerQualifies(String)

    var description: String {
        switch self {
        case .noWiFiInterface: "no Wi-Fi interface is available"
        case .targetNotVisible(let ssid): "target SSID is not visible: \(ssid)"
        case .noSavedCredential(let diagnostic): diagnostic.description
        case .credentialInputCancelled: "credential setup cancelled or requires an interactive terminal"
        case .invalidSSID(let ssid): "SSID cannot be encoded for credential setup: \(ssid)"
        case .keychainFailure(let status): "stage=credential_store code=\(status) classification=keychain_write_failed"
        case .currentRecovered: "current network recovered before association"
        case .targetNoLongerQualifies(let ssid): "target SSID no longer meets the safety margin: \(ssid)"
        }
    }
}

private enum NetworkProbe {
    static func waitUntilUsable(
        attempts: Int = 3,
        retryDelay: Duration = .seconds(1)
    ) async -> NetworkHealth {
        var latest = NetworkHealth.unknown
        for attempt in 0..<max(1, attempts) {
            latest = await run()
            if latest.isUsable || attempt == max(1, attempts) - 1 {
                return latest
            }
            try? await Task.sleep(for: retryDelay)
        }
        return latest
    }

    static func run(host: String = "apple.com", port: UInt16 = 443) async -> NetworkHealth {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let started = Date()
        let result = await withTaskGroup(of: NetworkHealth.self) { group in
            group.addTask {
                await waitForReady(connection: connection, started: started)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                connection.cancel()
                return NetworkHealth(reachable: false, dnsAndTCPCheckAt: Date())
            }
            let first = await group.next() ?? NetworkHealth(reachable: false, dnsAndTCPCheckAt: Date())
            group.cancelAll()
            connection.cancel()
            return first
        }
        guard result.reachable else { return result }
        let httpsOK = await httpsProbe()
        return NetworkHealth(
            reachable: true,
            latencyMillis: result.latencyMillis,
            httpsReachable: httpsOK,
            dnsAndTCPCheckAt: Date()
        )
    }

    private static func waitForReady(connection: NWConnection, started: Date) async -> NetworkHealth {
        await withCheckedContinuation { continuation in
            let resolver = OnceResolver<NetworkHealth>()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resolver.resolve(
                        NetworkHealth(
                            reachable: true,
                            latencyMillis: Date().timeIntervalSince(started) * 1_000,
                            dnsAndTCPCheckAt: Date()
                        ),
                        continuation: continuation
                    )
                case .failed, .cancelled:
                    resolver.resolve(
                        NetworkHealth(reachable: false, dnsAndTCPCheckAt: Date()),
                        continuation: continuation
                    )
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "wifi-glide.network-probe"))
        }
    }

    private static func httpsProbe() async -> Bool {
        guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<400).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

private final class OnceResolver<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func resolve(_ value: Value, continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        let shouldResolve = !resolved
        resolved = true
        lock.unlock()
        if shouldResolve {
            continuation.resume(returning: value)
        }
    }
}

private func printSnapshot(
    _ snapshot: Snapshot,
    approvedSSIDs: Set<String>,
    interfaceAvailable: Bool,
    interfaceRSSI: Int?
) {
    if let current = snapshot.current {
        print("Current: \(current.ssid) | RSSI \(current.rssi) dBm | BSSID \(current.bssid ?? "redacted")")
    } else if interfaceAvailable {
        let rssi = interfaceRSSI.map { "RSSI \($0) dBm" } ?? "RSSI unavailable"
        print("Current: Wi-Fi interface present, but SSID/BSSID are unavailable (\(rssi); check Location Services permission)")
    } else {
        print("Current: no Wi-Fi interface is available")
    }
    print("Eligible saved personal networks: \(snapshot.visible.count)")
    for network in snapshot.visible {
        let approved = approvedSSIDs.contains(network.ssid) ? " [approved]" : ""
        print("  \(network.ssid) | RSSI \(network.rssi) dBm | BSSID \(network.bssid ?? "redacted")\(approved)")
    }
}

private func printDecision(
    _ decision: Decision,
    current: CurrentNetwork?,
    visible: [WiFiObservation],
    activeScan: Bool,
    interfaceAvailable: Bool
) {
    let timestamp = ISO8601DateFormatter().string(from: decision.at)
    switch decision.action {
    case .stay(let reason):
        print("[\(timestamp)] STAY | \(reason) | scan=\(activeScan) visible=\(visible.count)")
    case .switchTo(let ssid, let reason):
        print("[\(timestamp)] WOULD-SWITCH | current=\(current?.observation.ssid ?? "none") target=\(ssid) | \(reason)")
    case .noCurrentConnection(let reason):
        let detail = interfaceAvailable
            ? "Wi-Fi interface present but SSID/BSSID unavailable; check Location Services"
            : "no Wi-Fi interface detected"
        print("[\(timestamp)] NO-CONNECTION | \(reason) | \(detail) | scan=\(activeScan) visible=\(visible.count)")
    }
}
