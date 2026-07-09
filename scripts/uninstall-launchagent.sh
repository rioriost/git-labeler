#!/bin/sh
set -eu

label="st.rio.git-labeler"
plist_path="${HOME}/Library/LaunchAgents/${label}.plist"
uid="$(id -u)"

launchctl bootout "gui/${uid}" "${plist_path}" >/dev/null 2>&1 || true
rm -f "${plist_path}"

echo "Uninstalled ${plist_path}"
