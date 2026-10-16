# Wi-Fi Glide research status

**Scope:** iPhone/iOS first; MacBook/macOS now included; separate SSIDs with potentially separate
internet connections; no new hardware assumed.

**Status:** feasibility research is substantially complete for the first decision. We have not
started iPhone implementation. A first MacBook command-line proof of concept now exists under
`client/macos`; it is tested locally but has not yet been exercised against a real target Wi-Fi
handoff. The next step is a controlled real-device observation run, followed by an app-bundle/menu-
bar shell if the measurements justify it.

## Current conclusion

### iPhone / iOS

A normal App Store application cannot reliably implement the requested behavior:

> Continuously compare arbitrary nearby Wi-Fi networks with different SSIDs and silently switch
> the iPhone in the background according to an app-defined signal or quality policy.

Public iOS APIs can support an **assisted connector**: configure a specific known network with
user approval, show limited current-network information where the required privacy conditions are
met, and guide the user. They do not give a third-party app a general nearby-network scan,
global Wi-Fi priority list, or unrestricted background control of the Wi-Fi association.

Apple's documented automatic selection is system-owned. Signal strength is considered, but after
network preference history, network category, configuration method, Wi-Fi generation, band, and
security. It is not a user-configurable "always choose the strongest signal" policy.

### MacBook / macOS

macOS is materially more feasible. A Mac app using public **CoreWLAN** APIs can generally:

- scan visible networks;
- inspect scan RSSI/noise/channel/security information;
- inspect the current SSID/BSSID/RSSI/noise/transmit rate;
- monitor Wi-Fi events, subject to the relevant signing/entitlement and privacy setup; and
- request association with a configured visible network.

Therefore, Wi-Fi Glide can be a real Mac-side automatic switcher for the Mac itself. Switching
between different SSIDs is still disruptive because the Mac has one Wi-Fi interface and may need
to reassociate, obtain DHCP, update routes/DNS, and re-establish VPN or captive-portal state. It is
not equivalent to seamless roaming between coordinated access points.

The Mac app cannot control the iPhone's Wi-Fi radio merely because the devices are paired.

The first Wi-Fi Glide POC now implements this boundary as a Swift package. It defaults to a single
read-only snapshot or observe loop, considers only explicitly approved SSIDs, uses RSSI in dBm,
and includes EMA smoothing, weak/candidate dwell, candidate freshness, traffic-conservative
margin, attempt cooldown, failure cooldown, current-network revalidation, and TCP/HTTPS readiness
verification for the opt-in active path. It reads a saved user-keychain credential only after
explicit active-mode confirmation and does not accept passwords through command-line arguments.

The POC's live CoreWLAN path is intentionally not called a seamless roaming solution. It controls
the Mac only, and real association behavior, permissions, credential prompts, VPN disruption, and
rollback need validation on a Mac with the actual household networks.

Active switching remains experimental and is fail-closed when traffic status is unknown unless the
user supplies a separate override. The first unbundled command-line run found a connected Mac Wi-Fi
interface at approximately -44 to -48 dBm but received no SSID/BSSID or scan names. After adding a
bundled app with a location usage description and authorization request, real Mac validation
succeeded: the app reported the current SSID/BSSID and eight nearby observations. A 60-second
observe-only run stayed on the current network while RSSI moved from approximately -54 dBm to
-45 dBm, and it performed no active scans while the connection remained healthy.

The ground-floor use case was then tested by connecting the Mac to first-floor `Ghaghan` while
standing on the ground floor. The snapshot reported `Ghaghan` at approximately `-59 dBm`, with
`Amma5g` at approximately `-43 dBm` and `Amma` at approximately `-38 dBm`. During a 60-second
observe-only run, `Ghaghan` drifted from about `-62` to `-68 dBm`; no association occurred. The
engine correctly stayed because the current default policy treats `-67` through `-75 dBm` as a
hysteresis band and does not actively scan or switch there. This validates the safety behavior but
also identifies the next product choice: earlier candidate evaluation near `-67 dBm` versus the
more conservative `-75 dBm` switching trigger.

The candidate policy has now been tightened: the Mac POC filters the scan to explicitly approved
SSIDs that match a remembered personal-security CoreWLAN profile. It excludes open, enterprise,
OWE, unknown, and WEP profiles in the strict mode, deduplicates multiple BSSIDs to the strongest
representative per SSID, and does not run speed tests against candidates. RSSI/SNR are used before
association; bounded TCP/HTTPS readiness checks are used only after one candidate is selected.
The POC deliberately avoids the System keychain, because checking it can trigger an administrator
prompt. The active path still fails closed if it cannot obtain a user-keychain credential. A
rebuilt ad-hoc app requires its Location Services permission to be granted again if macOS treats
the new signature as a new app.

