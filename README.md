<p align="center">
  <img src="Sweep/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" height="128" alt="Sweep app icon">
</p>

<h1 align="center">Sweep</h1>

<p align="center">
  Free up iPhone storage by cleaning your photo library, entirely on device.
</p>

<p align="center">
  <a href="https://github.com/iamabhaymittal/Sweep/actions/workflows/ci.yml"><img src="https://github.com/iamabhaymittal/Sweep/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/iOS-26%2B-blue" alt="iOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
</p>

Sweep finds the photos and videos taking up the most space and helps you decide what to keep. There are no accounts, servers, analytics or network access: your library never leaves your iPhone.

## Features

| Feature | What it does |
| --- | --- |
| **Storage overview** | Free and used space on the device, how much your photos and videos take, and how much you've cleaned with Sweep. |
| **Swipe Photos / Swipe Videos** | Review your library one item at a time, largest first. Swipe right to keep, left to mark for deletion. Videos play inline, and there's a full-screen player with scrubbing. Photos you keep stay hidden in later sessions. |
| **Bursts** | Finds burst sequences, including the extra frames Photos normally hides, and suggests keeping your pick or Photos' best shot. |
| **Low-Value Shots** | Uses Vision's aesthetics scores to surface receipts, documents, whiteboards and poor shots, worst first. Favorites are never suggested. |
| **Duplicates** | Groups identical and near-identical photos using a 64-bit difference hash, and suggests the best copy to keep. |

Deleted items go to **Recently Deleted** in Photos, where they stay for 30 days. Storage is fully reclaimed once that album is emptied.

## Privacy

- Sweep asks for Photos access only to analyze and delete items you choose. Photos also asks you to confirm every deletion.
- Analysis runs on device. Results, such as image hashes and scores, are stored locally with SwiftData and never leave the device.
- Photos stored only in iCloud aren't downloaded for analysis.
- The privacy manifest (`Sweep/PrivacyInfo.xcprivacy`) declares disk-space and UserDefaults access, both used only to show information in the app.

## Requirements

- iOS 26.0 or later
- Xcode 27 or later, with the iOS 27 SDK

## Getting started

```sh
git clone https://github.com/iamabhaymittal/Sweep.git
cd Sweep
cp Config/Local.xcconfig.template Config/Local.xcconfig   # then edit it
open Sweep.xcodeproj
```

In `Config/Local.xcconfig`, set:

- `DEVELOPMENT_TEAM`: your Apple Developer Team ID
- `BUNDLE_ID_PREFIX`: a reverse-DNS prefix you own, for example `com.yourname`. The app becomes `com.yourname.sweep`.

The file is git-ignored, so your signing settings never end up in a commit. The Simulator works without it. A physical device needs it, and Developer Mode turned on (Settings → Privacy & Security → Developer Mode).

## Tests

Unit tests use [Swift Testing](https://developer.apple.com/documentation/testing) and live in `SweepTests/`. They cover difference hashing, duplicate clustering (checked against a brute-force reference), and the group review selection rules.

Run them in Xcode with **Product → Test** (⌘U). CI runs them on every push and pull request.

## Project structure

```
Sweep/
├── App/                     App entry point and root routing
├── Features/
│   ├── Home/                Dashboard and storage card
│   ├── Onboarding/          Permission flow
│   ├── SwipeDeck/           Keep/delete deck and inline video player
│   └── GroupReview/         Group review screen used by Bursts and Duplicates
├── Services/
│   ├── Analysis/            Background analysis pipeline, SwiftData store, finders
│   └── …                    Library access, sizes, deletion, kept-photos store
└── DetectionConfig.swift    Tunable thresholds for detection and the swipe deck
SweepTests/                  Unit tests
Config/                      Shared build settings and the local signing template
```

### How detection works

- **Duplicates:** each photo's thumbnail is reduced to a 9×8 grayscale image to produce a 64-bit dHash. Photos within `duplicateHammingDistance` bits are grouped. Pigeonhole bucketing means only hashes that share a 16-bit chunk are compared, which keeps grouping fast on large libraries.
- **Low-value shots:** Vision's `CalculateImageAestheticsScoresRequest` gives an overall score from −1 to 1 and a "utility" label. Photos below `lowValueScoreThreshold`, or labelled as utility, are suggested.
- **Analysis:** runs in the foreground with bounded concurrency, halved in Low Power Mode or when the device is hot. It's incremental across launches: only new or edited photos are re-analyzed.

All thresholds live in `Sweep/DetectionConfig.swift`.

## Known limitations

- **File sizes** come from the `fileSize` key on `PHAssetResource`, which isn't public API. Many photo apps use it, but Apple could change it. Sweep checks the key exists before reading it, and falls back to "size unknown" rather than crashing.
- **Analysis** only runs while the app is open, and resumes next time.
- **Other apps' storage** can't be inspected or cleaned. iOS doesn't allow it.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and project principles, and [SECURITY.md](SECURITY.md) for reporting vulnerabilities privately. This project follows a [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 Abhay Mittal
