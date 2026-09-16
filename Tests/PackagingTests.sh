#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo_root"
fixture=$(mktemp -d "./Tests/.packaging-tests.XXXXXX")
cleanup() {
  rm -rf -- "$fixture"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)
fixture_repo="$fixture/repo with spaces"
tools="$fixture/tools"
out="$fixture_repo/target/package/macos"
real_shasum=$(command -v shasum)
export real_shasum

fail() {
  echo "FAIL: $*" >&2
  if [ -f "$fixture/run.log" ]; then
    cat "$fixture/run.log" >&2
  fi
  exit 1
}

mkdir -p "$fixture_repo/packaging/macos" "$fixture_repo/.build/release" \
  "$fixture_repo/scripts" "$fixture_repo/launchd" "$tools" "$out/nested"
cp packaging/macos/build-pkg.sh packaging/macos/notarize-pkg.sh "$fixture_repo/packaging/macos/"
printf '#!/bin/sh\nexit 0\n' > "$fixture_repo/.build/release/git-labeler"
chmod +x "$fixture_repo/.build/release/git-labeler"
for file in README.md LICENSE scripts/install-launchagent.sh \
  scripts/uninstall-launchagent.sh scripts/status-launchagent.sh launchd/st.rio.git-labeler.plist; do
  printf 'fixture: %s\n' "$file" > "$fixture_repo/$file"
done

cat > "$tools/tool" <<'STUB'
#!/bin/sh
set -eu
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$PACKAGING_TEST_LOG"
case "$tool" in
  uname) echo arm64 ;;
  git) echo fixture-commit ;;
  pkgbuild|productbuild)
    for output do :; done
    printf '%s: %s\n' "$tool" "$PACKAGING_TEST_BUILD_ID" > "$output"
    ;;
  shasum)
    if [ "${PACKAGING_TEST_FAIL_TOOL:-}" = shasum ]; then
      printf 'partial checksum\n'
      exit 1
    fi
    exec "$real_shasum" "$@"
    ;;
esac
if [ "${PACKAGING_TEST_FAIL_TOOL:-}" = "$tool" ]; then
  echo "Injected $tool failure" >&2
  exit 1
fi
STUB
chmod +x "$tools/tool"
for tool in uname swift pkgbuild productbuild codesign pkgutil xattr git shasum xcrun spctl; do
  ln -s tool "$tools/$tool"
done
PATH="$tools:$PATH"
PACKAGING_TEST_LOG="$fixture/tools.log"
PACKAGING_TEST_BUILD_ID=first
PACKAGING_TEST_FAIL_TOOL=
CODESIGN_IDENTITY=
PKG_SIGN_IDENTITY=
export PATH PACKAGING_TEST_LOG PACKAGING_TEST_BUILD_ID PACKAGING_TEST_FAIL_TOOL \
  CODESIGN_IDENTITY PKG_SIGN_IDENTITY
: > "$PACKAGING_TEST_LOG"

run_build() {
  sh "$fixture_repo/packaging/macos/build-pkg.sh" --skip-build --out-dir "$out" --version 1.2.3 "$@"
}

run_signed_build() {
  run_build --sign-identity "Fixture Application" --pkg-sign-identity "Fixture Installer" "$@"
}

expect_success() {
  "$@" > "$fixture/run.log" 2>&1 || fail "command should succeed: $*"
}

expect_failure() {
  status=0
  "$@" > "$fixture/run.log" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "command should fail: $*"
}

assert_line() {
  grep -Fx -- "$1" "$2" >/dev/null || fail "missing '$1' in $2"
}

assert_clean_staging() {
  for stage in "$out"/.git-labeler-pkg.*; do
    [ ! -e "$stage" ] || fail "staging directory leaked: $stage"
  done
}

snapshot_output() {
  find "$out" -type f -exec "$real_shasum" -a 256 {} + | LC_ALL=C sort
}

assert_preserved() {
  assert_line sentinel "$out/nested/keep.txt"
  assert_line previous-release "$out/git-labeler-1.1.0-darwin-arm64.pkg"
  assert_line previous-signed-release "$out/git-labeler-1.1.0-darwin-arm64-signed.pkg"
  assert_clean_staging
}

assert_unchanged() {
  snapshot_output > "$fixture/current.snapshot"
  cmp -s "$fixture/baseline.snapshot" "$fixture/current.snapshot" || fail "existing output changed"
  assert_preserved
}

unsigned_name=git-labeler-1.2.3-darwin-arm64.pkg
signed_name=git-labeler-1.2.3-darwin-arm64-signed.pkg
printf 'sentinel\n' > "$out/nested/keep.txt"
printf 'previous-release\n' > "$out/git-labeler-1.1.0-darwin-arm64.pkg"
printf 'previous-signed-release\n' > "$out/git-labeler-1.1.0-darwin-arm64-signed.pkg"
printf 'existing-signed\n' > "$out/$signed_name"
printf 'existing-cask-checksum\n' > "$out/SHA256SUMS.cask"

expect_success run_build
assert_line 'productbuild: first' "$out/$unsigned_name"
assert_line existing-signed "$out/$signed_name"
assert_line existing-cask-checksum "$out/SHA256SUMS.cask"
assert_line "artifact=$unsigned_name" "$out/BUILD-METADATA.txt"
assert_line codesigned=no "$out/BUILD-METADATA.txt"
assert_line pkg_signed=no "$out/BUILD-METADATA.txt"
assert_preserved

PACKAGING_TEST_BUILD_ID=second
expect_success run_build
assert_line 'productbuild: second' "$out/$unsigned_name"
assert_line existing-signed "$out/$signed_name"
assert_preserved

