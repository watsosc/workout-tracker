# WorkoutTracker iOS frontend (SwiftUI)

This is a native iOS frontend for the existing workout backend.

## Scope

- Mirrors core web features with native iOS UI patterns.
- Tabs included:
  - Workout
  - Analytics
  - History
  - Settings
- **Plan tab is intentionally excluded** (no plan create/edit on iOS).
- **Settings → Plans** lists all plans and lets you switch which one is active (or deactivate it).
- Workout screen includes live Bluetooth heart-rate support (standard BLE Heart Rate service, compatible with Garmin HR broadcasting):
  - live chart (left)
  - latest BPM text (right)
  - Bluetooth status icon bottom-right (gray + slash when not receiving, blue when receiving)
  - Garmin watches only send heart rate while broadcasting: turn on **Broadcast Heart Rate** for the
    activity profile you use (e.g. Strength) and start that activity on the watch. A watch already
    paired with the phone is picked up through its existing connection, no scan needed.

## Offline logging

Workouts are recorded **on the phone** and uploaded in one request (`logWorkout`) when you finish,
so logging works with no signal:

- The next workout's prescription is cached whenever the Workout tab loads with a connection, so a
  workout can be started offline.
- The in-progress workout (sets, rest timings, heart-rate samples) is saved to disk and survives
  the app being killed.
- Finished workouts go into an upload queue that retries automatically when connectivity returns
  (network change, app foreground, backoff timer). Uploads are idempotent (`clientId`), so a retry
  after a dropped response never double-logs.
- If the server rejects an upload outright it's kept and flagged in **Settings → Uploads** with
  Retry / Discard.
- A workout started on web is picked up and finished on the phone.
- Limitation: after finishing a workout offline, the *next* workout can't be started until the
  first one uploads (the server decides what comes next).

## In-workout changes

Change weight, skip / swap / add-a-set per exercise (⋯ menu), add exercises, and start empty
workouts — all on-device, so they work offline and upload with the workout. Finished workouts can
be edited or deleted from History (online).

## Tests

- Unit tests (`WorkoutTrackerIOSTests` target, run with ⌘U or `xcodebuild test`): local workout
  model, upload queue against a stubbed network, decoding data saved by older versions.
- Live integration (`../scripts/test-ios-integration.sh`): compiles the sync code for macOS and
  runs it against a throwaway backend.

## Live Activity (lock screen + Dynamic Island)

While a workout is in progress, a Live Activity shows the next set ("Squat · Set 3 of 5 · 3 reps @
225 lb"), sets done, and a rest countdown to the rest target ("Rest's up" once reached). It follows
the on-device workout (offline too) and ends when the workout is finished or discarded.

- Lives in the `WorkoutLiveActivity` widget extension; shared data is
  `WorkoutTrackerIOS/Shared/WorkoutActivityAttributes.swift`; the app side is
  `Core/LiveActivityController.swift`.
- Requires iOS 16.2+ (the app still supports 16.0 without it).
- Installing on a device: select your team for **both** the `WorkoutTrackerIOS` and
  `WorkoutLiveActivity` targets (Signing & Capabilities).

## Rest timer notifications

After each set the app schedules a local notification for when the rest target is up (asks for
notification permission on the first workout).

## Backend endpoint

Default GraphQL endpoint is set to:

- `https://watsoworkout.duckdns.org/graphql`

You can change it in **Settings → API**. When the server requires a login, a sign-in sheet appears
(username/password); the session token is stored in the Keychain. Workouts recorded while signed
out stay queued and upload after you sign in.

## Project layout

- `WorkoutTrackerIOS/`
  - `Core/` GraphQL client, API layer, app settings
  - `Models/` Codable app models
  - `Features/` SwiftUI feature views + view models
  - `Shared/` shared formatters/helpers

## Notes

- This folder now includes a ready-to-open Xcode project:
  - `ios/WorkoutTrackerIOS.xcodeproj`
- Recommended deployment target: iOS 16+ (uses SwiftUI + Charts).
- Dev launcher from repo root:
  - `./scripts/dev-all.sh --ios` (reuses a booted simulator when available, then builds/installs/launches app against local backend)
  - `./scripts/dev-all.sh --ios --ios-device "iPhone 16"` (pick preferred simulator model)
  - `./scripts/dev-all.sh --ios --ios-list-devices` (list booted/available iPhone simulators)
  - `./scripts/dev-all.sh --ios --ios-mock-heart-rate` (force a looping 80-135 bpm mock stream for in-workout UI testing)
- Demo data seed command:
  - `npm run seed:test-data` (creates demo plan + active workout session + completed history + heart-rate samples)
