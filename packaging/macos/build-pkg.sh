#!/bin/sh
set -eu

export COPYFILE_DISABLE=1

usage() {
  cat <<'USAGE'
Usage:
  build-pkg.sh [options]

Builds a macOS arm64 .pkg for git-labeler.

Options:
  --version VERSION          Default: 0.2.1
  --out-dir PATH             Default: target/package/macos
  --prefix PATH              Default: /opt/homebrew
  --skip-build               Use existing Swift build output
  --sign-identity NAME       Developer ID Application identity for codesign
  --pkg-sign-identity NAME   Developer ID Installer identity for productsign
  -h, --help                 Show this help

Environment alternatives:
  CODESIGN_IDENTITY          Same as --sign-identity
  PKG_SIGN_IDENTITY          Same as --pkg-sign-identity
USAGE
}

version="0.2.1"
out_dir="target/package/macos"
prefix="/opt/homebrew"
skip_build=0
codesign_identity="${CODESIGN_IDENTITY:-}"
pkg_sign_identity="${PKG_SIGN_IDENTITY:-}"

require_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    echo "Missing value for $1" >&2
    exit 2
  fi
  case "$2" in
    --*|-h)
      echo "Missing value for $1" >&2
      exit 2
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      require_value "$@"
      version="$2"
      shift 2
      ;;
    --out-dir)
      require_value "$@"
      out_dir="$2"
      shift 2
      ;;
    --prefix)
      require_value "$@"
      prefix="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --sign-identity)
      require_value "$@"
      codesign_identity="$2"
      shift 2
      ;;
    --pkg-sign-identity)
      require_value "$@"
      pkg_sign_identity="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$version" in
  ''|[!0-9]*|*[!0-9A-Za-z.+_-]*)
    echo "--version must start with a digit and contain only letters, digits, dots, plus signs, underscores, or hyphens" >&2
    exit 2
    ;;
esac

case "$prefix" in
  /*) ;;
  *) echo "--prefix must be absolute" >&2; exit 2 ;;
esac
case "$prefix/" in
  */../*|*/./*)
    echo "--prefix must not contain '.' or '..' path components" >&2
    exit 2
    ;;
esac

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 1
  fi
}

require_command swift
require_command pkgbuild
require_command productbuild
require_command cp

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

case "$(uname -m)" in
  arm64) ;;
  *) echo "macOS package builds are Apple Silicon arm64 only." >&2; exit 1 ;;
esac

if [ "$skip_build" -ne 1 ]; then
  swift build -c release --arch arm64
fi

binary=".build/arm64-apple-macosx/release/git-labeler"
if [ ! -x "$binary" ]; then
  binary=".build/release/git-labeler"
fi
if [ ! -x "$binary" ]; then
  echo "binary not found or not executable: $binary" >&2
  exit 1
fi

mkdir -p "$out_dir"
abs_out_dir=$(CDPATH= cd -- "$out_dir" && pwd -P)
artifact_name="git-labeler-${version}-darwin-arm64.pkg"
if [ -n "$pkg_sign_identity" ]; then
  artifact_name="git-labeler-${version}-darwin-arm64-signed.pkg"
fi

check_publication_targets() {
  for name in "$artifact_name" SHA256SUMS BUILD-METADATA.txt; do
    target="$abs_out_dir/$name"
    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
      echo "Refusing to replace non-regular artifact: $target" >&2
      exit 1
    fi
  done
}

check_publication_targets
work_dir=$(mktemp -d "$abs_out_dir/.git-labeler-pkg.XXXXXX")
payload_dir="$work_dir/payload"
component_pkg="$work_dir/git-labeler-component.pkg"
staged_out_dir="$work_dir/artifacts"
final_pkg="$staged_out_dir/$artifact_name"
metadata_file="$staged_out_dir/BUILD-METADATA.txt"

cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p \
  "$staged_out_dir" \
  "$payload_dir$prefix/bin" \
  "$payload_dir$prefix/share/git-labeler/scripts" \
  "$payload_dir$prefix/share/git-labeler/launchd" \
  "$payload_dir$prefix/share/doc/git-labeler"

install_clean_file() {
  src="$1"
  dst="$2"
  mode="$3"
  cp -X "$src" "$dst"
  chmod "$mode" "$dst"
}

install_clean_file "$binary" "$payload_dir$prefix/bin/git-labeler" 0755
install_clean_file scripts/install-launchagent.sh "$payload_dir$prefix/share/git-labeler/scripts/install-launchagent.sh" 0755
install_clean_file scripts/uninstall-launchagent.sh "$payload_dir$prefix/share/git-labeler/scripts/uninstall-launchagent.sh" 0755
install_clean_file scripts/status-launchagent.sh "$payload_dir$prefix/share/git-labeler/scripts/status-launchagent.sh" 0755
install_clean_file launchd/st.rio.git-labeler.plist "$payload_dir$prefix/share/git-labeler/launchd/st.rio.git-labeler.plist" 0644
install_clean_file README.md "$payload_dir$prefix/share/doc/git-labeler/README.md" 0644
if [ -f LICENSE ]; then
  install_clean_file LICENSE "$payload_dir$prefix/share/doc/git-labeler/LICENSE" 0644
fi

find "$payload_dir" -name '._*' -delete
xattr -cr "$payload_dir" >/dev/null 2>&1 || true

if [ -n "$codesign_identity" ]; then
  codesign --force --timestamp --options runtime --sign "$codesign_identity" "$payload_dir$prefix/bin/git-labeler"
else
  echo "Skipping codesign; pass --sign-identity or set CODESIGN_IDENTITY for distribution builds." >&2
fi

pkgbuild \
  --root "$payload_dir" \
  --identifier st.rio.git-labeler.pkg \
  --version "$version" \
  --install-location / \
  --ownership recommended \
  --filter '/\\._[^/]*$' \
  "$component_pkg"

if [ -n "$pkg_sign_identity" ]; then
  productbuild \
    --package "$component_pkg" \
    --sign "$pkg_sign_identity" \
    "$final_pkg"
else
  productbuild \
    --package "$component_pkg" \
    "$final_pkg"
  echo "Built unsigned package; pass --pkg-sign-identity or set PKG_SIGN_IDENTITY for distribution builds." >&2
fi

cat > "$metadata_file" <<EOF_METADATA
version=$version
prefix=$prefix
artifact=$(basename -- "$final_pkg")
codesigned=$([ -n "$codesign_identity" ] && echo yes || echo no)
pkg_signed=$([ -n "$pkg_sign_identity" ] && echo yes || echo no)
source_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
EOF_METADATA

(
  cd "$staged_out_dir"
  shasum -a 256 "$(basename -- "$final_pkg")" > SHA256SUMS
)

pkgutil --check-signature "$final_pkg" || true

# Generate everything before replacing only this invocation's named files.
check_publication_targets
for name in "$artifact_name" SHA256SUMS BUILD-METADATA.txt; do
  mv -f -h "$staged_out_dir/$name" "$abs_out_dir/$name"
done
final_pkg="$abs_out_dir/$artifact_name"
metadata_file="$abs_out_dir/BUILD-METADATA.txt"
ls -l "$final_pkg" "$metadata_file" "$abs_out_dir/SHA256SUMS"
echo "Built $final_pkg"
