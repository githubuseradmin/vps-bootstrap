#!/usr/bin/env bash
#
# harden-check.sh — read-only hardening audit for a vps-bootstrap'd box
# ---------------------------------------------------------------------------
# A thin, friendly wrapper around `bootstrap.sh --verify`. It inspects the live
# system (SSH config, UFW, fail2ban, swap, automatic updates, sysctl hardening)
# and prints a PASS / WARN / FAIL report. It changes NOTHING, so it is safe to
# run on any server at any time — in cron, in CI, or by hand.
#
# USAGE
#   sudo bash harden-check.sh              # full audit (run as root for SSH/fail2ban checks)
#   bash harden-check.sh                   # works unprivileged too (some checks become WARN)
#   sudo bash harden-check.sh --log audit.log
#
# EXIT CODES (so you can wire it into monitoring / CI)
#   0  all checks passed
#   1  passed but with one or more warnings
#   2  one or more critical checks FAILED
# ---------------------------------------------------------------------------

set -euo pipefail

# Resolve our own directory so the wrapper finds bootstrap.sh next to it,
# regardless of where it is invoked from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BOOTSTRAP="$SCRIPT_DIR/bootstrap.sh"

if [[ ! -f "$BOOTSTRAP" ]]; then
  printf 'harden-check: cannot find bootstrap.sh next to this script (%s)\n' "$SCRIPT_DIR" >&2
  exit 3
fi

# Forward every argument straight through, then force audit mode. Passing
# --verify last guarantees it wins even if the caller did not include it.
exec bash "$BOOTSTRAP" "$@" --verify
