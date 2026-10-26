# Privacy

WheelFlip runs locally. The app has no account system, advertising, analytics SDK, automatic update service, or application network requests.

## Input handling

The engine observes scroll-wheel events to choose a direction and, when requested, reverse their deltas. It does not subscribe to keyboard events. Accessibility permission is used to modify scrolling.

To apply per-app rules, WheelFlip resolves the event's target process to an application identifier. It also discovers application names, locations, and icons through local macOS APIs. The recent target shown in the panel is held in memory rather than saved as an activity history.

## Local storage

The app stores default and per-app rules, relevant application paths, and security-scoped bookmarks for manually selected apps in its own Application Support directory. It retains a backup if a rules file cannot be read. These files are not uploaded.

The application identifier is `com.jonywu.WheelFlip`. A sandboxed installation keeps its data inside that application's macOS container.

## Diagnostics and development

Explicitly running the headless tools or `probe/` diagnostics can print or save application identifiers, process identifiers, paths, event positions, and timestamps. Diagnostic logs can reveal personal information. Review and redact them before sharing; they are not automatically sent anywhere.

GitHub separately handles information submitted through issues, pull requests, and repository visits under its own policies. Do not attach private rules or diagnostic files to a public issue without checking their contents.

## Controls

Pause stops scroll modification. Quit stops the service and unregisters the login item. Accessibility access can be revoked in System Settings. To remove local settings, quit the app and remove its application container only after confirming the container belongs to WheelFlip.
