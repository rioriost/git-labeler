#!/bin/sh
set -eu

binary="${1:?usage: sh Tests/CLITests.sh /absolute/path/to/git-labeler}"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/git-labeler-cli.XXXXXX")
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)
daemon_pid=""
cleanup() {
  if [ -n "$daemon_pid" ]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export HOME="$fixture/home"
export CFFIXED_USER_HOME="$HOME"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME" "$fixture/roots/repo"
root="$fixture/roots"
repository="$root/repo"
stdout="$fixture/stdout"
stderr="$fixture/stderr"
config="$HOME/Library/Application Support/st.rio.git-labeler/config.json"

fail() {
  echo "FAIL: $*" >&2
  cat "$stdout" "$stderr" >&2
  exit 1
}

run_ok() {
  "$binary" "$@" >"$stdout" 2>"$stderr" || fail "expected success: $*"
}

run_fails() {
  if "$binary" "$@" >"$stdout" 2>"$stderr"; then
    fail "expected failure: $*"
  fi
  [ -s "$stderr" ] || fail "failure must be reported on stderr: $*"
}

mkdir -p "$(dirname "$config")"
run_ok config path
reported_config=$(cat "$stdout")
[ "$(basename "$reported_config")" = "config.json" ] &&
  [ "$(CDPATH= cd -- "$(dirname "$reported_config")" && pwd -P)" = \
    "$(CDPATH= cd -- "$(dirname "$config")" && pwd -P)" ] || fail "test HOME was not isolated"
cat > "$fixture/git" <<'GIT'
#!/bin/sh
if [ -f "$HOME/fail-rev-parse" ]; then
  echo "simulated repository access failure" >&2
  exit 1
fi
if [ "$3" = status ] && [ -f "$HOME/fail-status" ]; then
  echo "simulated status failure" >&2
  exit 1
fi
exec /usr/bin/git "$@"
GIT
chmod 0755 "$fixture/git"

write_config() {
  cat > "$config" <<CONFIG
{
  "version": 1,
  "roots": ["$1"],
  "debounceMilliseconds": 50,
  "rescanIntervalSeconds": 86400,
  "gitPath": "$fixture/git",
  "tags": {
    "untracked": "git:untracked",
    "modified": "git:modified",
    "deleted": "git:deleted"
  }
}
CONFIG
}

assert_root_retained() {
  [ "$(/usr/bin/plutil -extract roots.0 raw "$config")" = "$root" ] ||
    fail "failed operation removed the configured root"
}

start_daemon() {
  "$binary" daemon >"$fixture/daemon.stdout" 2>"$fixture/daemon.stderr" &
  daemon_pid=$!
  attempt=0
  until grep -q "scanned " "$fixture/daemon.stderr"; do
    kill -0 "$daemon_pid" 2>/dev/null || fail "daemon exited during startup"
    attempt=$((attempt + 1))
    [ "$attempt" -lt 80 ] || fail "daemon did not finish startup"
    sleep 0.1
  done
}

stop_daemon() {
  kill "$daemon_pid"
  wait "$daemon_pid" 2>/dev/null || true
  daemon_pid=""
}

/usr/bin/git -C "$repository" init --quiet
printf 'untracked\n' > "$repository/new.txt"
write_config "$root"
run_ok scan
grep -q "^untracked" "$stdout" || fail "untracked repository was not classified"

write_config "$fixture/missing-root"
/usr/bin/plutil -insert roots.1 -string "$root" "$config"
run_fails scan
grep -q "cannot read root" "$stderr" || fail "missing root error was not reported"
grep -q "^untracked" "$stdout" || fail "scanning stopped before processing another root"
write_config "$root"

touch "$HOME/fail-rev-parse"
run_fails scan
grep -q "simulated repository access failure" "$stderr" || fail "Git failure was hidden"
run_fails config remove "$root" --clear-labels
assert_root_retained
rm "$HOME/fail-rev-parse"

touch "$HOME/fail-status"
run_ok config remove "$root" --clear-labels
if xattr -p com.apple.metadata:_kMDItemUserTags "$repository" >/dev/null 2>&1; then
  fail "managed tags remained after retrying clear"
fi
[ "$(/usr/bin/plutil -extract roots json -o - "$config" | tr -d '[:space:]')" = "[]" ] ||
  fail "successful clear did not remove the root"
rm "$HOME/fail-status"

write_config "$root"
start_daemon
run_fails config remove "$root" --clear-labels
grep -q "stop the LaunchAgent" "$stderr" || fail "active daemon was not reported"
assert_root_retained
run_fails daemon
stop_daemon
run_ok config remove "$root" --clear-labels
if xattr -p com.apple.metadata:_kMDItemUserTags "$repository" >/dev/null 2>&1; then
  fail "managed tags remained after stopping the daemon"
fi

inner="$root/group"
mkdir -p "$inner/repo"
/usr/bin/git -C "$inner/repo" init --quiet
write_config "$root"
run_ok config add "$inner"
start_daemon
attempt=0
until grep -q '/group:' "$fixture/daemon.stderr"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 80 ] || fail "nested root was not scanned at startup"
  sleep 0.1
done
printf 'event-driven\n' > "$inner/repo/new.txt"
attempt=0
until xattr -p com.apple.metadata:_kMDItemUserTags "$inner/repo" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 80 ] || fail "nested repository did not receive filesystem events"
  sleep 0.1
done
stop_daemon

write_config "$root"
/usr/bin/plutil -replace rescanIntervalSeconds -integer 0 "$config"
run_fails daemon
grep -q rescanIntervalSeconds "$stderr" || fail "invalid interval was not rejected"
write_config "$root"
/usr/bin/plutil -replace version -integer 999 "$config"
run_fails scan
grep -q version "$stderr" || fail "unsupported config version was not rejected"

echo "CLI regression tests passed"