After the final Location Services authorization, the bundled POC reported three eligible remembered
personal networks: `Amma` at approximately `-49 dBm`, `Amma5g` at approximately `-53 dBm`, and
`Ghaghan` at approximately `-75 dBm`, while the Mac was connected to `Ghaghan` at approximately
`-83 dBm`. The 60-second observe-only run waited through weak dwell, scanned the three eligible
networks, sustained the candidate dwell, and emitted `WOULD-SWITCH` for `Amma` with an advantage of
approximately 32–34 dB. The Mac remained on `Ghaghan`, as required by observe-only mode.

An explicitly confirmed active test then reached the same decision and selected `Amma` with an
advantage of approximately 38 dB. The association attempt failed before the Mac changed networks,
so the radio-ranking logic was validated but the credential/CoreWLAN association path still needs a
better error classification and a supported credential-resolution strategy. The current Wi-Fi
icon itself is not used as an input: it summarizes the current network only, while Wi-Fi Glide
uses CoreWLAN's current-interface and scan-result measurements to compare approved candidates.

The association failure path has now been tightened. Credential eligibility is computed before the
decision engine from a user-keychain presence check; the System keychain is never queried. Raw
Keychain status codes are classified without exposing secrets, and CoreWLAN/NSError association
failures retain their domain, numeric code, and non-secret classification. A candidate with an
unavailable user credential is no longer emitted as `WOULD-SWITCH` and then rejected late.

## Network finding that changes the product decision

If the physical networks can be changed, the best solution remains network-native roaming:

```text
AP/floor 1 ─┐
AP/floor 2 ─┼─ one LAN/VLAN ─ one DHCP service ─ one gateway/NAT
AP/floor 3 ─┘
```

Use one SSID, one security configuration, and wired backhaul where possible. 802.11k, 802.11r,
802.11v, and PMKID caching can improve handoff. Merely giving independent routers the same SSID
does not merge their networks and does not preserve sessions across separate gateways or ISPs.

If the SSIDs and gateways must remain independent, a client-side switch can only provide a
best-effort handoff. Existing TCP/VPN/local-network sessions may break when the IP path or NAT
mapping changes. The iPhone cannot be made to do this by a normal app; a Mac can attempt it for
its own traffic.

## Evidence collected so far

- Apple Support, [known-network auto-join selection](https://support.apple.com/en-us/102169)
- Apple Platform Deployment, [Wi-Fi roaming support](https://support.apple.com/en-in/guide/deployment/dep98f116c0f/web)
- Apple Developer, [TN3111: iOS Wi-Fi API overview](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview.md)
- Apple Developer, [`NEHotspotConfigurationManager`](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager.md)
- Apple Developer, [`NEHotspotNetwork.fetchCurrent`](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchCurrent%28completionhandler%3A%29.md)
- Apple Developer, [CoreWLAN](https://developer.apple.com/documentation/corewlan)
- GitHub, [AP Switcher for macOS](https://github.com/infinityanalytics/ap-switcher)
- GitHub, [MacAPLock](https://github.com/demolen/MacAPLock)
- GitHub, [macOS Intelligent Wi-Fi Switcher](https://github.com/nishant-ingle/macos-intelligent-wifi-switcher)

Some Apple Developer pages require JavaScript in the web view; their linked `.md` pages are the
preferred machine-readable references. Existing open-source projects are evidence of practical
experimentation, not guarantees of App Store compatibility or Apple-supported behavior.

## Recommended product direction

1. **MacBook proof of concept first** if the goal is to prove automatic switching in software.
2. **iPhone companion second**, limited to status, onboarding, diagnostics, and user-approved
   network configuration.
3. **Network-readiness mode** that checks whether existing routers can be converted to AP/bridge
   mode with one shared LAN and SSID; this is the strongest path for actually improving iPhone
   movement between floors or rooms.

The Mac POC should use public CoreWLAN only, keep credentials in Keychain, require explicit
opt-in for automatic switching, use hysteresis/cooldown/dwell-time, and verify DHCP/DNS/HTTPS
after every association. It should not use private BSSID-locking APIs or claim zero interruption.
