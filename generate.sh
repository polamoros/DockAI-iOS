#!/bin/bash
# Generates DockAI.xcodeproj from project.yml — the one step every build
# needs, whether on a Mac, in Codemagic or in Xcode Cloud (the project file is
# not committed). Run from anywhere.
#
#   DEVELOPMENT_TEAM=ABCDE12345 apps/ios/generate.sh
#
# DEVELOPMENT_TEAM, when set, is written into Config.xcconfig so a cloud
# build signs with it; on a Mac you can set it there by hand instead.
set -euo pipefail
cd "$(dirname "$0")"

# CI: a pinned XcodeGen, checked against its checksum, rather than whatever
# Homebrew has today (independent audit 2026-09-26, M3). A Mac uses its own.
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  dir="${RUNNER_TEMP:-/tmp}/xcodegen-$XCODEGEN_VERSION"
  if [ ! -x "$dir/xcodegen/bin/xcodegen" ]; then
    mkdir -p "$dir"
    curl -sfL --proto =https -o "$dir/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
    echo "$XCODEGEN_SHA256  $dir/xcodegen.zip" | shasum -a 256 -c -
    unzip -q "$dir/xcodegen.zip" -d "$dir"
  fi
  export PATH="$dir/xcodegen/bin:$PATH"
fi
command -v xcodegen >/dev/null || brew install xcodegen

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  sed -i '' "s/^DEVELOPMENT_TEAM *=.*/DEVELOPMENT_TEAM = ${DEVELOPMENT_TEAM}/" Config.xcconfig
  echo "[generate] signing team set from DEVELOPMENT_TEAM"
fi

xcodegen generate

# Cloud builds do not resolve packages on their own: they need the lockfile
# inside the generated project. It lives beside project.yml so it survives
# regeneration.
resolved=DockAI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$resolved"
cp Package.resolved "$resolved/Package.resolved"
echo "[generate] DockAI.xcodeproj ready, packages pinned"
