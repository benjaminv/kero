# Kero's zsh integration.
#
# Kero starts zsh with ZDOTDIR pointing at this directory so it can add one
# interactive convenience after the user's own startup files have run. Nothing
# else about the shell changes: the user's ZDOTDIR is restored before anything
# is sourced, so .zprofile, .zshrc and .zlogin are read from where they always
# were, in their usual order.
#
# This exists because PATH cannot be used for the job on macOS. /etc/zprofile
# runs `path_helper`, which rebuilds PATH with the system directories first, so
# a directory Kero prepends ends up behind /usr/bin and never shadows anything.

# Restore before sourcing: every later startup file must come from the user's
# directory, not this one. A user who had no ZDOTDIR must end up with none.
if [[ -n "${KERO_ZSH_ZDOTDIR-}" ]]; then
  ZDOTDIR="$KERO_ZSH_ZDOTDIR"
else
  unset ZDOTDIR
fi
unset KERO_ZSH_ZDOTDIR

# The user's own .zshenv may set ZDOTDIR itself; zsh reads the remaining
# startup files from whatever it holds once this file returns.
if [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
  builtin source -- "${ZDOTDIR:-$HOME}/.zshenv"
fi

# Everything below is interactive-only. Scripts, `zsh -c`, and anything an
# agent runs must behave exactly as they do outside Kero.
if [[ -o interactive ]] && [[ -n "${KERO_SSH_HELPER-}" ]]; then
  kero_ssh_integration() {
    emulate -L zsh
    # Runs once, before the first prompt, which is after .zprofile, .zshrc and
    # .zlogin. Defining ssh any earlier would let the user's own files replace
    # it, and defining it in this file would be earlier still.
    precmd_functions=(${precmd_functions:#kero_ssh_integration})
    unfunction kero_ssh_integration 2>/dev/null

    # The user's own ssh always wins.
    (( $+aliases[ssh] || $+functions[ssh] )) && return
    [[ -x "$KERO_SSH_HELPER" ]] || return

    ssh() {
      # Deliberately not `exec`: that would replace this interactive shell and
      # close the terminal when the connection ended. The helper execs the real
      # ssh over itself, so the process id, the terminal and the exit status
      # are the ones ssh would have had anyway.
      "$KERO_SSH_HELPER" "$@"
    }
  }
  precmd_functions+=(kero_ssh_integration)
fi
