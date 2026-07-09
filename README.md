# git-labeler

`git-labeler` applies macOS Finder tags to direct child git repositories under configured parent directories.

It is designed for Apple Silicon macOS and maps repository status to Finder labels:

- `git:untracked` / green: untracked files exist and no higher-priority state exists
- `git:modified` / yellow: modified, added, renamed, copied, type-changed, or conflicted paths exist
- `git:deleted` / red: deleted paths exist
- clean: managed `git:*` tags are removed

Directories that are not git repository roots are ignored and their Finder tags are not changed.

## Usage

```sh
git-labeler config add ~/Git_Managed
git-labeler config list
git-labeler scan
```

Run as a service:

```sh
brew services start git-labeler
```

If you need the LaunchAgent file to be exactly `st.rio.git-labeler.plist`, use the bundled script instead:

```sh
/opt/homebrew/share/git-labeler/scripts/install-launchagent.sh
```

The config file is stored at:

```text
~/Library/Application Support/st.rio.git-labeler/config.json
```

## Configuration

```json
{
  "version": 1,
  "roots": [
    "/Users/rifujita/Git_Managed"
  ],
  "debounceMilliseconds": 750,
  "rescanIntervalSeconds": 300,
  "gitPath": null,
  "tags": {
    "untracked": "git:untracked",
    "modified": "git:modified",
    "deleted": "git:deleted"
  }
}
```

Multiple roots are supported. The daemon watches each root with FSEvents, debounces changes per repository, and periodically rescans all configured roots.

## Development

```sh
swift test
swift build -c release --arch arm64
```

## macOS Release

Create the notary profile once with an app-specific password:

```sh
xcrun notarytool store-credentials git-labeler-notary \
  --apple-id APPLE_ID \
  --team-id TEAMID \
  --password APP_SPECIFIC_PASSWORD
```

Build a signed package:

```sh
make package-macos-signed \
  CODESIGN_IDENTITY="Developer ID Application: Ryo Fujita (23889H77KX)" \
  PKG_SIGN_IDENTITY="Developer ID Installer: Ryo Fujita (23889H77KX)"
```

Notarize and staple it:

```sh
make notarize-macos NOTARY_PROFILE=git-labeler-notary
```

The cask artifact is:

```text
target/package/macos/git-labeler-0.1.0-darwin-arm64.pkg
```

Update `Casks/git-labeler.rb` with the SHA-256 written to `target/package/macos/SHA256SUMS.cask`.

## License

MIT
