# Candidate eligibility and network quality

## Candidate eligibility is a hard gate

Wi-Fi Glide must not rank every visible SSID. A visible network is eligible for automatic
consideration only when all of these conditions hold:

```text
visible now
AND explicitly approved by the user
AND remembered by macOS as a compatible personal-security profile
AND macOS has a remembered compatible personal-security profile
AND not excluded or in failure cooldown
```

The Mac POC uses CoreWLAN's preferred network profiles to match a visible SSID and security type.
This is the no-admin proxy for a saved personal network. It does not inspect the System keychain,
because doing so can trigger an administrator-authentication prompt on a personal Mac. The active
path still performs a just-in-time user-keychain lookup before association and refuses to proceed
if it cannot obtain a usable credential.

The initial POC intentionally excludes:

- open networks;
- OWE and OWE-transition networks;
- enterprise/EAP networks, which do not use one shared Wi-Fi password;
- unknown security types; and
- obsolete WEP profiles.

An SSID allowlist remains necessary even when a password is saved. Saved networks can include
coffee shops, offices, hotels, or old home networks that the user does not want Wi-Fi Glide to
select automatically. The effective set is an intersection:

```text
explicitly approved SSIDs ∩ macOS remembered personal profiles
```

Exclusions must always win over approvals.

## Ranking before association

For candidates that pass the hard eligibility gate, rank using measurements available without
joining them:

1. strongest current RSSI, represented once per SSID;
2. SNR (`RSSI - noise`) when both measurements are available;
3. recent smoothed RSSI history;
4. band/PHY information as a small supporting preference;
5. prior association/readiness success and user preference; and
6. stability and switching-cost penalties.

If several BSSIDs advertise the same SSID, the POC uses one deterministic representative:

```text
strongest RSSI
→ newest observation on an RSSI tie
→ deterministic BSSID ordering on a complete tie
```

The ranking does not probe every candidate's Internet connection. Doing that would require
associating with each network, interrupt the current connection, trigger DHCP/DNS changes, consume
data, and create exactly the disruption the decision engine is designed to avoid.

## RSSI versus Internet speed

RSSI is a radio measurement, not Internet speed. A strong signal can have a congested access
point, packet loss, a broken gateway, or a slow ISP. A lower RSSI can still be usable. Therefore,
RSSI/SNR should be used to shortlist and rank candidates, not to claim that one ISP is faster.

## What the Wi-Fi icon tells us

The Wi-Fi icon is a useful user-interface clue, but not a reusable network-selection API.

The bars normally summarize the **current association** using system-owned radio/link information
such as received signal and link conditions. Apple does not publish the exact formula used by the
icon, and the icon does not expose a ranked list of every saved or nearby network. It also does not
tell us whether another SSID has lower latency, better Internet service, or a working gateway.

Wi-Fi Glide should therefore not try to read or imitate the icon itself. It should use the public
measurements behind the same general concept:

```text
current link:   CWInterface.rssiValue(), noise, transmit rate
candidate link: CWNetwork.rssiValue, noise, channel/security metadata from a scan
```

Those values are both radio measurements in dBm and are appropriate for a relative comparison,
with the normal caveats that scans are snapshots, antennas/bands can differ, and RSSI is not
Internet quality. The POC already uses this model: it smooths current/candidate RSSI, keeps one
strongest BSSID representative per SSID, then applies saved-profile eligibility, dwell, hysteresis,
and cooldown rules.

The useful product interpretation is:

```text
Wi-Fi icon:     “How healthy is the network I am using right now?”
Wi-Fi Glide:    “Among approved remembered networks I can see, which radio looks materially better?”
```

The second question still requires a scan. The icon cannot answer it by itself.

The quality signals have different roles:

| Signal | Can be measured before joining a candidate? | Wi-Fi Glide use |
| --- | ---: | --- |
| RSSI | Yes | Primary pre-association shortlist signal |
| Noise/SNR | Usually | Supporting radio-quality signal |
| Current transmit rate | Only current network | Supporting degradation signal |
| Gateway latency/loss | No | Strong post-association health signal |
| DNS/TCP/TLS/HTTPS | No | Readiness and Internet usability checks |
| Small download/upload | No | Optional diagnostic tie-breaker |
| Full throughput test | No | Manual diagnostics only |

## Why not run a speed test for every network?

A full upload/download test generally takes several seconds or longer, transfers data, competes
with the user's traffic, and measures the selected test server as much as the Wi-Fi network. It
also cannot be run against an unjoined candidate without switching the Mac onto that candidate.
Running it for every visible network would create repeated disruptions and high battery/data use.

Wi-Fi Glide should therefore use this escalation policy:

```text
Healthy current link:
  read current radio state; avoid active scans and IP probes

Candidate selection:
  use saved-password eligibility + fresh scan RSSI/SNR + hysteresis

After one candidate is selected/associated:
  verify path readiness, DNS/TCP/TLS/HTTPS, and captive-portal state

Ambiguous diagnostic case:
  optionally run one small bounded download on explicit user request

Full upload/download throughput:
  never automatic; manual diagnostics only
```

The current POC already uses bounded TCP and HTTPS readiness checks after the selected network is
joined. It does not implement a bandwidth test. That is the correct default for automatic mode.

## Recommended switching rule

For the Mac POC's conservative profile:

```text
current is meaningfully weak or unusable for a dwell period
AND
eligible candidate is fresh and materially stronger
AND
candidate advantage survives candidate dwell
AND
traffic guard permits interruption
→ request one association
→ verify network path and HTTPS readiness
```

For the observed ground-floor case, the current test showed:

```text
Ghaghan  ≈ -59 to -68 dBm
Amma5g   ≈ -43 dBm
Amma     ≈ -38 dBm
```

The existing default policy stayed in the `-67` to `-75 dBm` hysteresis band and did not scan or
switch. A future balanced profile can begin candidate evaluation near `-67 dBm`, but it should
still require a 10 dB advantage, a dwell window, saved-password eligibility, and post-association
readiness. That profile should be validated in observe-only mode before active switching.

## Acceptance criteria

- No visible open, enterprise, OWE, unknown, or unremembered SSID produces a switch decision in
  strict saved-profile mode.
- Two BSSIDs for one SSID produce one candidate representative.
- A strong but stale representative is rejected rather than replaced by a weaker duplicate with
  inconsistent freshness.
- Candidate ranking performs no DNS, TCP, HTTPS, upload, or download probe before association.
- A selected target receives one bounded readiness check after association.
- Full throughput tests are never run automatically.
- A healthy current connection does not trigger repeated scans or speed tests merely because a
  stronger visible SSID exists.
