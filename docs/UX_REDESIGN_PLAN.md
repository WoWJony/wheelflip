# Interface design

The panel presents three distinct choices:

1. **Service state:** whether WheelFlip is running, paused, waiting for permission, or unable to start.
2. **Application rule:** which application is being edited and whether it reverses, preserves, or inherits the direction.
3. **Default direction:** what happens in applications without a custom rule.

The editing target is pinned while the panel is open. Manual selection remains available without first launching or scrolling the target app. The engine continues routing each event independently of the panel's editing target.

## Feedback

Effective-direction text reflects service state: a paused app says what will happen after resuming rather than implying that rules are active. Save failures are shown beside the affected control; invalid rule files expose explicit repair choices.

## Permission flow

The panel explains Accessibility access, opens System Settings, reveals the running app bundle, and offers a restart to recheck permission. A failed recheck remains visible. Settings can be browsed while permission is unavailable.

## Management window

The list supports searching and filtering custom rules. Saved rules remain visible when a catalog source is unavailable. Changes save immediately; closing the window does not discard them.

## Screenshots and fixtures

Public screenshots use system application names and the isolated `--ui-fixture` mode. The fixture supplies fake engine/login services and temporary storage. It does not enumerate a user's live applications for screenshots.
