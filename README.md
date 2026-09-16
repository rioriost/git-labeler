# git-labeler

`git-labeler` applies macOS Finder tags to direct child git repositories under configured parent directories.

It is designed for Apple Silicon macOS and maps repository status to Finder labels:

- `git:untracked` / green: untracked files exist and no higher-priority state exists
- `git:modified` / yellow: modified, added, renamed, copied, type-changed, or conflicted paths exist
- `git:deleted` / red: deleted paths exist
- clean: managed `git:*` tags are removed

Directories that are not git repository roots are ignored and their Finder tags are not changed.

![git-labeler screenshot](images/screenshot.webp)

## Installation

Install from the Homebrew tap:

```sh
brew tap rioriost/cask
brew install --cask git-labeler
```

Configure at least one parent directory:

```sh
git-labeler config add ~/Git_Managed
```

Start the LaunchAgent:

```sh
/opt/homebrew/share/git-labeler/scripts/install-launchagent.sh
```

The package installs an Apple Silicon binary under `/opt/homebrew/bin/git-labeler`.

## Usage

```sh
git-labeler config add ~/Git_Managed
git-labeler config list
git-labeler scan
```

Remove a configured parent directory while keeping existing Finder tags:

```sh
git-labeler config remove ~/Git_Managed
```

To remove a configured parent directory and clear managed labels, stop the LaunchAgent **before** clearing, then restart it:

```sh
/opt/homebrew/share/git-labeler/scripts/uninstall-launchagent.sh
git-labeler config remove ~/Git_Managed --clear-labels
/opt/homebrew/share/git-labeler/scripts/install-launchagent.sh
```

Stop any foreground `git-labeler daemon` process as well. Clearing refuses to run while a daemon or another clearing operation holds the service lock. Daemons read configuration only at startup; stopping first prevents them from restoring labels using the old configuration. Versions before 0.2.1 do not hold this lock and must also be stopped before clearing.

If clearing fails, the root remains configured and the command exits unsuccessfully; resolve the reported error and retry before restarting the service. Clearing checks repository identity but does not require a successful `git status`. Unrelated Finder tags are preserved.

`scan` continues processing other repositories after an error, reports errors on stderr, and exits with a nonzero status if any candidate failed.

Check the LaunchAgent status:

```sh
/opt/homebrew/share/git-labeler/scripts/status-launchagent.sh
```

Restart the LaunchAgent after changing configuration:

```sh
/opt/homebrew/share/git-labeler/scripts/uninstall-launchagent.sh
/opt/homebrew/share/git-labeler/scripts/install-launchagent.sh
```

`git-labeler` is distributed as a notarized Homebrew Cask package, not as a Formula, so it is not managed by `brew services`.

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

Multiple roots, including nested roots, are supported. The daemon watches each root with FSEvents, debounces changes per repository, and periodically rescans all configured roots. Event-driven and periodic scans share one serial queue to prevent older results from overwriting newer labels.

Configuration is validated before use:

- `version` must be `1`.
- `roots` must contain absolute paths. Temporarily unavailable roots are reported during scanning.
- `debounceMilliseconds` must be between `0` and `60000`.
- `rescanIntervalSeconds` must be between `1` and `86400`.
- `gitPath` must be `null` or an absolute path to an executable file.
- Tag names must be distinct, nonempty, and contain no control characters. Choose names reserved for this tool, since matching tags are managed by `git-labeler`.

Repository classification includes untracked files even when Git's `status.showUntrackedFiles` setting hides them, and includes submodule changes even when Git is configured to hide those changes. Each Git command has a 30-second timeout. Git execution failures are reported, not treated as non-repositories.

## Development

```sh
make check
swift build -c release --arch arm64
```

`make check` runs Swift tests, CLI regressions in an isolated home directory, shell syntax checks, and packaging regressions with stub signing tools.

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
  CODESIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
  PKG_SIGN_IDENTITY="Developer ID Installer: YOUR NAME (TEAMID)"
```

Notarize and staple it:

```sh
make notarize-macos NOTARY_PROFILE=git-labeler-notary
```

The cask artifact is:

```text
target/package/macos/git-labeler-0.2.1-darwin-arm64.pkg
```

Update `Casks/git-labeler.rb` with the SHA-256 written to `target/package/macos/SHA256SUMS.cask`.

Package builds preserve unrelated output files and previous releases. Artifacts are generated in a temporary staging directory before replacing only the current package, `SHA256SUMS`, and `BUILD-METADATA.txt`. Artifact targets must be regular files or absent, not symlinks or directories.

## License

MIT
