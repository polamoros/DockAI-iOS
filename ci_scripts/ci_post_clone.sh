#!/bin/bash
# Xcode Cloud runs this after cloning and before it opens the project, which
# is not committed (XcodeGen). It must sit beside the project: apps/ios.
set -euo pipefail
# SwiftTerm ships a build plugin; an unattended build has nobody to trust it.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
"$(dirname "$0")/../generate.sh"
