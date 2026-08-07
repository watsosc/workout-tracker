#!/usr/bin/env fish

set -l SCRIPT_DIR (cd (dirname (status --current-filename)); pwd)
set -l ROOT_DIR (cd "$SCRIPT_DIR/.."; pwd)
set -l BACKEND_DIR "$ROOT_DIR/backend"
set -l WEB_DIR "$ROOT_DIR/web"
set -l BACKEND_UVICORN "$BACKEND_DIR/.venv/bin/uvicorn"

if not test -x "$BACKEND_UVICORN"
	echo "Missing backend venv/uvicorn at $BACKEND_UVICORN"
	echo "Run:"
	echo "  cd backend"
	echo "  python -m venv .venv"
	echo "  source .venv/bin/activate.fish"
	echo "  pip install -e ."
	exit 1
end

if not test -d "$WEB_DIR/node_modules"
	echo "Installing web dependencies..."
	cd "$WEB_DIR"
	npm install
	cd "$ROOT_DIR"
end

if command -sq ss
	if ss -ltn | grep -qE ':8000\s'
		echo "Port 8000 is already in use. Stop existing backend first."
		exit 1
	end
	if ss -ltn | grep -qE ':5173\s'
		echo "Port 5173 is already in use. Stop existing frontend first."
		exit 1
	end
end

echo "Starting backend on http://127.0.0.1:8000 ..."
"$BACKEND_UVICORN" app.main:app --app-dir "$BACKEND_DIR" --reload --host 127.0.0.1 --port 8000 &
set -g DEV_ALL_BACKEND_PID $last_pid

echo "Starting frontend on http://127.0.0.1:5173 ..."
cd "$WEB_DIR"
npm run dev -- --port 5173 &
set -g DEV_ALL_WEB_PID $last_pid
cd "$ROOT_DIR"

function __workout_dev_all_cleanup --on-signal INT --on-signal TERM --on-process-exit %self
	for pid in $DEV_ALL_BACKEND_PID $DEV_ALL_WEB_PID
		if test -n "$pid"
			kill $pid >/dev/null 2>&1
		end
	end
end

echo ""
echo "Dev stack is running:"
echo "  Web:     http://127.0.0.1:5173"
echo "  GraphQL: http://127.0.0.1:8000/graphql"
echo ""
echo "Press Ctrl-C to stop both."

wait $DEV_ALL_BACKEND_PID $DEV_ALL_WEB_PID

set -e DEV_ALL_BACKEND_PID DEV_ALL_WEB_PID
functions -e __workout_dev_all_cleanup
