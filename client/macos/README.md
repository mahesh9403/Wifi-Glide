# Wi-Fi Glide for macOS — proof of concept

This is the first executable slice of Wi-Fi Glide. It targets the **MacBook itself**, not an
iPhone. It uses public CoreWLAN APIs and starts in observe-only mode.

## Requirements

- macOS 14 or newer;
- Swift 6 toolchain/Xcode command-line tools;
- a Mac with Wi-Fi; and
- Location Services permission for the terminal or bundled app if macOS redacts SSIDs/BSSIDs.

## Build and test

From this directory:

```sh
swift build
swift test
```

For reliable macOS Location Services behavior, build the local app bundle and use that bundle for
real-device validation:

```sh
chmod +x Scripts/make-app.sh
Scripts/make-app.sh
open "dist/Wi-Fi Glide.app"
```

The app bundle declares `NSLocationWhenInUseUsageDescription` and requests authorization before
reading CoreWLAN identifiers. If macOS shows a Location Services prompt, allow it for **Wi-Fi
Glide**. This local POC bundle is ad-hoc signed; it is not a distributable notarized release.

After permission is granted, invoke the bundled executable for CLI arguments:

```sh
"dist/Wi-Fi Glide.app/Contents/MacOS/WiFiGlide" --once
```

The plain `swift run wifi-glide ...` command remains useful for build and algorithm checks, but
macOS may continue to redact SSID/BSSID values for that unbundled executable.

## Observe a snapshot

```sh
swift run wifi-glide --once \
  --allow-ssid "GroundFloor" \
  --allow-ssid "Bedroom"
```

The command prints the current network and **eligible saved personal networks** among the
explicitly approved SSIDs. It matches macOS remembered personal-security profiles without reading
the System keychain. Open, enterprise, OWE, unknown, and unremembered networks are not included. A
scan is only a snapshot; it is not a promise that every nearby SSID is visible.

## Observe decisions

Only SSIDs explicitly supplied with `--allow-ssid` are eligible switch targets:

```sh
swift run wifi-glide --observe \
  --allow-ssid "GroundFloor" \
  --allow-ssid "Bedroom" \
  --interval 10 \
  --duration 120
```

Observe mode never calls `associate` or `disassociate`. It prints the reason for every decision.
While the current link is healthy, the loop does not actively scan. When the link is weak or
unusable, it refreshes the saved personal-profile candidate scan at a bounded cadence and reuses the
most recent snapshot between scans. Same-SSID results are reduced to the strongest representative.

## Opt into active switching

Active switching is intentionally difficult to invoke:

```sh
swift run wifi-glide --observe \
  --auto-switch \
  --confirm-disruption \
  --allow-unknown-traffic \
  --allow-ssid "GroundFloor" \
  --allow-ssid "Bedroom" \
  --interval 10 \
  --duration 120
```

The `--confirm-disruption` flag is required because joining a different SSID can interrupt traffic,
change the IP route, break VPN/local-network sessions, and cause existing TCP connections to fail.
The POC only attempts approved SSIDs, reads the user-keychain Wi-Fi credential in memory, and
verifies the target SSID plus network-path/TCP/HTTPS readiness after association. It performs one
rollback attempt if the target joins but is not usable, then applies a cooldown. It cannot
guarantee session continuity.

The first run should be observe-only. Do not enable active switching during a meeting, call,
large upload/download, or other work where a temporary network interruption is unacceptable.
The POC does not yet have a complete traffic classifier, so active switching is fail-closed by
default. `--allow-unknown-traffic` is a separate explicit override; it keeps the conservative
larger margin but does not prove that the link is idle.

## macOS permissions

macOS may require Location Services to expose SSIDs and BSSIDs to CoreWLAN. If the output shows
missing identifiers, enable Location Services for the terminal or a signed/bundled Wi-Fi Glide
application in **System Settings → Privacy & Security → Location Services**, then retry.

The CLI does not print Wi-Fi passwords. Candidate filtering uses macOS's remembered
personal-security profile as the no-admin eligibility signal and does not retrieve a password for
ranking. The active path reads an actual user-keychain credential only after explicit active-mode
opt-in. The POC deliberately does not inspect the System keychain, so it does not require
administrator credentials. If no user credential is available, the POC refuses to associate rather
than passing an undocumented nil password. The credential is held in memory for the association
call and is not persisted by Wi-Fi Glide.

Credential filtering reports non-secret diagnostics such as the SSID, user-keychain status code,
and classification (`missing`, `interaction-required`, `interaction-not-allowed`, or `unknown`).
It does not print passwords or the complete Keychain response. Association failures report their
stage and CoreWLAN domain/code classification instead of the generic Swift enum error message.

## Add a Wi-Fi Glide credential without administrator access

If CoreWLAN reports `status=4097 classification=unknown` for the user Wi-Fi keychain, macOS has
remembered the network but is not exposing its existing credential to this process. Do not enter
administrator credentials and do not use the System keychain as a workaround. Add an app-owned
credential instead:

```sh
"dist/Wi-Fi Glide.app/Contents/MacOS/WiFiGlide" --configure-credential "Amma"
```

The SSID must be visible to the Mac. The command asks for the password with terminal echo disabled
and stores it as an app-owned generic-password item in the current user's Keychain. The password is
not placed in shell history, arguments, output, or project files. Repeat for `Amma5g` and any other
approved personal network you want Wi-Fi Glide to use.

After configuring the credentials, verify eligibility without switching:

```sh
"dist/Wi-Fi Glide.app/Contents/MacOS/WiFiGlide" --once \
  --allow-ssid "Ghaghan" \
  --allow-ssid "Amma5g" \
  --allow-ssid "Amma"
```

The output should list configured networks as eligible saved personal networks. This app-owned
credential flow is still a local POC; enterprise/EAP networks are not supported.

## Why Wi-Fi Glide does not run speed tests for every candidate

RSSI/SNR can rank a candidate without joining it. Internet speed, gateway latency, DNS, and HTTPS
quality cannot be measured for a different SSID without first associating with it. Testing every
candidate would interrupt the current connection, change routes/DHCP state, consume data, and
drain battery. Wi-Fi Glide therefore uses radio measurements for pre-association ranking and
bounded TCP/HTTPS readiness checks only after one target is selected. Full upload/download tests
are reserved for manual diagnostics.

## Current boundaries

- This POC controls the Mac's Wi-Fi interface only.
- It does not control an iPhone or other devices.
- It does not use private CoreWiFi APIs or force a permanent BSSID lock.
- RSSI is measured in dBm, not a percentage. RSSI alone is not Internet quality.
- Different SSIDs are best-effort switching, not seamless roaming.
