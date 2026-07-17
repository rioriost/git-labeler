VERSION ?= 0.1.4
NOTARY_PROFILE ?= git-labeler-notary
MACOS_SIGNED_PKG ?= target/package/macos/git-labeler-$(VERSION)-darwin-arm64-signed.pkg
MACOS_FINAL_PKG ?= target/package/macos/git-labeler-$(VERSION)-darwin-arm64.pkg

.PHONY: build test check package-macos package-macos-signed notarize-macos clean

build:
	swift build

test:
	swift test

check:
	swift test
	sh -n scripts/install-launchagent.sh
	sh -n scripts/uninstall-launchagent.sh
	sh -n scripts/status-launchagent.sh
	sh -n packaging/macos/build-pkg.sh
	sh -n packaging/macos/notarize-pkg.sh

package-macos:
	packaging/macos/build-pkg.sh --version "$(VERSION)"

package-macos-signed:
	@test -n "$(CODESIGN_IDENTITY)" || { echo "Set CODESIGN_IDENTITY" >&2; exit 2; }
	@test -n "$(PKG_SIGN_IDENTITY)" || { echo "Set PKG_SIGN_IDENTITY" >&2; exit 2; }
	packaging/macos/build-pkg.sh --version "$(VERSION)" --sign-identity "$(CODESIGN_IDENTITY)" --pkg-sign-identity "$(PKG_SIGN_IDENTITY)"

notarize-macos:
	packaging/macos/notarize-pkg.sh --pkg "$(MACOS_SIGNED_PKG)" --keychain-profile "$(NOTARY_PROFILE)" --final-pkg "$(MACOS_FINAL_PKG)" --sha256-file target/package/macos/SHA256SUMS.cask

clean:
	rm -rf .build target/package
