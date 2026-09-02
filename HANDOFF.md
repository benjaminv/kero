# Handoff: window-scoped agent profiles

## Status

Exploration only. No implementation has started and no product decision has
been committed beyond the direction recorded here.

## User need

The user has separate personal and work subscriptions for coding-agent CLIs.
They want to choose which account context a Kero window uses without binding an
identity to a project, repository, or workspace path. This is convenience and
mistake prevention for one macOS user, not a security boundary.

Kero's existing **New Window** command does not currently isolate accounts. A
window owns a separate `TerminalManager`, but its shells still run as the same
macOS user with the same agent configuration and credentials.

## Preferred product model

Add a platform-agnostic, window-scoped **Agent Profile** (or simply
**Profile**):

- A new window is opened as Default, Personal, or Work.
- Any project may be opened in any profile; paths do not select or retain an
  identity.
- Every terminal created in the window inherits that profile, including
  terminals created through new projects, tabs, splits, restoration, Finder or
  CLI requests, and automation.
- Commands typed manually inherit the profile as well as agents started by
  Kero's UI.
- The active profile is visibly identified in the window.
- The profile is persisted with the window snapshot.
- Do not replace the shell's complete `HOME`: Git, SSH, dotfiles, and other CLI
  state should remain normal. Apply only agent-specific supported configuration
  roots.
- Login remains controlled by each CLI. Running `/login` in Claude or the
  corresponding Codex login flow changes the credentials inside the selected
  profile's bucket. The profile is not permanently locked to an account.
- Prefer opening a new window to changing the profile of a window that already
  has running terminals. Existing processes cannot safely be migrated to a new
  environment.

Initial integrations discussed:

```text
Personal
  Claude -> CLAUDE_CONFIG_DIR=~/.kero/profiles/personal/claude
  Codex  -> CODEX_HOME=~/.kero/profiles/personal/codex

Work
  Claude -> CLAUDE_CONFIG_DIR=~/.kero/profiles/work/claude
  Codex  -> CODEX_HOME=~/.kero/profiles/work/codex
```

Treat those mappings as adapters so future agents can be added without changing
the window/profile model.

Anthropic explicitly documents `CLAUDE_CONFIG_DIR` as useful for running
multiple accounts side by side and says it relocates settings, credentials,
sessions, and plugins:
<https://code.claude.com/docs/en/env-vars>

Before implementation, re-verify current official Codex documentation and the
installed CLI's behavior for `CODEX_HOME`, including macOS credential storage.

## Relevant implementation areas

- `kero/keroApp.swift`: `WindowGroup`, `WindowRootView`, and the existing **New
  Window** command. Each window constructs its own `TerminalManager`.
- `kero/TerminalManager.swift`: window ownership, all project creation paths,
  multi-window snapshot save/restore, Finder and CLI routing.
- `kero/Project.swift`: currently constructs `TerminalSession` directly from a
  central `makeSession` method; this is the main place that needs a
  window-provided environment overlay or session factory.
- `kero/TerminalSession.swift`: constructs `TerminalLaunch`; its
  `surfaceEnvironment` currently adds terminal/Kero variables and an optional
  PATH but no profile-specific variables.
- `kero/SessionStore.swift`: `SessionSnapshot` is the persisted per-window
  structure and must gain a backwards-compatible optional profile identifier.
- `kero/KeroAutomationRouter.swift`: agent automation acts on existing shells,
  so correctness depends on every shell receiving its window profile at birth.

New UI must follow the repository convention: AppKit, not new or expanded
SwiftUI. The existing SwiftUI app-scene/menu code is legacy.

## Estimated scope

A hard-coded proof of concept is a few hours. A production-ready first version
is approximately 3-5 focused development days:

- Profile model, stable identifiers, directories, and persistence: 0.5-1 day.
- Environment plumbing through every session creation/restoration path: 1 day.
- AppKit window-selection UI and visible indicator: 0.5-1 day.
- Backwards-compatible window snapshot changes: 0.5 day.
- Claude/Codex multi-window login, restoration, CLI, Finder, split, and
  automation verification: about 1 day, with contingency for credential quirks.

A sensible first release is Default/Personal/Work, window selection and
persistence, a clear indicator, and Claude/Codex adapters. Defer arbitrary
profile management and live profile switching.

## Open questions for the next session

1. Should **New Window** open a submenu, show a small AppKit chooser, or reuse
   the last/default profile with alternate commands for Personal and Work?
2. Where should profile metadata live: Kero's TOML settings or a dedicated
   profile store? Secret tokens must remain owned by the agent CLIs.
3. Should multiple windows using the same profile intentionally share agent
   sessions/configuration? The current assumption is yes.
4. Confirm `CODEX_HOME` account isolation on the currently installed Codex CLI
   and confirm both CLIs' macOS Keychain behavior empirically before committing
   to the storage layout.
5. Decide how Finder/`kero` CLI requests choose a target profile when no Kero
   window exists.

## Suggested skills

- `engineering:system-design` for the profile model, ownership boundaries, and
  environment propagation design.
- `openai-docs` to verify current official Codex configuration and
  authentication behavior before implementing the Codex adapter.
