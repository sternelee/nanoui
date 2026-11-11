# noop

A notch that answers GitHub for you. When a pull request, issue or comment
arrives that wants your attention, noop shows it in the notch; tapping it
starts an agent (Claude Code or Codex) in the repository it belongs to, and
the card turns into the agent's progress, then its answer.

In the manner of [noop](https://github.com/sternelee/www/github/noop),
written in Zig against [nanoui](../../README.md): native UI, no webview, no
poller that wakes an idle app for nothing.

## What it does

- Polls `gh api notifications` (the `gh` CLI's own login, no token is stored
  by noop). Signed out is said in one line, with the command to fix it.
- Binds a GitHub repository to a folder. The agent runs in that folder, so
  `AGENTS.md`, the tests and the repository's own tools apply.
- Shows only what needs a person: unread, not yet handled, and still
  waiting/running/needs_decision. Everything else stays out of the notch.
- Each run reports back as the last fenced ```json block: `done`,
  `needs_decision` or `failed`. A decision becomes two buttons; the
  recommended one comes first, lettered by noop rather than by the agent.
- Settings: repositories and their folders, agent (claude/codex), model,
  poll interval, and where the notch sits.

## Running it

```sh
cd apps/noop
zig build run
```

`gh` must be installed and signed in (`gh auth login`). The binary is
`apps/noop/zig-out/bin/noop`.

Headless, for checks without a window (see the repo's rules on never
showing windows while working): noop is an ordinary nanoui app, so the
`--nanoui-*` flags of `src/dev.zig` apply (`snapshot`, `script`, `wait`,
`hidden`). The exact spellings are that file's to keep.

## Tests

```sh
cd apps/noop
zig build test
```

The tests cover what noop decides without a screen: what GitHub said, what
an agent's answer says, what a run turns into, and what the agent is told.

## Layout

```
src/main.zig          the app: the notch window, the settings window
src/app_state.zig     what the app knows and does: look, click, run, answer
src/ingest.zig        polling GitHub and turning it into items
src/gh.zig            the gh CLI: argv, what it said, details and comments
src/agent.zig         starting claude/codex, its argv, its process, its end
src/prompt.zig        what the agent is told, and what its answer means
src/store.zig         what survives a restart (kv), capped at 40 items
src/types.zig         Item, Workspace, Run, Decision, Result, Settings
src/view.zig          the notch card drawing
src/settings_view.zig the settings window
src/cmd.zig           one child process: stdin, stdout, a callback per line
src/tests.zig         the tests
```
