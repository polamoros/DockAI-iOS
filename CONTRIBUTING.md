# Contributing

Thank you for helping. This repository is the iPhone and Apple Watch app of DockAI, a self-hosted
dashboard for Claude Code sessions.

## Building

1. Install Xcode (the newest release) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. `./generate.sh` — generates `DockAI.xcodeproj` from `project.yml` (the project file is not committed).
3. Set your team in `Config.xcconfig` (or `DEVELOPMENT_TEAM=… ./generate.sh`) and a bundle id of your own.
4. Build the `DockAI` scheme. The watch app is embedded in it.

To use the app you need a DockAI server; pair the app from its
**Settings → Your devices**.

## Tests

The UI tests walk every screen against a local test server with invented data:

```sh
node ci/mock-server.mjs &            # 127.0.0.1:8787
xcodebuild test -scheme DockAI -destination 'platform=iOS Simulator,name=iPhone 16'
```

`ci/fixtures.mjs` is generated from the dashboard's design-gate fixtures —
change it there, not here.

## Pull requests

- One change per pull request, with what it fixes or adds and how you checked it.
- Keep the code's own style: SwiftUI, small views, comments that say *why*.
- No personal data, real hostnames, tokens or screenshots of a real server in
  code, tests, commits or issues.
- By contributing you agree your work is licensed under this repository's
  [MIT licence](LICENSE).

Please follow the [code of conduct](CODE_OF_CONDUCT.md).
