# CaliBar

A free, native menu-bar companion for Apple Calendar. **[Website](https://calibar.app)** · **[Download for Mac](https://github.com/RobSwish/calibar/releases/latest/download/CaliBar.zip)** · [Releases](https://github.com/RobSwish/calibar/releases)

macOS 14 or later, on Apple silicon and Intel. Unzip CaliBar, move it to Applications, and open it. Turn on **Sync calendars** to grant calendar access. CaliBar reads the calendars already configured in macOS; it never edits your events.

## Features

- Month calendar and daily agenda, with the calendar colours you already use.
- Next appointment in the menu bar, with date-format and today-only options.
- Join video calls from the agenda or event details. Command-click the menu-bar item to join its displayed video meeting.
- Choose which installed browser opens your video calls.
- Event notes, location and invitation responses; open the selected event in Apple Calendar from the footer.
- Times follow your Mac’s locale and 12/24-hour preference.
- Launch at login and signed Sparkle updates. Refresh calendars with Command-R; Settings with Command-comma.
- Liquid Glass on macOS 26+, with a frosted panel on earlier versions. Motion respects Reduce Motion.

CaliBar recognises supported Google Meet, Zoom, Microsoft Teams, Webex and FaceTime links in event URLs, locations and notes. Calendar accounts remain managed by macOS. There is no CaliBar account, advertising or analytics. Automatic update checks contact the GitHub-hosted release feed; turn them off in Settings if preferred.

## Development

Requires Xcode with the macOS 26 SDK or newer, Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Sparkle is pinned to 2.10.0.

```sh
./scripts/build.sh
open build/CaliBar.app
swift test
```

Use `open -n build/CaliBar.app --args --demo` to show fictional events without reading personal calendars. Join actions and updates are disabled in demo mode. Add `--demo-settings` or `--demo-event` to open the corresponding view for screenshots.

`Sources/CaliBar` contains the AppKit/SwiftUI app. `Sources/CaliBarCore` contains calendar reading, date handling, link detection and display logic. Tests cover date boundaries, menu-bar preferences, participant ordering, meeting URLs and Apple Calendar links. `project.yml` generates the Xcode project and app configuration.

The bundle identifier remains `com.robswift.Daybar` to preserve the identity of earlier development builds. All visible branding is CaliBar.

## Releases

Releases use Developer ID signing, Apple notarization and Sparkle Ed25519 archive signatures. See [the release guide](docs/releases.md). Signing secrets stay in the maintainer’s Keychain and are never committed.

## Website

The [Astro website](website/) uses system SF fonts, Inter fallback, Hugeicons and CSS motion. See its [README](website/README.md) for local development and deployment. Its download buttons use the latest public GitHub release.

Third-party licences and artwork sources are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