- No frontend-design skill is necessary unless the scope expands beyond a
  compact native AppKit chooser and profile indicator.


---

# Addendum: redesign required before the next implementation attempt

Recorded 1 September 2026, from a Debug build of `feature/window-ai-profiles`
(`kero-wt-profiles/build-crew/Build/Products/Debug/Kero Debug.app`), running
Claude Code inside a window set to a named profile. Where this addendum
conflicts with the exploration above, this addendum wins.

## What the build does today

It works as coded. A named profile exports `CLAUDE_CONFIG_DIR`, `CODEX_HOME`
and `KERO_PROFILE` into every terminal, and Claude Code obeys them.

## The problem observed

The window ran a half-configured Claude, not the user's Claude with a different
account. The visible symptom was a missing status line; that was one item of a
much larger loss.

Verified in that window:

- Per-profile and therefore missing: `settings.json` (the profile's file was 22
  bytes, `{"theme":"dark"}`, against a 10 KB user file whose `statusLine` runs
  `~/.claude/statusline-command.sh`), all 25 custom skills in `~/.claude/skills`
  including `crew` and `handoff`, the `hooks/session-end-log.sh` entry,
  `.claude.json` project state, session transcripts (2 in the profile against 11
  for the same repository under `~/.claude`), and project memory (empty against
  5 files plus `MEMORY.md`).
- Still shared: `~/.claude/CLAUDE.md` and `~/.claude/rules/*.md` both loaded, so
  Claude Code 2.1.252 resolves those two at `$HOME/.claude` regardless of
  `CLAUDE_CONFIG_DIR`. The 39 files in `~/.claude/memory` stayed reachable only
  because CLAUDE.md references them by absolute path.

That mixture is the core defect. Rules load while the skills, hooks and status
line they depend on do not, so a profile window is neither the user's
environment nor a clean one.

## Requirement the redesign must satisfy

One configuration, a swappable credential. The current model makes a profile a
whole new configuration root, which keys the user's settings, skills, memory and
history to the identity axis instead of leaving them shared.

## Constraints, both verified

1. The credential slot is derived from the config directory path. The Keychain
   held `Claude Code-credentials` (default root) alongside
   `Claude Code-credentials-322aa235` (the profile root). No `.credentials.json`
   exists on disk on macOS. There is no credentials-only environment variable in
   CLI 2.1.252; `CLAUDE_CONFIG_DIR` is the only knob. So isolation must come from
   a distinct path, and sharing must be rebuilt inside it. The reverse is not
   available.
2. `.claude.json` mixes identity with state: `oauthAccount` (email,
   organisation, account UUID) sits in the same file as project trust, MCP
   enablement and history (43 projects in the real file). It cannot be shared
   wholesale.

## What the current code gets right and should be kept

- The System profile exports nothing, so the default path is untouched
  (`ProfileStore.swift:148-163`).
- Paths key off the immutable profile UUID, not the display name, because a
  respelled path reads as a silent logout (`ProfileStore.swift:150-153`).
- Codex is pinned to its file credential store so named profiles do not collapse
  into one Keychain account (`ProfileStore.swift:186-200`).
- Kero never reads or copies credentials.

The gap is `prepareDirectories` (`ProfileStore.swift:165`): it creates an empty
`claude/` directory and nothing seeds or shares user configuration.

## Direction to evaluate, not yet a decision

Keep the per-profile root, then link the shared state back into it: seed a new
profile's `claude/` with symlinks to `~/.claude/settings.json`,
`settings.local.json`, `skills`, `hooks`, `plugins`, `commands`, `agents`,
`keybindings.json`, `statusline-command.sh`, and `projects` (memory and
transcripts). Leave only identity and per-session state real. `settings.json`
was checked and holds no token or credential key, so it is safe to share.
`.claude.json` should be copied at creation rather than linked, so state starts
identical and the account can diverge.

## What the proof of concept must prove

1. Whether Claude Code's atomic writes (write temporary file, rename over the
   target) replace a symlinked `settings.json` or `.claude.json` with a regular
   file and silently end the sharing. Change a setting inside a profile window,
   then check with `ls -l`. This is the single assumption the whole direction
   rests on.
2. Which files a fresh config root accumulates across real use. Anything the CLI
   adds later defaults to unshared; decide whether that is acceptable or whether
   seeding must be re-run.
3. Keychain slot stability: that the path-hashed entry survives app restart,
   rebuild and profile rename, and that deleting then recreating a profile
   produces a new slot and a required re-login, with the user told.
4. Two windows on two profiles running Claude at once, with no cross-write
   damage to the shared linked files.
5. The Codex half: what `CODEX_HOME` state should be shared against isolated,
   and that the file credential store behaves as assumed on the installed CLI.
6. Whether `CLAUDE.md` and `rules` resolving at `$HOME/.claude` is intended CLI
   behaviour or a quirk of 2.1.252. Sharing must not silently depend on it.

## Working note for the next session

Do not run this redesign from a profile window. That session has no custom
skills, no project memory and no prior transcripts, which is what forced this
addendum to be written by hand. Use a System profile window.
