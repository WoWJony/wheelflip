# Per-app scroll rules

Rules are keyed by bundle identifier, not a display name or a process identifier.

| Rule | Effective behavior |
| --- | --- |
| Inherit | Use the global default |
| Force on | Reverse the wheel |
| Force off | Preserve the original event |

Pause bypasses all rules. Continuous scrolling bypasses both rule evaluation and target resolution.

## Target identity

The engine uses the annotated event's target process ID, which identifies the receiving window's application in supported cases. It does not substitute the frontmost app. An unresolvable target falls back to the global default, never the previous event's target.

`AppIdentityResolver` caches process-to-application mappings. Helper executables inside an application bundle are associated with the outermost app. Exit notifications and periodic pruning invalidate cached entries.

## Discovering apps

The catalog combines local application directories, Spotlight, running applications, and user-selected apps. It tracks incomplete or inaccessible sources separately. The management list is the union of discovered apps and saved overrides, so a missed scan does not hide a saved rule.

## Removing obsolete rules

Reconciliation requires affirmative absence evidence, a grace period, repeated confirmation, and a final check before removing an override. A revision guard prevents a stale cleanup proposal from deleting a newly edited rule. Inaccessible or offline locations do not establish absence.

## Event latency

Rules are read from a memory snapshot in the event callback. Target mappings are cached; failed stable lookups are negatively cached. Persistence and catalog refreshes are kept out of the event callback.

The `probe/` utilities are optional developer diagnostics. They may log app identities, paths, positions, and timestamps; review their output before sharing.