PACKAGING_TEST_BUILD_ID=signed
expect_success run_signed_build
assert_line 'productbuild: signed' "$out/$signed_name"
assert_line 'productbuild: second' "$out/$unsigned_name"
assert_line existing-cask-checksum "$out/SHA256SUMS.cask"
assert_line version=1.2.3 "$out/BUILD-METADATA.txt"
assert_line prefix=/opt/homebrew "$out/BUILD-METADATA.txt"
assert_line "artifact=$signed_name" "$out/BUILD-METADATA.txt"
assert_line codesigned=yes "$out/BUILD-METADATA.txt"
assert_line pkg_signed=yes "$out/BUILD-METADATA.txt"
assert_line source_commit=fixture-commit "$out/BUILD-METADATA.txt"
grep -F -- '--sign Fixture Application' "$PACKAGING_TEST_LOG" >/dev/null || fail "codesign not requested"
grep -F -- '--sign Fixture Installer' "$PACKAGING_TEST_LOG" >/dev/null || fail "package signing not requested"
(cd "$out" && "$real_shasum" -a 256 -c SHA256SUMS) > "$fixture/run.log" 2>&1 || fail "invalid checksum"
assert_preserved

# Exercise the same signed-input/final-copy contract as make notarize-macos.
expect_success sh "$fixture_repo/packaging/macos/notarize-pkg.sh" \
  --pkg "$out/$signed_name" --keychain-profile fixture \
  --final-pkg "$out/$unsigned_name" --sha256-file "$out/SHA256SUMS.cask"
cmp -s "$out/$signed_name" "$out/$unsigned_name" || fail "notarized copy differs"
(cd "$out" && "$real_shasum" -a 256 -c SHA256SUMS.cask) > "$fixture/run.log" 2>&1 || fail "invalid cask checksum"
assert_preserved
snapshot_output > "$fixture/baseline.snapshot"

PACKAGING_TEST_BUILD_ID=failed
for tool in codesign pkgbuild productbuild shasum; do
  PACKAGING_TEST_FAIL_TOOL="$tool"
  expect_failure run_signed_build
  assert_unchanged
done
PACKAGING_TEST_FAIL_TOOL=

for name in "$signed_name" SHA256SUMS BUILD-METADATA.txt; do
  for kind in directory file-link directory-link dangling-link; do
    mv "$out/$name" "$fixture/saved-target"
    case "$kind" in
      directory)
        mkdir "$out/$name"
        printf 'keep\n' > "$out/$name/keep"
        ;;
      file-link)
        printf 'external\n' > "$fixture/external-file"
        ln -s "$fixture/external-file" "$out/$name"
        ;;
      directory-link)
        mkdir "$fixture/external-dir"
        printf 'external\n' > "$fixture/external-dir/keep"
        ln -s "$fixture/external-dir" "$out/$name"
        ;;
      dangling-link)
        ln -s "$fixture/not-created" "$out/$name"
        ;;
    esac
    expect_failure run_signed_build
    grep -F 'Refusing to replace non-regular artifact:' "$fixture/run.log" >/dev/null || fail "unsafe target accepted"
    case "$kind" in
      directory)
        assert_line keep "$out/$name/keep"
        rm "$out/$name/keep"
        rmdir "$out/$name" || fail "package was moved inside a directory target"
        ;;
      file-link)
        [ -L "$out/$name" ] || fail "file symlink replaced"
        assert_line external "$fixture/external-file"
        rm "$out/$name" "$fixture/external-file"
        ;;
      directory-link)
        [ -L "$out/$name" ] || fail "directory symlink replaced"
        assert_line external "$fixture/external-dir/keep"
        rm "$out/$name" "$fixture/external-dir/keep"
        rmdir "$fixture/external-dir" || fail "package was moved through a directory symlink"
        ;;
      dangling-link)
        [ -L "$out/$name" ] || fail "dangling symlink replaced"
        [ ! -e "$fixture/not-created" ] || fail "dangling symlink followed"
        rm "$out/$name"
        ;;
    esac
    mv "$fixture/saved-target" "$out/$name"
    assert_unchanged
  done
done

cp "$PACKAGING_TEST_LOG" "$fixture/tools.before-validation"
for prefix in relative /../escape /opt/../escape /./escape; do
  expect_failure run_build --prefix "$prefix"
  [ "$status" -eq 2 ] || fail "unsafe prefix should be a usage error"
  assert_unchanged
done
for version in '' . .. ../escape 1/../../escape '1\..\escape' '1 2' '-1' '1;escape'; do
  expect_failure run_build --out-dir "$fixture/not-created" --version "$version"
  [ "$status" -eq 2 ] || fail "invalid version should be a usage error"
  [ ! -e "$fixture/not-created" ] || fail "invalid version created output"
  assert_unchanged
done
for option in --version --out-dir --prefix --sign-identity --pkg-sign-identity; do
  for kind in absent empty option; do
    case "$kind" in
      absent) expect_failure run_build "$option" ;;
      empty) expect_failure run_build "$option" "" ;;
      option) expect_failure run_build "$option" --skip-build ;;
    esac
    [ "$status" -eq 2 ] || fail "missing value should be a usage error"
    grep -F "Missing value for $option" "$fixture/run.log" >/dev/null || fail "missing value diagnostic"
    assert_unchanged
  done
done
cmp -s "$PACKAGING_TEST_LOG" "$fixture/tools.before-validation" || fail "invalid arguments invoked build tooling"

expect_success sh "$fixture_repo/packaging/macos/build-pkg.sh" --version 2.3.4 --out-dir "$out"
assert_line 'swift build -c release --arch arm64' "$PACKAGING_TEST_LOG"
[ -f "$out/git-labeler-2.3.4-darwin-arm64.pkg" ] || fail "normal build did not publish"
assert_preserved
echo "Packaging regression tests passed."
