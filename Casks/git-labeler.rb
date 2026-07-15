cask "git-labeler" do
  version "0.1.3"
  sha256 "44541ca13c34418dce633ad72306953cc48dc416a2d8b5be05679f3c5204e09c"

  url "https://github.com/rioriost/git-labeler/releases/download/v#{version}/git-labeler-#{version}-darwin-arm64.pkg"
  name "git-labeler"
  desc "Apply Finder tags to git repositories based on git status"
  homepage "https://github.com/rioriost/git-labeler"

  depends_on arch: :arm64
  depends_on macos: :ventura

  pkg "git-labeler-#{version}-darwin-arm64.pkg"

  uninstall launchctl: "st.rio.git-labeler",
            pkgutil:   "st.rio.git-labeler.pkg",
            delete:    [
              "/opt/homebrew/bin/git-labeler",
              "/opt/homebrew/share/doc/git-labeler",
              "/opt/homebrew/share/git-labeler",
            ]

  caveats <<~EOS
    Configure one or more parent directories:
      git-labeler config add ~/Git_Managed

    Install and start the LaunchAgent:
      /opt/homebrew/share/git-labeler/scripts/install-launchagent.sh
  EOS
end
