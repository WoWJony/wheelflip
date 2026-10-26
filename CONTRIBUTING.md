# Contributing

Thanks for helping improve WheelFlip. Focused bug fixes, translation improvements, and reproducible reports are welcome.

## Build and test

Use Xcode and XcodeGen. The README contains the local build and signing steps. Keep generated projects and build output out of Git.

```sh
python3 -m unittest discover -s test -p 'test_*.py' -v
cd app
xcodegen generate
xcodebuild test -project WheelFlip.xcodeproj -scheme WheelFlip \
  -destination 'platform=macOS' -derivedDataPath build/validation
```

The installer test replaces `launchctl` with a stub and uses temporary paths. XCTest uses a host-isolation guard to avoid starting a second event tap or registering login items.

Do not overwrite a running app bundle. Use a separate derived-data directory and expect to reauthorize an ad-hoc-signed build after changes.

## Live scroll tests

`make test` needs exactly one active flipping engine and event access. `make route-test` starts its own headless engine and needs exclusive access: quit other scroll-modifying instances first. These tests send synthetic scroll events to the desktop; do not run them unattended against an active work session.

These commands use `uv` to supply PyObjC. The route test expects a Release build at `app/build/per-app-validation/Build/Products/Release/WheelFlip.app`; build and ad-hoc sign that isolated copy using the README commands with `build/per-app-validation` as the derived-data path.

Headless processes can inherit a terminal's Accessibility authorization. Verify actual app authorization by launching through Finder or `open`, not by relying on a headless permission check.

## UI fixtures

The `--ui-fixture` mode uses a fake engine, temporary settings, sample applications, and a fake login manager. It can render screenshots without Accessibility or Screen Recording access:

```sh
app/build/validation/Build/Products/Debug/WheelFlip.app/Contents/MacOS/WheelFlip \
  --ui-fixture --scenario running --shot /tmp/wheelflip-panel.png \
  -AppleLanguages '(en)'
```

Other scenarios include `paused`, `permission`, `engine-failed`, `rules-corrupt`, `save-failure`, `no-target`, and `stress`.

## Reporting and changes

- Include macOS version, mouse model, relevant driver software, and reproduction steps.
- Redact app paths, project names, and personal details from screenshots and logs.
- Use four-space Swift indentation and keep system interactions separate from pure rule logic.
- Add regression coverage for behavior changes. Keep unrelated refactors separate.
- Edit `app/project.yml` rather than generated Xcode project files.
- Describe what changed and how you tested it in the pull request.

Report security problems using [private vulnerability reporting](https://github.com/WoWJony/wheelflip/security/advisories/new).
