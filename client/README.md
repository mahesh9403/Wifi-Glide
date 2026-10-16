# Wi-Fi Glide client

This directory is the client boundary for Wi-Fi Glide. It does not contain a fake cross-platform
implementation yet.

The first client milestone is the macOS proof of concept in `macos/`. It uses explicit opt-in for
association and visible decision output. An iPhone client remains an assisted status/configuration
track rather than an autonomous cross-SSID switcher.

Each future platform client should document:

- APIs used to observe the current and nearby networks;
- permissions, background-execution rules, and user prompts;
- whether the OS permits selecting a different saved network automatically;
- how the client handles credential privacy, failures, and rapid switching; and
- the exact device/OS versions used for validation.
