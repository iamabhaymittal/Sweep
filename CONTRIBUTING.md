# Contributing to Sweep

Thanks for helping. Sweep is small on purpose, so a short read here saves time on both sides.

## Ground rules

- **Everything stays on device.** No network access, analytics, accounts or third-party SDKs. If a change needs any of these, open an issue to discuss it first.
- **Deletion is always the user's choice.** Never delete without an explicit action, and always go through `LibraryDeletion`, so Photos shows its confirmation.
- **No new dependencies** without discussing it first. Sweep uses only Apple frameworks.

## Getting set up

1. Fork and clone the repository.
2. Copy `Config/Local.xcconfig.template` to `Config/Local.xcconfig`, and set your Team ID and a bundle ID prefix you own. The file is git-ignored.
3. Open `Sweep.xcodeproj` in Xcode 27 or later and run the **Sweep** scheme.

The Simulator works without step 2. A physical device needs it.

## Making a change

- Branch from `main` and keep each pull request to one change.
- Match the surrounding code style: SwiftUI, Swift concurrency (no Combine), and comments where the code isn't obvious.
- Detection thresholds belong in `DetectionConfig.swift`, not inline.
- Add or update tests in `SweepTests` for logic changes. Tests use [Swift Testing](https://developer.apple.com/documentation/testing).
- Run the tests with **Product → Test** (⌘U) before opening the pull request. CI runs them too.

## Reporting bugs

Open an issue using the bug report template. Include your iOS version, device, and roughly how many photos are in your library, because many issues only show up at scale. Never attach photos from your library.

## Security

See [SECURITY.md](SECURITY.md). Please don't open public issues for vulnerabilities.
