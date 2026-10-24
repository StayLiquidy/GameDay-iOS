# GameDay iOS native prototype

## Install and update with FlareStore

Add this URL in FlareStore's app sources/repositories:

https://github.com/StayLiquidy/GameDay-iOS/releases/latest/download/source.json

Refresh the source, select GameDay, and sign/install using the certificate configured in FlareStore. Keep the same bundle identifier (`net.inspectah.gameday`) and signing identity when updating to preserve the existing app's data. The public IPA is unsigned and contains no personal provisioning profile. FlareStore must sign it before installation.

Releases: https://github.com/StayLiquidy/GameDay-iOS/releases

This repository contains only the native iPhone project. No provider credentials, playlists, developer certificates, or device profiles are included.

## Publishing subsequent updates

Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for both configurations in `GameDay.xcodeproj/project.pbxproj`, commit, and push a matching version-only tag such as `v0.13`. Increment the marketing version for every public update; keep the build number separate in the app and feed metadata so GitHub-based app importers compare versions correctly. The release workflow builds an unsigned IPA and publishes `GameDay.ipa`, `icon.png`, and `source.json`. The source URL above stays the same; refresh it in FlareStore to see the new version. Installation still requires your signing certificate and the normal iOS confirmation.

For a local release, archive with `CODE_SIGNING_ALLOWED=NO`, then run `python3 scripts/package_release.py path/to/GameDay.xcarchive`. Upload the three files in `dist/` to the matching GitHub release. The workflow requires a macOS runner with Xcode 26 and package download access.

## Version 0.12 (build 19)

- Scores are visible in the game browser by default, including after upgrading. Settings → Scores still allows hiding browser scores; later choices are preserved.
- One centered loading indicator and one Picture in Picture button in KSPlayer.
- Public release packaging and a FlareStore-compatible source feed.

This Xcode project implements the first native milestone:

- SwiftUI onboarding and provider connection
- Generic Xtream account validation and live catalog import
- Credentials stored in the iOS Keychain only
- Searchable real channel and category lists
- EPGenius-style M3U imports from Files, including channel names, logos, groups, and XMLTV programme listings
- Auto-updating M3U URL sources (including Google Drive links supplied by EPGenius), refreshed when the app opens after six hours
- Multiple guide sources per provider with enable/disable controls, priority ordering, individual refresh, and removal
- Guide-assisted game matching plus current/next programme details in channel and player screens
- ESPN remains the sole source for the Games list; guide data enriches channel matching without injecting unrelated programme rows
- Guide indexing and search preparation run outside the interface thread so large XMLTV files do not freeze typing or startup
- NFL and college-football history remains cached for matching, while completed games leave Find a Game after a configurable Final-state window (three hours by default)
- Lightweight current-day ESPN checks while Find a Game is open keep live/final status changes current without reloading the entire schedule archive
- Imported file contents and stream URLs are discarded after matching; remote guide links are stored in the iOS Keychain
- KSPlayer's FFmpeg/Metal engine as the default player, with optional AVKit fallback
- Saved playback controls for hardware decoding, asynchronous decompression, and adaptive frame rate
- Automatic deinterlacing is visible but temporarily disabled because KSPlayer 2.3.4 can crash on some live MPEG-TS feeds when it is enabled
- Portrait-only browsing with automatic, in-place landscape fullscreen while a feed is playing
- App-managed fullscreen controls avoid KSPlayer's UIKit re-parenting path so playback continues through rotation
- Fullscreen hides the tab and navigation bars, ignores landscape safe-area edges, and defaults to aspect-fit so the full picture remains visible
- A fullscreen Fit/Fill control switches between uncropped video and edge-to-edge cropped video
- The app's Fit/Fill, Picture in Picture, and minimize controls fade with KSPlayer's standard playback controls
- KSPlayer Picture in Picture supports a manual PiP button and automatic PiP when leaving the app, subject to the iPhone's system PiP preference
- No provider credentials, profiles, or stream URLs in source or diagnostics

The provider host may use HTTP or HTTPS, including hostnames that change when a subscription migrates. HTTPS is preferred because HTTP sends provider credentials and stream traffic without transport encryption. Do not add credentials to source, tests, screenshots, or diagnostics.

The project pins KSPlayer 2.3.4 and FFmpegKit 6.1.4 through Swift Package Manager. Xcode may ask to install Apple's optional Metal Toolchain the first time it compiles the project.

## License

GameDay is distributed under the GNU General Public License, version 3. See `LICENSE`. KSPlayer and its GPL FFmpeg dependency are used under their respective GPL-compatible licenses. Any distributed binary must be accompanied by the corresponding source and license notices required by those licenses.
