import Foundation

/// A deterministic selector for platforms that are allowed to request a Wi-Fi association.
///
/// The engine deliberately uses a stateful, conservative policy rather than a single RSSI
/// threshold. Its input is a snapshot; it performs no scans, network calls, or Wi-Fi changes.
public struct DecisionEngine: Sendable {
    public let policy: DecisionPolicy

    public init(policy: DecisionPolicy = .default) {
        self.policy = policy
    }

    public func evaluate(
        state: DecisionState,
        current: CurrentNetwork?,
        visibleNetworks: [WiFiObservation],
        approvedSSIDs: Set<String>,
        credentialEligibleSSIDs: Set<String> = [],
        traffic: TrafficState = .unknown,
        now: Date
    ) -> (DecisionState, Decision) {
        var next = state

        // A scan can contain several BSSIDs for one SSID. Coalesce them before updating the
        // EMA so one physical observation is not counted multiple times. The current-link
        // reading is authoritative for the current SSID.
        let representatives = WiFiObservation.strongestPerSSID(visibleNetworks)
        var observationsBySSID = Dictionary(uniqueKeysWithValues: representatives.map { ($0.key, $0) })
        if let current {
            observationsBySSID[current.observation.key] = current.observation
        }
        for network in observationsBySSID.values {
            let previous = next.emaBySSID[network.key] ?? Double(network.rssi)
            next.emaBySSID[network.key] = previous + policy.emaAlpha * (Double(network.rssi) - previous)
        }

        guard let current else {
            next.currentSSID = nil
            next.currentBSSID = nil
            next.weakSince = nil
            next.candidateSince.removeAll()
            return (
                next,
                Decision(
                    at: now,
                    action: .noCurrentConnection(reason: "not connected to a Wi-Fi network"),
                    currentSSID: nil
                )
            )
        }

        let currentSSID = current.observation.ssid
        let currentBSSID = current.observation.bssid
        let associationChanged = next.currentSSID != currentSSID ||
            (currentBSSID != nil && next.currentBSSID != currentBSSID)
        if associationChanged {
            next.currentSSID = currentSSID
            next.currentBSSID = currentBSSID
            next.weakSince = nil
            next.candidateSince.removeAll()
        }
        let currentRSSI = smoothedRSSI(for: currentSSID, fallback: current.observation.rssi, state: next)

        if let lastAttemptAt = next.lastAttemptAt {
            let remaining = policy.switchCooldown - now.timeIntervalSince(lastAttemptAt)
            if remaining > 0 {
                return (
                    next,
                    stay(
                        now: now,
                        currentSSID: currentSSID,
                        reason: "switch cooldown active for another \(format(seconds: remaining))"
                    )
                )
            }
        }

        let currentUnusable = current.health.isKnown && !current.health.isUsable
        if currentRSSI >= Double(policy.goodEnoughRSSI) && !currentUnusable {
            next.weakSince = nil
            next.candidateSince.removeAll()
            return (
                next,
                stay(
                    now: now,
                    currentSSID: currentSSID,
                    reason: "current network is good enough at \(format(rssi: currentRSSI))"
                )
            )
        }

        let currentIsWeak = currentRSSI <= Double(policy.tooWeakRSSI) || currentUnusable
        guard currentIsWeak else {
            next.weakSince = nil
            next.candidateSince.removeAll()
            return (
                next,
                stay(
                    now: now,
                    currentSSID: currentSSID,
                        reason: "current network is in the hysteresis band at \(format(rssi: currentRSSI))"
                )
            )
        }

        if next.weakSince == nil {
            next.weakSince = now
        }
        let weakFor = now.timeIntervalSince(next.weakSince ?? now)
        guard weakFor >= policy.weakDwell else {
            let remaining = policy.weakDwell - weakFor
            return (
                next,
                stay(
                    now: now,
                    currentSSID: currentSSID,
                    reason: "current network has been weak for \(format(seconds: weakFor)); waiting \(format(seconds: remaining))"
                )
            )
        }

        let isConservativeTrafficMode = traffic != .idle
        let effectiveMargin = Double(policy.hysteresisMarginDB) * (isConservativeTrafficMode ? policy.activeTrafficMarginMultiplier : 1)
        let eligible = representatives
            .filter { observation in
                let age = now.timeIntervalSince(observation.observedAt)
                return observation.ssid != currentSSID &&
                approvedSSIDs.contains(observation.ssid) &&
                credentialEligibleSSIDs.contains(observation.ssid) &&
                Double(observation.rssi) >= Double(policy.candidateMinimumRSSI) &&
                age >= 0 && age <= policy.candidateFreshness &&
                !isInFailureCooldown(observation.ssid, now: now, state: next)
            }
            .map { observation in
                (observation, score: smoothedRSSI(for: observation.ssid, fallback: observation.rssi, state: next))
            }
            .filter { $0.score - currentRSSI >= effectiveMargin }
            .sorted { lhs, rhs in lhs.score > rhs.score }

        guard let best = eligible.first else {
            next.candidateSince.removeAll()
            let suffix = isConservativeTrafficMode ? " while traffic status is not confirmed idle" : ""
            return (
                next,
                stay(
                    now: now,
                    currentSSID: currentSSID,
                    reason: "no approved candidate with saved credentials beats current by the required \(format(rssi: effectiveMargin)) dB\(suffix)"
                )
            )
        }

        let targetSSID = best.0.ssid
        let candidateSince = next.candidateSince[targetSSID] ?? now
        next.candidateSince[targetSSID] = candidateSince
        next.candidateSince = next.candidateSince.filter { $0.key == targetSSID }
        let candidateFor = now.timeIntervalSince(candidateSince)
        guard candidateFor >= policy.candidateDwell else {
            let remaining = policy.candidateDwell - candidateFor
            return (
                next,
                stay(
                    now: now,
                    currentSSID: currentSSID,
                    reason: "candidate \(targetSSID) has led by \(format(rssi: best.score - currentRSSI)) dB for \(format(seconds: candidateFor)); waiting \(format(seconds: remaining))"
                )
            )
        }

        let trafficSuffix = isConservativeTrafficMode ? "; conservative traffic margin passed" : ""
        return (
            next,
            Decision(
                at: now,
                action: .switchTo(
                    ssid: targetSSID,
                    reason: "\(targetSSID) leads by \(format(rssi: best.score - currentRSSI)) dB after sustained weakness\(trafficSuffix)"
                ),
                currentSSID: currentSSID
            )
        )
    }

