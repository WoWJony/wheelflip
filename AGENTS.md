# Repository Guidelines

WheelFlip is a Swift menu bar app for macOS 14+ that reverses mouse-wheel scrolling with per-app rules.

## Structure

- `app/WheelFlip/`: SwiftUI/AppKit UI, event engine, rule storage, and system managers.
- `app/Tests/`: XCTest tests.
- `app/project.yml`: XcodeGen configuration; generated projects are ignored.
- `test/`: Installer regression and live event tests.
- `Sources/`, `launchd/`: Legacy CLI.
- `docs/`: Public architecture and UI notes.

## Build and test

Generate with `xcodegen generate --spec app/project.yml`. Build or test using a separate derived-data directory such as `app/build/validation`. Never overwrite a running app bundle; its ad-hoc Accessibility identity can change.

Run `python3 -m unittest discover -s test -p 'test_*.py' -v` and the XCTest command in CONTRIBUTING.md after relevant code changes. Run live event tests after engine changes only when the required permission and instance isolation are available. Do not treat a skipped live test as a pass.

## Behavior and style

- Use four-space indentation, UpperCamelCase types, and lowerCamelCase members.
- Keep scroll math in `ScrollFlip` and system calls in dedicated managers.
- Read all six scroll fields before writing reversed values; pass continuous events through.
- Pausing retains rules and the login item; quitting removes the tap and login item.
- Permission validation must use a Finder or `open` launch; headless tools can inherit terminal authorization.
- Pass paths as arguments, never interpolated shell code.
- Use temporary directories and fakes in tests. Never modify a user's live configuration for a test.
- Do not commit credentials, private logs, personal screenshots, generated projects, or build outputs.

Use focused commits such as `fix:`, `feat(app):`, `build:`, and `docs:`. Include test results and screenshots for UI changes.
