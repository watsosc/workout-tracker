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