    public func recordSwitchOutcome(
        state: inout DecisionState,
        targetSSID: String,
        success: Bool,
        now: Date
    ) {
        state.candidateSince.removeAll()
        state.lastAttemptAt = now
        if success {
            state.weakSince = nil
            state.lastSwitchAt = now
            state.failedUntil[targetSSID] = nil
        } else {
            // Keep the weak timer on failure so another approved candidate can be considered
            // without pretending that the current network recovered.
            state.failedUntil[targetSSID] = now.addingTimeInterval(policy.failedCandidateCooldown)
        }
    }

    private func smoothedRSSI(for ssid: String, fallback: Int, state: DecisionState) -> Double {
        state.emaBySSID[ssid] ?? Double(fallback)
    }

    private func isInFailureCooldown(_ ssid: String, now: Date, state: DecisionState) -> Bool {
        guard let until = state.failedUntil[ssid] else { return false }
        return until > now
    }

    private func stay(now: Date, currentSSID: String, reason: String) -> Decision {
        Decision(at: now, action: .stay(reason: reason), currentSSID: currentSSID)
    }

    private func format(rssi: Double) -> String {
        String(format: "%.1f", rssi)
    }

    private func format(seconds: TimeInterval) -> String {
        String(format: "%.1fs", max(0, seconds))
    }
}
