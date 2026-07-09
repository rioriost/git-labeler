#!/bin/sh
set -eu

label="st.rio.git-labeler"
prefix="${HOMEBREW_PREFIX:-/opt/homebrew}"
plist_dir="${HOME}/Library/LaunchAgents"
log_dir="${HOME}/Library/Logs/${label}"
plist_path="${plist_dir}/${label}.plist"
uid="$(id -u)"

mkdir -p "${plist_dir}" "${log_dir}"

cat > "${plist_path}" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${prefix}/bin/git-labeler</string>
    <string>daemon</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${prefix}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>${log_dir}/out.log</string>
  <key>StandardErrorPath</key>
  <string>${log_dir}/err.log</string>
</dict>
</plist>
EOF_PLIST

chmod 0644 "${plist_path}"
launchctl bootout "gui/${uid}" "${plist_path}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/${uid}" "${plist_path}"
launchctl enable "gui/${uid}/${label}"
launchctl kickstart -k "gui/${uid}/${label}"

echo "Installed ${plist_path}"
