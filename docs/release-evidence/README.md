# Release evidence

This directory stores privacy-reviewed evidence summaries, not raw captures.

- `agent-apps/` records support-scope checks for remote apps and Mac Screen.
- `mac-app/` records native permission, auth, signing, and relaunch checks.
- `mobile/` is reserved for sanitized hardware-only summaries when a release gate
  explicitly requires them.

Raw screenshots, videos, HTML dumps, logs, transcripts, emails, account identifiers,
and absolute paths must remain under ignored local test output. Before committing a
summary, inspect it for private content and run `pnpm qa:public-repo`.
