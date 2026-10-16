import Foundation
import XCTest
@testable import WiFiGlideCore

final class DecisionEngineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private var policy: DecisionPolicy {
        DecisionPolicy(
            emaAlpha: 1,
            goodEnoughRSSI: -67,
            tooWeakRSSI: -75,
            candidateMinimumRSSI: -65,
            hysteresisMarginDB: 10,
            weakDwell: 10,
            candidateDwell: 8,
            switchCooldown: 30,
            failedCandidateCooldown: 60,
            candidateFreshness: 120,
            activeTrafficMarginMultiplier: 2
        )
    }

    private func network(_ ssid: String, _ rssi: Int) -> WiFiObservation {
        WiFiObservation(ssid: ssid, bssid: "bssid-\(ssid)", rssi: rssi, observedAt: start)
    }

    private func current(_ ssid: String = "Current", _ rssi: Int, reachable: Bool = true) -> CurrentNetwork {
        CurrentNetwork(
            observation: network(ssid, rssi),
            health: NetworkHealth(reachable: reachable, latencyMillis: 20, dnsAndTCPCheckAt: start)
        )
    }

    private func evaluate(
        _ state: DecisionState = DecisionState(),
        current: CurrentNetwork? = nil,
        visible: [WiFiObservation] = [],
        approved: Set<String> = ["Better"],
        credentialed: Set<String>? = nil,
        traffic: TrafficState = .unknown,
        at seconds: TimeInterval
    ) -> (DecisionState, Decision) {
        DecisionEngine(policy: policy).evaluate(
            state: state,
            current: current,
            visibleNetworks: visible,
            approvedSSIDs: approved,
            credentialEligibleSSIDs: credentialed ?? approved,
            traffic: traffic,
            now: start.addingTimeInterval(seconds)
        )
    }

    func testHealthyCurrentNetworkDoesNotConsiderSwitch() {
        let current = current("Current", -55)
        let result = evaluate(current: current, visible: [current.observation, network("Better", -45)], at: 0)

        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected a stay decision")
        }
        XCTAssertTrue(reason.contains("good enough"))
    }

    func testWeakNetworkMustRemainWeakBeforeCandidateEvaluation() {
        let current = current("Current", -80)
        let better = network("Better", -60)
        var state = evaluate(current: current, visible: [current.observation, better], at: 0).0

        let beforeDwell = evaluate(state, current: current, visible: [current.observation, better], at: 9)
        state = beforeDwell.0
        guard case .stay(let reason) = beforeDwell.1.action else {
            return XCTFail("expected to wait for weak dwell")
        }
        XCTAssertTrue(reason.contains("waiting"))
    }

    func testCandidateMustStayBetterBeforeSwitch() {
        let current = current("Current", -80)
        let better = network("Better", -60)
        var state = evaluate(current: current, visible: [current.observation, better], at: 0).0
        state = evaluate(state, current: current, visible: [current.observation, better], at: 10).0

        let beforeCandidateDwell = evaluate(state, current: current, visible: [current.observation, better], at: 17)
        guard case .stay(let reason) = beforeCandidateDwell.1.action else {
            return XCTFail("expected to wait for candidate dwell")
        }
        XCTAssertTrue(reason.contains("candidate Better"))

        let ready = evaluate(beforeCandidateDwell.0, current: current, visible: [current.observation, better], at: 18)
        guard case .switchTo(let ssid, _) = ready.1.action else {
            return XCTFail("expected a switch after both dwell windows")
        }
        XCTAssertEqual(ssid, "Better")
    }

    func testSmallImprovementDoesNotSwitch() {
        let current = current("Current", -80)
        let slightlyBetter = network("Better", -70)
        let initial = evaluate(
            current: current,
            visible: [current.observation, slightlyBetter],
            at: 0
        )
        let result = evaluate(
            initial.0,
            current: current,
            visible: [current.observation, slightlyBetter],
            at: 20
        )

        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected a stay decision")
        }
        XCTAssertTrue(reason.contains("no approved candidate"), reason)
    }

    func testCooldownBlocksImmediateReverseDecision() {
        let current = current("Current", -80)
        let better = network("Better", -60)
        var state = DecisionState()
        let engine = DecisionEngine(policy: policy)
        state = engine.evaluate(
            state: state,
            current: current,
            visibleNetworks: [current.observation, better],
            approvedSSIDs: ["Better"],
            credentialEligibleSSIDs: ["Better"],
            now: start
        ).0
        engine.recordSwitchOutcome(state: &state, targetSSID: "Better", success: true, now: start.addingTimeInterval(18))

        let result = engine.evaluate(
            state: state,
            current: current,
            visibleNetworks: [current.observation, better],
            approvedSSIDs: ["Better"],
            credentialEligibleSSIDs: ["Better"],
            now: start.addingTimeInterval(20)
        )
        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected cooldown to block switching")
        }
        XCTAssertTrue(reason.contains("cooldown"))
    }

    func testFailedCandidateIsTemporarilyExcluded() {
        let engine = DecisionEngine(policy: policy)
        let current = current("Current", -80)
        let better = network("Better", -60)
        var state = DecisionState()
        state = engine.evaluate(
            state: state,
            current: current,
            visibleNetworks: [current.observation, better],
            approvedSSIDs: ["Better"],
            credentialEligibleSSIDs: ["Better"],
            now: start
        ).0
        engine.recordSwitchOutcome(state: &state, targetSSID: "Better", success: false, now: start.addingTimeInterval(18))

        let result = engine.evaluate(
            state: state,
            current: current,
            visibleNetworks: [current.observation, better],
            approvedSSIDs: ["Better"],
            credentialEligibleSSIDs: ["Better"],
            now: start.addingTimeInterval(50)
        )
        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected failed candidate cooldown to block switching")
        }
        XCTAssertTrue(reason.contains("no approved candidate"), reason)
    }

    func testActiveTrafficRequiresLargerMargin() {
        let current = current("Current", -80)
        let better = network("Better", -61)
        var state = evaluate(current: current, visible: [current.observation, better], traffic: .active, at: 0).0
        state = evaluate(state, current: current, visible: [current.observation, better], traffic: .active, at: 10).0

        let result = evaluate(state, current: current, visible: [current.observation, better], traffic: .active, at: 20)
        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected active traffic margin to block this switch")
        }
        XCTAssertTrue(reason.contains("no approved candidate"))
    }

    func testApprovedButUncredentialedCandidateIsRejected() {
        let current = current("Current", -80)
        let better = network("Better", -55)
        let initial = evaluate(
            current: current,
            visible: [current.observation, better],
            approved: ["Better"],
            credentialed: [],
            at: 0
        )
        let result = evaluate(
            initial.0,
            current: current,
            visible: [current.observation, better],
            approved: ["Better"],
            credentialed: [],
            at: 20
        )

        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected an uncredentialed candidate to be rejected")
        }
        XCTAssertTrue(reason.contains("no approved candidate"))
    }

    func testCredentialedButUnapprovedCandidateIsRejected() {
        let current = current("Current", -80)
        let better = network("Better", -55)
        let initial = evaluate(
            current: current,
            visible: [current.observation, better],
            approved: [],
            credentialed: ["Better"],
            at: 0
        )
        let result = evaluate(
            initial.0,
            current: current,
            visible: [current.observation, better],
            approved: [],
            credentialed: ["Better"],
            at: 20
        )

        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected an unapproved candidate to be rejected")
        }
        XCTAssertTrue(reason.contains("no approved candidate"))
    }

    func testStrongestDuplicateSSIDIsTheOnlyCandidateRepresentative() {
        let weaker = WiFiObservation(
            ssid: "Better",
            bssid: "bssid-z",
            rssi: -62,
            observedAt: start.addingTimeInterval(1)
        )
        let stronger = WiFiObservation(
            ssid: "Better",
            bssid: "bssid-a",
            rssi: -55,
            observedAt: start
        )
        let representatives = WiFiObservation.strongestPerSSID([weaker, stronger])
        XCTAssertEqual(representatives.count, 1)
        XCTAssertEqual(representatives.first?.rssi, -55)
        XCTAssertEqual(representatives.first?.bssid, "bssid-a")
    }

    func testStrongerDuplicateThatIsStaleMakesSSIDIneligible() {
        let stalePolicy = DecisionPolicy(
            emaAlpha: 1,
            goodEnoughRSSI: -67,
            tooWeakRSSI: -75,
            candidateMinimumRSSI: -65,
            hysteresisMarginDB: 10,
            weakDwell: 10,
            candidateDwell: 8,
            switchCooldown: 30,
            failedCandidateCooldown: 60,
            candidateFreshness: 5,
            activeTrafficMarginMultiplier: 2
        )
        let engine = DecisionEngine(policy: stalePolicy)
        let current = self.current("Current", -80)
        let staleStrong = WiFiObservation(
            ssid: "Better",
            bssid: "strong",
            rssi: -55,
            observedAt: start.addingTimeInterval(-10)
        )
        let freshWeak = WiFiObservation(
            ssid: "Better",
            bssid: "weak",
            rssi: -60,
            observedAt: start
        )
        let initial = engine.evaluate(
            state: DecisionState(),
            current: current,
            visibleNetworks: [current.observation, staleStrong, freshWeak],
            approvedSSIDs: ["Better"],
            credentialEligibleSSIDs: ["Better"],
            now: start
        )
        let result = engine.evaluate(
            state: initial.0,
            current: current,
            visibleNetworks: [current.observation, staleStrong, freshWeak],
            approvedSSIDs: ["Better"],
            credentialEligibleSSIDs: ["Better"],
            now: start.addingTimeInterval(20)
        )
        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected the stale strongest representative to be rejected")
        }
        XCTAssertTrue(reason.contains("no approved candidate"))
    }

    func testChangingCurrentNetworkResetsWeakDwell() {
        let first = current("First", -80)
        let second = current("Second", -80)
        let better = network("Better", -60)
        let state = evaluate(current: first, visible: [first.observation, better], at: 0).0

        let result = evaluate(
            state,
            current: second,
            visible: [second.observation, better],
            at: 9
        )
        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected a new weak dwell after an external network change")
        }
        XCTAssertTrue(reason.contains("waiting"))
        XCTAssertEqual(result.0.currentSSID, "Second")
    }

    func testChangingBSSIDUnderSameSSIDResetsWeakDwell() {
        let firstObservation = WiFiObservation(
            ssid: "Home",
            bssid: "ap-one",
            rssi: -80,
            observedAt: start
        )
        let secondObservation = WiFiObservation(
            ssid: "Home",
            bssid: "ap-two",
            rssi: -80,
            observedAt: start.addingTimeInterval(9)
        )
        let better = network("Better", -60)
        let first = CurrentNetwork(observation: firstObservation)
        let second = CurrentNetwork(observation: secondObservation)
        var state = evaluate(current: first, visible: [firstObservation, better], at: 0).0

        let result = evaluate(
            state,
            current: second,
            visible: [secondObservation, better],
            at: 9
        )
        state = result.0
        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected a new weak dwell after a BSSID change")
        }
        XCTAssertTrue(reason.contains("waiting"))
        XCTAssertEqual(state.currentBSSID, "ap-two")
    }

    func testStaleCandidateIsNotSelected() {
        let stalePolicy = DecisionPolicy(
            emaAlpha: 1,
            goodEnoughRSSI: -67,
            tooWeakRSSI: -75,
            candidateMinimumRSSI: -65,
            hysteresisMarginDB: 10,
            weakDwell: 10,
            candidateDwell: 8,
            switchCooldown: 30,
            failedCandidateCooldown: 60,
            candidateFreshness: 5,
            activeTrafficMarginMultiplier: 2
        )
        let engine = DecisionEngine(policy: stalePolicy)
        let current = self.current("Current", -80)
        let stale = network("Better", -60)
        let state = engine.evaluate(
            state: DecisionState(),
            current: current,
            visibleNetworks: [current.observation, stale],
            approvedSSIDs: ["Better"],
            credentialEligibleSSIDs: ["Better"],
            now: start
        ).0
        let result = engine.evaluate(
            state: state,
            current: current,
            visibleNetworks: [current.observation, stale],
            approvedSSIDs: ["Better"],
            credentialEligibleSSIDs: ["Better"],
            now: start.addingTimeInterval(20)
        )
        guard case .stay(let reason) = result.1.action else {
            return XCTFail("expected stale candidate to be rejected")
        }
        XCTAssertTrue(reason.contains("no approved candidate"))
    }

    func testCurrentObservationUpdatesEMAOnce() {
        let alphaHalfPolicy = DecisionPolicy(
            emaAlpha: 0.5,
            goodEnoughRSSI: -67,
            tooWeakRSSI: -75,
            candidateMinimumRSSI: -65,
            hysteresisMarginDB: 10,
            weakDwell: 10,
            candidateDwell: 8,
            switchCooldown: 30,
            failedCandidateCooldown: 60,
            candidateFreshness: 120,
            activeTrafficMarginMultiplier: 2
        )
        let engine = DecisionEngine(policy: alphaHalfPolicy)
        let first = self.current("Current", -80)
        let initial = engine.evaluate(
            state: DecisionState(),
            current: first,
            visibleNetworks: [first.observation],
            approvedSSIDs: [],
            now: start
        ).0
        let secondObservation = WiFiObservation(
            ssid: "Current",
            bssid: "bssid-Current",
            rssi: -60,
            observedAt: start.addingTimeInterval(1)
        )
        let next = engine.evaluate(
            state: initial,
            current: CurrentNetwork(observation: secondObservation),
            visibleNetworks: [secondObservation],
            approvedSSIDs: [],
            now: start.addingTimeInterval(1)
        ).0
        XCTAssertEqual(next.emaBySSID["Current"] ?? 0, -70, accuracy: 0.001)
    }
}
