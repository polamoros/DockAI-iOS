# Security

**Please do not report security problems in public issues.**

Use GitHub's private vulnerability reporting: **Security → Report a
vulnerability** on this repository. You will get an answer within a week.

## Scope

- The DockAI iPhone and Apple Watch apps in this repository.
- Their CI workflow (`.github/workflows/ios.yml`) and test harness (`ci/`).
- How the apps talk to a DockAI server: pairing, device tokens, push
  notifications and their actions.

The server itself lives in DockAI's main repository.

## How the apps hold your access

- A paired device holds one token, issued by a signed-in session, in the
  device's Keychain (this device only, not synced). Revoke it any time under
  **Settings → Your devices** on the web dashboard.
- Pairing links and QR codes are single-use and expire in ten minutes.
- The app only talks to a server over https.

## The CI

- There are no long-lived test credentials. A simulator run trades GitHub's
  signed identity for that run (OIDC) for a thirty-minute token, issued only
  to this workflow on `main`, started by hand by the owner, and limited to a
  throwaway test project.
- No screenshot or log of a test run is uploaded to this repository.
