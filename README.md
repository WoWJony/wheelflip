<p align="center">
  <img src="app/WheelFlip/Resources/Assets.xcassets/AppIconV2.appiconset/icon_128x128@2x.png" width="100" alt="WheelFlip icon">
</p>

# WheelFlip

**Reverse your mouse wheel. Keep your trackpad natural. Set a different direction for each app.**

A small, native macOS menu bar utility built with SwiftUI and AppKit. No account, ads, analytics, or network connection required.

[Download for macOS](https://github.com/WoWJony/wheelflip/releases/latest) · [Install with an agent](#install-with-an-agent) · [简体中文](README.zh-CN.md) · [MIT license](LICENSE)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-native-F05138)
[![CI](https://github.com/WoWJony/wheelflip/actions/workflows/ci.yml/badge.svg)](https://github.com/WoWJony/wheelflip/actions/workflows/ci.yml)

<p align="center">
  <img src="docs/assets/panel-en.png" width="380" alt="WheelFlip menu panel showing the scroll direction for TextEdit">
</p>

## What it does

- **Separate mouse and trackpad behavior.** Reverse discrete wheel events while leaving continuous scrolling unchanged.
- **Choose per-app rules.** Each app can reverse, keep its direction, or follow your default.
- **Follow the receiving window.** Rules use the app receiving the scroll event, including an unfocused window under the pointer.
- **Pause everything in one click.** Restore ordinary scrolling without losing your rules.
- **Stay out of the way.** A menu bar panel, no Dock icon, and English / Simplified Chinese UI.
- **Keep settings on your Mac.** Rules and app bookmarks stay in the app's local container. [Privacy details](PRIVACY.md).

For example: keep your browser's wheel direction reversed, preserve the original direction in a drawing app, and keep natural scrolling on the trackpad.

<p align="center">
  <img src="docs/assets/rules-en.png" width="760" alt="Per-app scroll direction rules for Preview and Terminal">
</p>

Screenshots are rendered from the real UI with sample data.

## Download and install

**macOS 14+ · Apple silicon and Intel · No Xcode required**

[Download DMG](https://github.com/WoWJony/wheelflip/releases/latest/download/WheelFlip-universal.dmg) · [Download ZIP](https://github.com/WoWJony/wheelflip/releases/latest/download/WheelFlip-universal.zip) · [Release notes and checksums](https://github.com/WoWJony/wheelflip/releases/latest)

1. Open the DMG and drag **WheelFlip** onto **Applications**. For ZIP, extract the app and move it to Applications. You can use your personal `~/Applications` folder if you do not have permission to install for all users.
2. Open the installed copy, then eject the DMG. WheelFlip lives in the **menu bar**, not the Dock.
3. Follow [First run](#first-run) to enable Accessibility access.

The current release is **ad-hoc signed, not Developer ID signed or Apple-notarized**. If macOS blocks it as an unverified app, and you trust this release, use **System Settings → Privacy & Security → Open Anyway** after the first launch attempt. This follows [Apple's instructions](https://support.apple.com/en-us/102445). Keep macOS security checks enabled.

When updating, quit WheelFlip before replacing the app and keep the same installation path. Your rules remain in the local container; you may need to authorize the new copy again.

## Install with an agent

Copy this prompt into **Claude Code, Codex, or another agent with terminal access to your Mac**. The agent handles the files and opens the right settings page; you handle macOS confirmation dialogs and the Accessibility switch.

```text
Install WheelFlip on my Mac from https://github.com/WoWJony/wheelflip.
Read the repository's README.md and AGENTS.md first. Explain progress briefly
in my language and complete the installation, rather than just giving commands.

1. Confirm you can access my Mac and that it runs macOS 14 or newer. A cloud
   workspace alone cannot install an app on my computer.
2. Prefer the latest official Release: download WheelFlip-universal.zip and
   SHA256SUMS.txt, and verify the ZIP checksum before extracting it. The binary
   needs neither Xcode nor a GitHub account. Build from source only if I ask or
   a release is unavailable; follow the README in an isolated build directory.
3. Install to ~/Applications/WheelFlip.app, or retain an existing installation's
   path when updating. Quit the old instance normally before replacement, keep
   a backup of its app bundle, and preserve its settings. Launch only the final
   installed copy with open, not the executable inside the bundle.
4. This release is not Apple-notarized. If macOS blocks it as unverified, open
   Privacy & Security with:
     open 'x-apple.systempreferences:com.apple.preference.security'
   Guide me to the app-specific Open Anyway button.
   Leave the confirmation and any password/Touch ID dialog to me; keep the
   system's security checks enabled. Do not treat a damaged-app or malware
   warning as the normal unverified-developer prompt.
5. Set wheelflip_app to the absolute path of the installed app. Proactively run:
     open -R "$wheelflip_app"
     open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
   Tell me: click +, press Command-Shift-G, paste the full parent folder path
   you provide, choose WheelFlip.app, click Open, and turn its switch on.
   If the correct entry is already listed, just enable it. Show the actual
   expanded folder path, not a placeholder. Wait for me to confirm this step.
6. After I confirm, use WheelFlip's Reopen and Check button, or quit normally
   and reopen that same installed copy. If you cannot operate its UI, guide me
   to that button. Verify the panel says Enabled; without screen access, ask
   me to confirm it. A headless check can inherit Terminal's permission and
   is not proof. If still denied, help me re-add only the stale WheelFlip entry.
7. Ask me to try the mouse wheel and trackpad, then report the installed version
   and path, any remaining blocker, and how to pause or quit. Mention that Pause
   retains the login item while Quit unregisters it. Do not claim success before
   the app is actually running with permission.
```

## Build from source

Requires **macOS 14 or later**, full Xcode with the macOS 14 SDK or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). These tools are only needed to build from source.

```sh
brew install xcodegen
git clone https://github.com/WoWJony/wheelflip.git
cd wheelflip/app
xcodegen generate
xcodebuild -project WheelFlip.xcodeproj -scheme WheelFlip \
  -configuration Release -derivedDataPath build/local build
codesign -f -s - --entitlements WheelFlip/WheelFlip.entitlements \
  --identifier com.jonywu.WheelFlip \
  build/local/Build/Products/Release/WheelFlip.app
open build/local/Build/Products/Release/WheelFlip.app
```

This uses a local ad-hoc signature. Quit an existing copy before replacing its app bundle; a rebuild can invalidate Accessibility authorization. Use a separate build directory during development.

## First run

1. Keep **Natural scrolling** enabled in macOS if you want natural trackpad scrolling and traditional mouse-wheel scrolling.
2. Click WheelFlip's menu bar icon, then **Open System Settings…** in its permission guide to open the Accessibility page.
3. Click **Show This App in Finder** to locate the installed copy. In Accessibility, click **+**, select that exact `WheelFlip.app`, and enable its switch. Complete any authentication in the macOS dialog.
4. Use **Reopen and Check** in WheelFlip after granting access.
5. Choose a default direction and add any per-app exceptions.

**Lifecycle:** starting the rule service registers WheelFlip as a login item. Pause keeps the login item; pause lasts only for the current session. **Quit WheelFlip** stops the service and unregisters the login item. Login items can also be managed in System Settings.

## Scope and limitations

- WheelFlip adjusts direction, not pointer acceleration, scroll speed, or smoothing.
- Vertical and horizontal wheel directions are reversed together.
- Continuous events pass through, including typical trackpad and Magic Mouse scrolling. A mouse driver that emits continuous events can also bypass reversal.
- Unidentified scroll targets use the default rule.
- App discovery can be limited by the sandbox. Use **Add App…** for apps in other locations.
- Run one scroll-modifying utility at a time to avoid double reversal.
- If a rebuild loses permission, remove the old Accessibility entry, add the new app, and reopen it.

## Development

```sh
python3 -m unittest discover -s test -p 'test_*.py' -v
cd app
xcodegen generate
xcodebuild test -project WheelFlip.xcodeproj -scheme WheelFlip \
  -destination 'platform=macOS' -derivedDataPath build/validation
```

Unit tests use fakes for the engine and login service. Live event tests need Accessibility permission and careful instance isolation; see [CONTRIBUTING.md](CONTRIBUTING.md).

| Location | Purpose |
| --- | --- |
| `app/WheelFlip/` | Menu bar app, event engine, rules, and permissions |
| `app/Tests/` | XCTest suite |
| `test/` | Installer regression and live scroll tests |
| `probe/` | Optional event-routing diagnostics |
| `Sources/`, `launchd/` | Legacy CLI implementation |

## Contributing

Bug reports, translations, and focused improvements are welcome. Please include your macOS version, mouse model, and reproduction steps. Read the [contribution guide](CONTRIBUTING.md) before attaching diagnostic logs.

If WheelFlip solves a small annoyance for you, a star helps other Mac users find it.

Made by [Jony Wu](https://github.com/WoWJony). Released under the [MIT license](LICENSE).
