# Kero: remote tmux setup check (plan for the builder)

Repo: benjaminv/kero. Work on the branch `feature/remote-tmux-align`. It was cut from origin/main at 5796007 (0.1.48-remote.2) and holds only this plan. Delete this file in the final commit, because the plan doesn't ship.

Status: parked by Ben on 2026-11-08 until the week of 2026-11-16. Before starting, confirm with Ben: (1) the safe Apply list, (2) whether to check only the connected host, (3) the builder machine.

Build on a Mac: MBA, since Kero is a personal repo. Test against `ubuntu@oracle`. Read CLAUDE.md first. New UI must be AppKit, never SwiftUI. Keep the repo's comment style ("why" comments).

## Source of truth
- The canonical files are `~/.claude/skills/align-setup/` on the Mac running Kero, shared by contextman. Kero reads them at runtime and never bundles or copies them into the repo. The app isn't sandboxed (`ENABLE_APP_SANDBOX = NO`), so it can read that folder.
- If `files/` or `scripts/check.sh` is missing, show nothing in the header.
- **check.sh needs its `files/` folder next to it.** It finds the canonical files via `$(dirname "$0")/../files`, so uploading check.sh alone gives every item as MISSING or DIFF. Upload the skill as a tarball of `scripts/check.sh` plus `files/` (about 72 KB). Leave SKILL.md out.

## 1. Check, once per destination
Run the check when a connection first reaches `.connected`. Cache the result per destination for the app's lifetime, and add a "Check again" button in the popover.

Do it in a new file, `kero/RemoteTmuxAlign.swift`, as an `enum` like `RemoteImagePaste`. Run it with `connection.run([RemoteConnection.remoteScript(["sh","-c",script], cwd: nil)], stdin: tarData, timeout: 30)`. That reuses the control socket and its liveness guard, the same path `RemoteImagePaste.upload` uses. The remote script:

```sh
[ "$(id -un)" = dc-ben ] && { echo KERO_SKIP_WORK; exit 0; }
command -v tmux >/dev/null || { echo KERO_NO_TMUX; exit 0; }
d=$(mktemp -d) || exit 1
trap 'rm -rf "$d"' EXIT
tar -xf - -C "$d" || exit 1
bash "$d/scripts/check.sh"
```

- `check.sh` exits 1 whenever something drifted, so treat exit 0 and 1 as success. Treat anything else as an error and show "tmux setup: check failed" with the stderr in the popover.
- If `KERO_NO_TMUX`, show nothing. tmux isn't used there.

**Parsing** (`printf '%-8s %-34s %s'`). Labels contain spaces ("t function", "claude SessionStart hook"), so don't split on whitespace.
- Match `^(OK|DIFF|MISSING|SKIP) +`, then match the rest against the known labels below, longest first. The remaining text is the detail.
- Skip the `host:` line.
- An unknown label is a manual item, so a new check.sh line can never become auto-applied by accident.

| Label in check.sh | Kind |
|---|---|
| `tmux.conf` | safe |
| `t function` | safe |
| `bin/claude-pane-record`, `bin/claude-pane-resume`, `bin/tmux-resurrect-save` | safe |
| `claude SessionStart hook`, `tmux-resurrect plugin`, `resurrect empty-title patch`, `tmux-continuum plugin`, `systemd/*`, `enabled *`, `linger`, `launchd/*`, `loaded *` | manual |

