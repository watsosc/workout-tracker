#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
WEB_DIR="$ROOT_DIR/web"
IOS_PROJECT="$ROOT_DIR/ios/WorkoutTrackerIOS.xcodeproj"
BACKEND_UVICORN="$BACKEND_DIR/.venv/bin/uvicorn"

MODE="web"
IOS_DEVICE_NAME="iPhone 16"
IOS_LIST_DEVICES_ONLY="false"
IOS_MOCK_HEART_RATE="false"

usage() {
  cat <<EOF
Usage: ./scripts/dev-all.sh [--web|--ios] [--ios-device <name>] [--ios-list-devices] [--ios-mock-heart-rate]
  --web                 Run backend + Svelte web frontend (default)
  --ios                 Run backend + iOS Simulator app
  --ios-device <name>   Preferred simulator device name (default: iPhone 16)
  --ios-list-devices    List booted/available iPhone simulators and exit
  --ios-mock-heart-rate Force a looping 80-135 bpm mock stream in the iOS app
EOF
}

list_ios_devices() {
  echo "Booted iPhone simulators:"
  xcrun simctl list devices | grep -E '^[[:space:]]*iPhone.*\([0-9A-F-]{36}\) \(Booted\)' || echo "  (none)"
  echo ""
  echo "Available iPhone simulators:"
  xcrun simctl list devices available | grep -E '^[[:space:]]*iPhone.*\([0-9A-F-]{36}\)' || echo "  (none)"
}

escape_regex() {
  printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\/]/\\&/g'
}

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | grep -qE ":$port\\s"
    return $?
  fi
  return 1
}

BACKEND_PID=""
WEB_PID=""
cleanup() {
  if [[ -n "$BACKEND_PID" ]]; then kill "$BACKEND_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$WEB_PID" ]]; then kill "$WEB_PID" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --web)
      MODE="web"
      ;;
    --ios)
      MODE="ios"
      ;;
    --ios-device)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --ios-device"; exit 1; }
      IOS_DEVICE_NAME="$1"
      ;;
    --ios-device=*)
      IOS_DEVICE_NAME="${1#--ios-device=}"
      ;;
    --ios-list-devices)
      IOS_LIST_DEVICES_ONLY="true"
      ;;
    --ios-mock-heart-rate)
      IOS_MOCK_HEART_RATE="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ ! -x "$BACKEND_UVICORN" ]]; then
  echo "Missing backend venv/uvicorn at $BACKEND_UVICORN"
  echo "Run:"
  echo "  cd backend"
  echo "  python -m venv .venv"
  echo "  source .venv/bin/activate"
  echo "  python -m pip install --upgrade pip"
  echo "  pip install ."
  exit 1
fi

if port_in_use 8000; then
  echo "Port 8000 is already in use. Stop existing backend first."
  exit 1
fi

if [[ "$MODE" == "web" ]] && port_in_use 5173; then
  echo "Port 5173 is already in use. Stop existing web frontend first."
  exit 1
fi

if [[ "$MODE" == "web" ]]; then
  if [[ ! -d "$WEB_DIR/node_modules" ]]; then
    echo "Installing web dependencies..."
    (cd "$WEB_DIR" && npm install)
  fi
else
  [[ -d "$IOS_PROJECT" ]] || { echo "Missing iOS project at $IOS_PROJECT"; exit 1; }
  command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is required for --ios mode."; exit 1; }
  command -v xcrun >/dev/null 2>&1 || { echo "xcrun is required for --ios mode."; exit 1; }

  if [[ "$IOS_LIST_DEVICES_ONLY" == "true" ]]; then
    list_ios_devices
    exit 0
  fi

  DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$DEV_DIR" != *"Xcode.app"* ]]; then
    echo "--ios mode requires full Xcode (active developer dir is '$DEV_DIR')."
    echo "Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
  fi
fi

echo "Starting backend on http://127.0.0.1:8000 ..."
"$BACKEND_UVICORN" app.main:app --app-dir "$BACKEND_DIR" --reload --host 127.0.0.1 --port 8000 &
BACKEND_PID="$!"

if [[ "$MODE" == "web" ]]; then
  echo "Starting web frontend on http://127.0.0.1:5173 ..."
  (cd "$WEB_DIR" && npm run dev -- --port 5173) &
  WEB_PID="$!"

  echo ""
  echo "Dev stack is running (web):"
  echo "  Web:     http://127.0.0.1:5173"
  echo "  GraphQL: http://127.0.0.1:8000/graphql"
  echo ""
  echo "Press Ctrl-C to stop both."

  wait "$BACKEND_PID" "$WEB_PID"
