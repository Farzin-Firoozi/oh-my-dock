# Agent instructions

Applies to every agent and model working in this repo (Claude, Cursor, Antigravity, and others).

## Commits

- **Never add `Co-Authored-By` trailers** (or any agent/AI attribution) to commit messages or PR descriptions.
- One commit per finished piece of work, in Conventional Commits style (`feat:`, `fix:`, `docs:`, `build:`, `ci:`, `chore:`, `test:`).
- Don't commit or push unless asked.

## Safety

- Never modify the live Dock (`~/Library/Preferences/com.apple.dock.plist` / the `com.apple.dock` domain), and never run `killall Dock`, unless the task explicitly allows it.
- dockutil mutations in tests and spikes always use `--no-restart` plus an explicit temp plist **file** path (see `docs/spikes/0.4-dockutil-temp-plist.md`).

## Docs

See `docs/README.md`. The plan lives in `docs/implementation-plan.md` and `docs/execution-plan.md`.
