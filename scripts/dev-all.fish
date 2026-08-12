#!/usr/bin/env fish

set -l SCRIPT_DIR (cd (dirname (status --current-filename)); pwd)
set -l SH_SCRIPT "$SCRIPT_DIR/dev-all.sh"

if not test -x "$SH_SCRIPT"
	echo "Missing executable script: $SH_SCRIPT"
	exit 1
end

exec bash "$SH_SCRIPT" $argv
