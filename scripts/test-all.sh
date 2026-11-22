#!/usr/bin/env bash
# Run every test suite: backend, web unit + type check, web end-to-end, iOS unit, iOS live integration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIMULATOR="${IOS_SIMULATOR:-iPhone 17}"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

step "Backend (pytest)"
(cd "$ROOT/backend" && .venv/bin/python -m pytest -q)

step "Web unit tests + type check"
(cd "$ROOT/web" && npm test --silent && npm run check --silent)

step "Web end-to-end (Playwright)"
(cd "$ROOT/web" && npx playwright test)

step "iOS unit tests (simulator: $SIMULATOR)"
(cd "$ROOT/ios" && xcodebuild test -quiet -project WorkoutTrackerIOS.xcodeproj -scheme WorkoutTrackerIOS \
  -destination "platform=iOS Simulator,name=$SIMULATOR" CODE_SIGNING_ALLOWED=NO)

step "iOS sync code against a live backend"
bash "$ROOT/scripts/test-ios-integration.sh"

printf '\n\033[1;32mAll suites passed\033[0m\n'
