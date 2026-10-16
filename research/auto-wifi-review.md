# Review of `coderask/auto-wifi`

Repository reviewed: <https://github.com/coderask/auto-wifi>

Review scope: README, repository tree, algorithm implementation, scanning loop, health probes,
decision loop, switch actor, configuration, and the synthetic algorithm test runner. The repository
was also cloned into a temporary directory and its algorithm test command was run locally.

## What the project already proves

This is the closest existing implementation to Wi-Fi Glide for macOS. It is not merely a concept
or a shell script. The repository contains a Swift 6/macOS 14 project with:

- CoreWLAN scanning and association;
- CoreLocation permission handling for SSID/BSSID visibility;
- Network-framework-based current-network health probes;
- captive-portal detection;
- exponential moving average (EMA) RSSI smoothing;
- a multi-layer hysteresis state machine;
- observe-only mode before enabling switching;
- user preferences such as prefer, avoid, and never-auto-join;
- active-traffic awareness that raises the switch margin;
- cooldown and manual-join protection;
- a menu-bar UI and JSONL decision log; and
- 17 synthetic algorithm checks.

The project is therefore strong evidence that a **MacBook-side** Wi-Fi Glide prototype is
technically practical without additional hardware.

## Its switching policy matches the right idea

The repository uses several protections rather than a single percentage threshold:

1. RSSI is smoothed with EMA (`alpha = 0.3`).
2. A current network above `-67 dBm` is treated as good enough.
3. A current network below `-75 dBm` must remain weak for 10 seconds.
4. A candidate must remain meaningfully better for 8 seconds.
5. A composite score margin is required before switching.
6. A 30-second post-switch cooldown blocks immediate reversal.
7. Active traffic doubles the required margin.

This is a better implementation of the user's proposed idea:

```text
if current is meaningfully weak for long enough
and an approved candidate is meaningfully better for long enough
and the candidate is usable
and we are not in a cooldown/active-traffic guard:
    switch once
```

The important correction is that `60%` should not be the primary input. Use RSSI in dBm and
connection-health measurements instead.

## Important implementation details

### Battery strategy

`ScanCoordinator` uses adaptive polling:

- 60 seconds while steady;
- 10 seconds while degraded;
- 30 seconds during cooldown;
- CoreWLAN event callbacks to refresh when the system already has relevant events; and
- cached scan data where possible.

This is the correct shape for a battery-conscious Mac menu-bar app. It does not continuously run
an active scan at a high frequency while the connection is healthy.

### Quality strategy

The implementation does **not** claim that nearby RSSI reveals the other network's Internet
quality. It measures health for the currently connected network only, then uses RSSI, band,
preferences, and prior captive-portal results for nearby candidates. This is technically honest:
the client cannot measure the backhaul of a network without associating to it, and associating to
every candidate just to test it would itself be disruptive.

### Safe rollout

The default is `Observe`; the engine logs decisions without switching. The user can review the
decision log before opting into `On`. This should be retained in Wi-Fi Glide.

## Findings to carry into Wi-Fi Glide

### Reuse as reference, not copy blindly

The repository is an excellent reference architecture, but Wi-Fi Glide should not copy it without
reviewing the following points:

1. **Post-association readiness:** its switch actor confirms that the SSID changed. Wi-Fi Glide
   should additionally verify DHCP/default route, DNS, and HTTPS reachability before declaring a
   switch successful.
2. **Different gateways:** the algorithm can reduce unnecessary switching, but it cannot preserve
   sessions when the new SSID uses a different IP network, NAT, VPN, or ISP.
3. **Failure cooldown:** a failed target should enter a per-network failure cooldown, not only a
   global post-switch cooldown, to avoid repeatedly selecting a broken candidate.
4. **Credential assumptions:** passing a nil password may work for saved networks but should not
   be treated as a portable credential strategy. Wi-Fi Glide should use explicit user-approved
   configuration and Keychain storage where needed.
5. **Candidate freshness:** the decision engine should record how old each scan result is and avoid
   switching using stale observations.
6. **Active traffic:** traffic detection is helpful but imperfect. It should be a guard that
   suppresses marginal switches, not a claim that every call or transfer is detected.
7. **Event entitlement and privacy:** CoreWLAN event monitoring and Location Services behavior must
   be verified for the intended signed/notarized distribution.
8. **Mac only:** nothing in this design transfers the switching capability to an iPhone.

## Local verification

Temporary checkout used for verification:

```text
/var/folders/qb/f23z3x9540n0rn8mbk2y2zv00000gn/T/omnirush/auto-wifi-review
```

Command run:

```text
make test
```

Result:

```text
17 passed, 0 failed
```

`make build` was also attempted, but the general executable build exceeded the 120-second command
timeout in this environment and was terminated. That is an incomplete check, not a build pass or a
confirmed source failure. No files from the external repository were copied into Wi-Fi Glide.

## Recommendation

Use `auto-wifi` as the primary design reference for the MacBook proof of concept. Wi-Fi Glide can
add a clearer separation between:

```text
observe → decide → request association → verify network readiness → report outcome
```

The strongest first milestone is not to invent a different algorithm. It is to reproduce the
existing project's safe, explainable behavior on a controlled test network, then add the missing
validation for separate gateways and user-facing evidence of disruption.

## Source files inspected

- `Sources/Algorithms/Config.swift`
- `Sources/Algorithms/Hysteresis.swift`
- `Sources/Algorithms/Scoring.swift`
- `Sources/AutoWiFi/ScanCoordinator.swift`
- `Sources/AutoWiFi/DecisionLoop.swift`
- `Sources/AutoWiFi/HealthProbe.swift`
- `Sources/AutoWiFi/SwitchActor.swift`
- `Tests/AlgorithmsRunner/Runner.swift`
