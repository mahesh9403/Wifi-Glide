import Foundation

public struct WiFiObservation: Sendable, Equatable {
    public let ssid: String
    public let bssid: String?
    public let rssi: Int
    public let noise: Int?
    public let observedAt: Date

    public init(
        ssid: String,
        bssid: String? = nil,
        rssi: Int,
        noise: Int? = nil,
        observedAt: Date = Date()
    ) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.observedAt = observedAt
    }

    public var key: String { ssid }

    /// Returns one deterministic representative per SSID. A scan can contain several BSSIDs for
    /// one SSID; candidate ranking should never mix the RSSI from one BSSID with the freshness of
    /// another. Strongest RSSI wins, then newest observation, then lexical BSSID order.
    public static func strongestPerSSID(_ observations: [WiFiObservation]) -> [WiFiObservation] {
        var representatives: [String: WiFiObservation] = [:]
        for observation in observations {
            guard let existing = representatives[observation.ssid] else {
                representatives[observation.ssid] = observation
                continue
            }
            let shouldReplace: Bool
            if observation.rssi != existing.rssi {
                shouldReplace = observation.rssi > existing.rssi
            } else if observation.observedAt != existing.observedAt {
                shouldReplace = observation.observedAt > existing.observedAt
            } else {
                shouldReplace = (observation.bssid ?? "") < (existing.bssid ?? "")
            }
            if shouldReplace {
                representatives[observation.ssid] = observation
            }
        }
        return representatives.values.sorted {
            if $0.rssi == $1.rssi { return $0.ssid < $1.ssid }
            return $0.rssi > $1.rssi
        }
    }
}

public struct NetworkHealth: Sendable, Equatable {
    public let reachable: Bool
    public let isKnown: Bool
    public let latencyMillis: Double?
    public let httpsReachable: Bool?
    public let dnsAndTCPCheckAt: Date?

    public init(
        reachable: Bool,
        latencyMillis: Double? = nil,
        httpsReachable: Bool? = nil,
        dnsAndTCPCheckAt: Date? = nil,
        isKnown: Bool = true
    ) {
        self.reachable = reachable
        self.isKnown = isKnown
        self.latencyMillis = latencyMillis
        self.httpsReachable = httpsReachable
        self.dnsAndTCPCheckAt = dnsAndTCPCheckAt
    }

    public static let unknown = NetworkHealth(reachable: false, isKnown: false)

    public var isUsable: Bool {
        isKnown && reachable && (httpsReachable ?? reachable)
    }
}

public struct CurrentNetwork: Sendable, Equatable {
    public let observation: WiFiObservation
    public let health: NetworkHealth

    public init(observation: WiFiObservation, health: NetworkHealth = .unknown) {
        self.observation = observation
        self.health = health
    }
}

public struct DecisionPolicy: Sendable, Equatable {
    /// EMA weight for a new RSSI sample. Lower values smooth more aggressively.
    public var emaAlpha: Double
    /// Do not consider a switch while the current connection is at or above this value.
    public var goodEnoughRSSI: Int
    /// Begin the weak-signal dwell timer at or below this value.
    public var tooWeakRSSI: Int
    /// Candidate must meet this absolute minimum before it is considered.
    public var candidateMinimumRSSI: Int
    /// Candidate must beat the current smoothed RSSI by at least this many dB.
    public var hysteresisMarginDB: Int
    public var weakDwell: TimeInterval
    public var candidateDwell: TimeInterval
    public var switchCooldown: TimeInterval
    public var failedCandidateCooldown: TimeInterval
    /// Do not trust a scan result indefinitely when the loop is delayed or suspended.
    public var candidateFreshness: TimeInterval
    /// Require a larger improvement while traffic is active.
    public var activeTrafficMarginMultiplier: Double

    public init(
        emaAlpha: Double = 0.3,
        goodEnoughRSSI: Int = -67,
        tooWeakRSSI: Int = -75,
        candidateMinimumRSSI: Int = -65,
        hysteresisMarginDB: Int = 10,
        weakDwell: TimeInterval = 10,
        candidateDwell: TimeInterval = 8,
        switchCooldown: TimeInterval = 30,
        failedCandidateCooldown: TimeInterval = 120,
        candidateFreshness: TimeInterval = 45,
        activeTrafficMarginMultiplier: Double = 2.0
    ) {
        precondition(emaAlpha > 0 && emaAlpha <= 1)
        precondition(goodEnoughRSSI > tooWeakRSSI)
        precondition(hysteresisMarginDB >= 0)
        precondition(weakDwell >= 0 && candidateDwell >= 0)
        precondition(switchCooldown >= 0 && failedCandidateCooldown >= 0 && candidateFreshness >= 0)
        precondition(activeTrafficMarginMultiplier >= 1 && activeTrafficMarginMultiplier.isFinite)
        self.emaAlpha = emaAlpha
        self.goodEnoughRSSI = goodEnoughRSSI
        self.tooWeakRSSI = tooWeakRSSI
        self.candidateMinimumRSSI = candidateMinimumRSSI
        self.hysteresisMarginDB = hysteresisMarginDB
        self.weakDwell = weakDwell
        self.candidateDwell = candidateDwell
        self.switchCooldown = switchCooldown
        self.failedCandidateCooldown = failedCandidateCooldown
        self.candidateFreshness = candidateFreshness
        self.activeTrafficMarginMultiplier = activeTrafficMarginMultiplier
    }

    public static let `default` = DecisionPolicy()
}

public enum TrafficState: Sendable, Equatable {
    /// No traffic detector is available. The engine uses the conservative margin.
    case unknown
    case idle
    case active
}

public struct DecisionState: Sendable, Equatable {
    public var emaBySSID: [String: Double]
    public var weakSince: Date?
    public var candidateSince: [String: Date]
    public var currentSSID: String?
    public var currentBSSID: String?
    public var lastAttemptAt: Date?
    public var lastSwitchAt: Date?
    public var failedUntil: [String: Date]

    public init(
        emaBySSID: [String: Double] = [:],
        weakSince: Date? = nil,
        candidateSince: [String: Date] = [:],
        currentSSID: String? = nil,
        currentBSSID: String? = nil,
        lastAttemptAt: Date? = nil,
        lastSwitchAt: Date? = nil,
        failedUntil: [String: Date] = [:]
    ) {
        self.emaBySSID = emaBySSID
        self.weakSince = weakSince
        self.candidateSince = candidateSince
        self.currentSSID = currentSSID
        self.currentBSSID = currentBSSID
        self.lastAttemptAt = lastAttemptAt
        self.lastSwitchAt = lastSwitchAt
        self.failedUntil = failedUntil
    }
}

public enum DecisionAction: Sendable, Equatable {
    case stay(reason: String)
    case switchTo(ssid: String, reason: String)
    case noCurrentConnection(reason: String)
}

public struct Decision: Sendable, Equatable {
    public let at: Date
    public let action: DecisionAction
    public let currentSSID: String?

    public init(at: Date, action: DecisionAction, currentSSID: String?) {
        self.at = at
        self.action = action
        self.currentSSID = currentSSID
    }
}
