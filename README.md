# Sweep

Sweep is an open-source iPhone app that helps you free up storage by cleaning up your photo library. Everything happens on your iPhone: no accounts, no servers, no analytics, and no network access.

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
- The privacy manifest (`PrivacyInfo.xcprivacy`) declares disk-space and UserDefaults access, both used only to show information in the app.

## Requirements

- iOS 26.0 or later
- Xcode 27 or later, with the iOS 27 SDK
- An iPhone with a photo library. The Simulator works, but its storage numbers reflect your Mac's disk.

## Building

1. Clone the repository and open `Untitled Project.xcodeproj`.
2. Select the **MyApp** target, then **Signing & Capabilities**:
   - Set **Team** to your own Apple Developer team.
   - Change the **Bundle Identifier** to one you own, for example `com.yourname.sweep`.
3. Choose your iPhone as the run destination and run. On a device, enable Developer Mode first (Settings → Privacy & Security → Developer Mode).

## Project structure

```
MyApp/
├── App/                 App entry point and root routing
├── Features/
│   ├── Home/            Dashboard and storage card
│   ├── Onboarding/      Permission flow
│   ├── SwipeDeck/       Keep/delete deck and inline video player
│   └── GroupReview/     Group review screen used by Bursts and Duplicates
├── Services/
│   ├── Analysis/        Background analysis pipeline, SwiftData store, finders
│   └── ...              Library access, sizes, deletion, kept-photos store
└── DetectionConfig.swift  Tunable thresholds for detection and the swipe deck
```

### How detection works

- **Duplicates:** each photo's thumbnail is reduced to a 9×8 grayscale image to produce a 64-bit dHash. Photos within `duplicateHammingDistance` bits are grouped. A pigeonhole bucketing step avoids comparing every pair, so grouping stays fast on large libraries.
- **Low-value shots:** Vision's `CalculateImageAestheticsScoresRequest` gives an overall score from −1 to 1 and a "utility" label. Photos below `lowValueScoreThreshold`, or labelled as utility, are suggested.
- **Analysis:** runs in the foreground with bounded concurrency, halved in Low Power Mode or when the device is hot. It's incremental across launches: only new or edited photos are re-analyzed.

All thresholds live in `DetectionConfig.swift`.

## Known limitations

- **File sizes** come from the `fileSize` key on `PHAssetResource`, which isn't public API. Many photo apps use it, but Apple could change it. Sweep checks the key exists before reading it, and falls back to "size unknown" rather than crashing.
- **Analysis** only runs while the app is open, and resumes next time.
- **Other apps' storage** can't be inspected or cleaned. iOS doesn't allow it.

## Contributing

Issues and pull requests are welcome. Please keep analysis on device and avoid adding network access or third-party dependencies without discussing it in an issue first.

## License

[MIT](LICENSE) © 2026 Abhay Mittal
