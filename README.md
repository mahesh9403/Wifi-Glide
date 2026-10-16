# Wi-Fi Glide

Wi-Fi Glide is a research-first project exploring whether a device can move between multiple
saved Wi-Fi networks as a person moves between rooms or floors.

## Current status

The first executable milestone is now a **MacBook/macOS proof of concept** under
`client/macos`. The iPhone/iOS work remains a feasibility and companion-app track because normal
App Store apps cannot replace the iOS Wi-Fi selector.

The project must distinguish between:

- **Observation:** scanning or reading the current connection and signal information.
- **Decision:** choosing when a different saved network would be better.
- **Control:** asking the operating system to disconnect and connect to another network.

Those capabilities are not equally available on every operating system, so the client will not
promise seamless cross-platform switching until the platform research and proof of concept support
that claim.

## Repository layout

```text
client/      Platform-client boundary and implementation notes
research/    Feasibility findings, references, and architecture decisions
```

## First acceptance criteria

1. Document the real OS permissions and APIs needed to observe and change Wi-Fi connections.
2. Identify the first platform where an app can demonstrate useful, user-approved switching.
3. Build and test a MacBook proof of concept using public CoreWLAN APIs.
4. Keep observe-only mode as the default; make active switching an explicit, disruptive opt-in.

## MacBook POC checks

From `client/macos`:

```sh
swift build
swift test
swift run wifi-glide --once
```

The POC is not yet a signed menu-bar application and has not been validated against a real
household handoff. See `client/macos/README.md` for observe-only and explicitly opt-in active-mode
instructions.
