# Architecture

WheelFlip is a single-process macOS menu bar application. The SwiftUI interface is hosted by AppKit; there is no separate helper service.

## Event engine

`FlipEngine` installs one active `CGEventTap` at the annotated session position and subscribes only to scroll-wheel events. Continuous events pass through. For discrete events, the engine resolves the target process, evaluates an immutable rule snapshot, and reverses all six vertical/horizontal delta fields when needed.

All fields are read before any write because Core Graphics can synchronize related delta fields during a write. `ScrollFlip` contains the pure transformation.

Stopping disables the tap, removes the run-loop source, and invalidates the port. Reenable attempts use backoff; repeated timeouts eventually surface an engine failure instead of looping indefinitely.

## Application state

`AppState` distinguishes running, paused, missing permission, engine failure, and damaged rules. It depends on injectable engine and login-item interfaces. Rule changes persist before publication to the event engine.

`LoginItemManager` uses `SMAppService.mainApp`. Pause retains the registration; explicit quit removes it. `PermissionRelauncher` waits for the previous process to exit before reopening the app. Paths are passed as positional arguments, not shell source.

## Storage and discovery

`RuleStore` stores versioned JSON with atomic writes, verification, and recovery backups. `RuleSnapshotBox` provides in-memory rule snapshots. `ManualAppStore` persists selected application paths and security-scoped bookmarks.

Application discovery combines directory scans, Spotlight, running apps, and manual selections. An unreadable location is not evidence that an application has been uninstalled. See [per-app rules](PER_APP_SCROLL_PLAN.md).

## Verification

Unit tests cover transformations, policies, storage, reconciliation, presentation, permission relaunch, and lifecycle state. Installer tests run in temporary directories with a fake `launchctl`. Live event tests and permission checks are separate; see [CONTRIBUTING.md](../CONTRIBUTING.md).