## 2. Header and popover (`RemotePaneHeaderView`)
Add a small line under the cwd subtitle, shown only while connected. Make it a borderless button that opens an `NSPopover` built with AppKit (an `NSViewController` holding an `NSStackView` of rows).
- **Wording:** "tmux setup: aligned", "tmux setup: N items drifted", "tmux setup: checking…" or "tmux setup: check failed".
- **Popover rows:** status, label and detail. Then two groups:
  - **Can fix here** (safe items that aren't OK), with an **Apply** button.
  - **Run align-setup in an agent** (manual items that aren't OK). Show these as text only, with no buttons.
- **State:** keep it in a new `@Published var tmuxAlign: RemoteTmuxAlign.Status?` on `RemoteConnection`. Have the sidebar observe it the same way it already observes `workingDirectory`.
- Match the existing font scaling (`fontScale`). Localize the strings with comments, as the file already does.

## 3. Apply, safe items only
Send one remote script with the same tarball on stdin. Apply only the safe items that weren't OK, and pass their labels as arguments.
- **dc-ben guard:** start with the same `id -un` guard as the check script.
- **Backups:** write `<target>.bak-YYYYMMDD`. If that file already exists, use `.bak-YYYYMMDD-HHMMSS` so an earlier backup is never overwritten (dc-ben already has `.bashrc.bak-20261103`, for example). Skip the backup when the target doesn't exist.
- **tmux.conf:** `cp files/tmux.conf ~/.tmux.conf`. Never touch `~/.tmux.local.conf`. That file is the per-user bar colour, sourced at the end of tmux.conf.
- **t function:** use `~/.zshrc` if `uname` is Darwin, otherwise `~/.bashrc`.
  - If the file has an `^unalias t ` line, replace the lines from `^unalias t ` to `^alias tl=` with `files/t.sh`, keeping everything else.
  - Otherwise append a blank line and `files/t.sh`.
  - Do the replacement with `awk` into a temp file, then `cat` it over the original. That keeps the file's mode and owner, and avoids BSD-vs-GNU `sed -i` differences.
- **bin scripts:** `mkdir -p ~/.local/bin`, copy, then `chmod 755`. contextman ships them as 644.
- **Reload:** if `tmux info >/dev/null 2>&1`, run `tmux source-file ~/.tmux.conf`.
- **Output:** print one line per applied item plus its backup path. Show them in the popover, then rerun the check automatically.
- **Never touch:** the resurrect patch, plugins, systemd or launchd units, linger, or `~/.claude/settings.json`.

## 4. Work account guard (dc-ben)
- **In Swift:** skip the check entirely if `connection.user == "dc-ben"`.
- **On the remote:** the `id -un` guard runs in both scripts. That's the guard that matters, because `connection.user` is empty when the user name comes from `~/.ssh/config` (for example, a Host alias with `User dc-ben`).
- **Result:** on `KERO_SKIP_WORK`, show nothing at all, not even "skipped", and log `kero: tmux align skipped for work account`.
- **Order:** the tarball is only extracted after the guard passes, and it's never written anywhere on dc-ben.

## 5. cwd probe follows the active tmux pane (`RemoteCommands.shellDiscoveryCommand`)
**Today:** the probe finds the sshd-child login shell `$p` and reports `readlink /proc/$p/cwd`. Inside tmux, that's the folder tmux was started from.

**Change:** after the tty check, if the shell's foreground process group belongs to a tmux client, ask tmux for that client's pane:

```sh
fg=$(ps -o tpgid= -p "$p" 2>/dev/null | tr -d ' ');
fc=$(ps -o comm= -p "$fg" 2>/dev/null);
case "$fc" in tmux*)
  r=$(tmux list-clients -F '#{client_tty} #{pane_pid} #{pane_current_path}' 2>/dev/null
      | awk -v t="/dev/$t" '$1==t { sub(/^[^ ]+ /,""); print; exit }');
  [ -n "$r" ] && { printf '%s\n' "$r"; break; };;
esac;
```

Put it before the existing `readlink` line, which stays as the fallback.

**Checked on Oracle (tmux 3.4):**
- The client's `comm` is `tmux: client`.
- `tmux display -p -c /dev/pts/999 …` with a wrong tty **still exits 0 and prints another client's pane**. So don't use `display -c`. Match the tty through `list-clients` as above.

**Details:**
- The output keeps the same `pid path` form, using `#{pane_pid}`, so `parseShellDiscovery` is unchanged. `shellProcessID` then points at the pane's shell, so the Info panel describes what the user is actually in.
- Paths with spaces still work, because the parser splits on the first space only.
- The `LC_KERO_TERMINAL` tag check still runs on `$p` (the sshd child). Keep it where it is.
- Detaching from tmux falls back to the shell's cwd on the next probe.
- Add asserts next to the existing ones at RemoteCommands.swift:623: the command contains `list-clients` and `#{client_tty}`, and doesn't contain `display-message -p -c`.

## 6. Changelog and version
CLAUDE.md says never bump the version in a feature PR. The earlier releases did the bump separately ("Bump to 0.1.48-remote.2"), so:
- **Feature PR:** code only, with this changelog text in the PR description.
- **After merge:** a "Bump to 0.1.48-remote.3" commit sets `MARKETING_VERSION` (2 places in project.pbxproj) and adds:

```
## [0.1.48-remote.3]

- See whether a remote machine's tmux setup matches yours: the remote pane header says "tmux setup: aligned" or how many items drifted, with details, and Apply brings tmux.conf, the t/tl shell commands and the helper scripts in line, keeping a dated backup of each file it replaces
- The Files, Git and Info panels follow the active tmux pane on the remote machine instead of the folder tmux was started from
```

## Test plan (on the Mac, against Oracle)
1. **Build and self-tests:** build Debug and run, so the DEBUG asserts run.
2. **Aligned host:** `ssh ubuntu@oracle`. Oracle is aligned now, so expect "tmux setup: aligned".
3. **Drift and Apply:** on Oracle, as ubuntu, make drift you can undo: `cp ~/.tmux.conf /tmp/tc && echo '# drift' >> ~/.tmux.conf`. Expect "1 item drifted".
   - Apply. Expect `~/.tmux.conf.bak-YYYYMMDD` to be created, then the header to return to "aligned".
   - Check that `~/.tmux.local.conf` is unchanged and the blue ORACLE bar is still there.
   - Remove the backup afterwards.
4. **Work account:** `ssh dc-ben@oracle`, and also through a Host alias with `User dc-ben`. Expect no header line, the skip log line, and no new files in dc-ben's `/tmp` or home.
5. **cwd in tmux:** in an ssh pane run `t kero-test`, then `cd /tmp`. Expect Files to show `/tmp` within one probe interval.
   - Split the window (control+b, release, then |), `cd ~/Documents` in the new pane, and expect Files to follow.
   - Detach (control+b, release, then d) and expect it to fall back.
   - Run `tmux kill-session -t kero-test` at the end. Never touch other sessions.
6. **Drop:** cut the network mid-check. Expect "check failed" and no hang (the 30 s timeout).

Report back: the PR link, the check output from Oracle before and after Apply, and the backup paths created.