else
  echo "Launching iOS frontend in Simulator (not hardware device)..."
  open -a Simulator

  preferred_regex="$(escape_regex "$IOS_DEVICE_NAME")"
  target_line=""
  target_source=""

  # Always reuse an already running simulator first.
  target_line="$(xcrun simctl list devices | grep -E "^[[:space:]]*$preferred_regex \([0-9A-F-]{36}\) \(Booted\)" | head -n 1 || true)"
  if [[ -n "$target_line" ]]; then
    target_source="booted-preferred"
  fi

  if [[ -z "$target_line" ]]; then
    target_line="$(xcrun simctl list devices | grep -E '^[[:space:]]*iPhone.*\([0-9A-F-]{36}\) \(Booted\)' | head -n 1 || true)"
    if [[ -n "$target_line" ]]; then
      target_source="booted-any"
    fi
  fi

  # If nothing is booted, pick preferred available, then any available iPhone.
  if [[ -z "$target_line" ]]; then
    target_line="$(xcrun simctl list devices available | grep -E "^[[:space:]]*$preferred_regex \([0-9A-F-]{36}\)" | head -n 1 || true)"
    if [[ -n "$target_line" ]]; then
      target_source="available-preferred"
    fi
  fi
  if [[ -z "$target_line" ]]; then
    target_line="$(xcrun simctl list devices available | grep -E '^[[:space:]]*iPhone.*\([0-9A-F-]{36}\)' | head -n 1 || true)"
    if [[ -n "$target_line" ]]; then
      target_source="available-any"
    fi
  fi

  TARGET_UDID="$(echo "$target_line" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
  TARGET_NAME="$(echo "$target_line" | sed -E 's/^[[:space:]]*//; s/ \([0-9A-F-]{36}\).*//')"

  if [[ -z "$TARGET_UDID" ]]; then
    echo "Could not find an available iPhone simulator device."
    exit 1
  fi

  echo "Selected simulator: $TARGET_NAME ($TARGET_UDID) [$target_source]"
  if [[ "$target_source" == booted-* ]]; then
    echo "Reusing already booted simulator."
  fi

  # Keep only one booted simulator (the selected target) for predictable launches.
  BOOTED_UDIDS="$(xcrun simctl list devices | sed -nE 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p')"
  while IFS= read -r udid; do
    if [[ -n "$udid" && "$udid" != "$TARGET_UDID" ]]; then
      echo "Shutting down extra booted simulator: $udid"
      xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    fi
  done <<< "$BOOTED_UDIDS"

  xcrun simctl boot "$TARGET_UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$TARGET_UDID" -b >/dev/null

  DERIVED_DATA="$ROOT_DIR/ios/.derived"
  echo "Building iOS app for simulator $TARGET_NAME ($TARGET_UDID) ..."
  xcodebuild \
    -project "$IOS_PROJECT" \
    -scheme WorkoutTrackerIOS \
    -configuration Debug \
    -destination "id=$TARGET_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    build

  APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/WorkoutTrackerIOS.app"
  [[ -d "$APP_PATH" ]] || { echo "Built app not found at $APP_PATH"; exit 1; }

  APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || true)"
  if [[ -z "$APP_BUNDLE_ID" ]]; then
    APP_BUNDLE_ID="com.seanwatson.WorkoutTrackerIOS"
  fi

  xcrun simctl install "$TARGET_UDID" "$APP_PATH"

  # Ensure local script-driven runs default to local backend in app settings.
  LOCAL_GRAPHQL_ENDPOINT="http://127.0.0.1:8000/graphql"
  if ! xcrun simctl spawn "$TARGET_UDID" defaults write "$APP_BUNDLE_ID" workout.ios.graphql-endpoint "$LOCAL_GRAPHQL_ENDPOINT" >/dev/null 2>&1; then
    echo "Warning: could not prewrite simulator defaults for $APP_BUNDLE_ID"
  fi

  if [[ "$IOS_MOCK_HEART_RATE" == "true" ]]; then
    xcrun simctl spawn "$TARGET_UDID" defaults write "$APP_BUNDLE_ID" workout.ios.mock-heart-rate -bool true >/dev/null 2>&1 || true
    echo "Enabled mock heart-rate stream (80-135 bpm loop)."
  else
    xcrun simctl spawn "$TARGET_UDID" defaults write "$APP_BUNDLE_ID" workout.ios.mock-heart-rate -bool false >/dev/null 2>&1 || true
  fi

  LAUNCH_OUTPUT="$(SIMCTL_CHILD_WORKOUT_GRAPHQL_ENDPOINT="$LOCAL_GRAPHQL_ENDPOINT" SIMCTL_CHILD_WORKOUT_MOCK_HEART_RATE="$([[ "$IOS_MOCK_HEART_RATE" == "true" ]] && echo 1 || echo 0)" \
    xcrun simctl launch --terminate-running-process "$TARGET_UDID" "$APP_BUNDLE_ID" 2>&1 || true)"

  if ! echo "$LAUNCH_OUTPUT" | grep -q "$APP_BUNDLE_ID"; then
    echo "Failed to launch app automatically."
    echo "$LAUNCH_OUTPUT"
    echo "Try launching manually from Simulator home screen (app id: $APP_BUNDLE_ID)."
  fi

  echo ""
  echo "Dev stack is running (iOS simulator):"
  echo "  Simulator device: $TARGET_NAME ($TARGET_UDID)"
  echo "  Bundle id:        $APP_BUNDLE_ID"
  echo "  GraphQL:          http://127.0.0.1:8000/graphql"
  echo "  App endpoint:     $LOCAL_GRAPHQL_ENDPOINT"
  echo "  Mock HR stream:   $IOS_MOCK_HEART_RATE"
  echo ""
  echo "Press Ctrl-C to stop backend."

  wait "$BACKEND_PID"
fi
