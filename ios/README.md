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

## Backend endpoint

Default GraphQL endpoint is set to:

- `https://watsoworkout.duckdns.org/graphql`

You can change it in **Settings → API**.

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
