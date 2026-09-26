# DockAI for iOS

The iPhone and Apple Watch app for DockAI, a self-hosted dashboard for
Claude Code workers. It talks only to the DockAI server you pair
it with — scan the QR code in DockAI's Settings → Your devices — and has no
server address of its own. SwiftUI, iOS 17+.

## Build

```bash
./generate.sh && open DockAI.xcodeproj   # installs XcodeGen with Homebrew if missing
```

Set your Team ID and bundle id in `Config.xcconfig` first. The `.xcodeproj`
is generated from `project.yml` and not committed.

## Layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec |
| `Config.xcconfig` | Team ID and bundle id |
| `DockAI/Core` | Keychain, the tRPC client (tRPC + superjson over HTTP), server-sent events, `JSON`, the Live Activity type |
| `DockAI/App` | App entry, app model, root tabs, the project screen's tabs |
| `DockAI/Features/*` | One folder per surface: projects, terminal (SwiftTerm), browser (RFB client), agent runs and automations, services, settings, admin, logs |
| `DockAI/Push` | Push registration, categories and actions |
| `DockAI/Intents` | App Intents and the Live Activity controller |
| `DockAIWidgets` | Usage widget and the run Live Activity |
| `DockAINotifications` | Notification service extension |
| `DockAIWatch` | The Apple Watch app: Needs you (permission requests and questions, answerable), Ask by voice (dictated on the watch, sent to a saved project and conversation, the answer back as a notification), projects, usage. Paired by the iPhone, as its own device |
| `DockAIWatchWidgets` | Watch complications: how many things are waiting, weekly usage, and one that opens Ask |

Server answers are read through a dynamic `JSON` type, so a field the server
adds or renames does not stop a whole screen from decoding.

## Tests

The UI tests walk every screen against a local test server with invented
data — see [CONTRIBUTING.md](CONTRIBUTING.md).

## CI

`.github/workflows/ios.yml`:

- **compile** — every push, unsigned, so compile errors show with no secrets.
- **simulator** — started by hand: the UI tests in the iPhone and watch
  simulators, against the test server or (`live`) the real server as a
  throwaway test user. A run gets a thirty-minute test token by trading
  GitHub's signed identity for it (OIDC) — there is no stored test token. No
  screenshot or log is uploaded here; they go to the DockAI server. A failed
  UI test fails the job.
- **testflight** — started by hand with `testflight=true`, after the
  simulator job passed: signs with an App Store Connect API key and uploads.
  The three `ASC_*` secrets must come from one key (`ASC_KEY_ID` is the id in
  the `.p8`'s file name). The logs are public, so the workflow prints whether
  Apple accepts the key and nothing more.

## Licence

MIT — see [LICENSE](LICENSE). Third-party code: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
(MIT), shown in the app under Settings → About.

Security problems: see [SECURITY.md](SECURITY.md).
