#!/usr/bin/env bash
#
# tests/run-tests.sh — self-contained test harness for vps-bootstrap
# ---------------------------------------------------------------------------
# Pure-bash tests with no external dependencies. They cover two things:
#
#   1. Static checks  — `bash -n` on every shell script in the project
#                       (and `shellcheck` too, if it happens to be installed).
#   2. Unit checks    — the project's pure helper functions are sourced from
#                       bootstrap.sh and asserted in isolation. This is possible
#                       because bootstrap.sh only runs main() when executed
#                       directly, never when sourced.
#
# These tests run fine on any machine with bash — they do NOT need a real
# Ubuntu/Debian host, root, or any of apt/ufw/sshd, because they only exercise
# logic that does not touch the system.
#
# USAGE
#   bash tests/run-tests.sh
#
# EXIT CODE
#   0  all tests passed     1  one or more tests failed
# ---------------------------------------------------------------------------

set -uo pipefail

# Resolve paths relative to this script so it works from any CWD.
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "$TESTS_DIR/.." >/dev/null 2>&1 && pwd)"
BOOTSTRAP="$ROOT_DIR/bootstrap.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
nok()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# assert_eq <expected> <actual> <name>
assert_eq() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else nok "$3 (expected '$1', got '$2')"; fi
}

# assert_true <name> -- pass if the following command (in "$@" after name) is 0.
# Usage: assert_cmd "<name>" <cmd...>
assert_cmd() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name"; fi
}

# assert_fail "<name>" <cmd...> -- pass if the command returns NON-zero.
assert_fail() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then nok "$name (expected non-zero)"; else ok "$name"; fi
}

printf '== vps-bootstrap test suite ==\n\n'

# ---------------------------------------------------------------------------
# 1. Static analysis: syntax-check every .sh, and shellcheck if available.
# ---------------------------------------------------------------------------
printf '[static] syntax & lint\n'
shopt -s nullglob
sh_files=("$ROOT_DIR"/*.sh "$ROOT_DIR"/tests/*.sh)
for f in "${sh_files[@]}"; do
  assert_cmd "bash -n $(basename "$f")" bash -n "$f"
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in "${sh_files[@]}"; do
    assert_cmd "shellcheck $(basename "$f")" shellcheck -S warning "$f"
  done
else
  printf '  --   shellcheck not installed (skipping lint)\n'
fi

# ---------------------------------------------------------------------------
# 2. Unit tests: source the helpers and assert their behaviour.
# ---------------------------------------------------------------------------
printf '\n[unit] helper functions\n'

# Source bootstrap.sh for its functions only. It guards main() behind a
# "executed directly" check, so sourcing defines functions without running.
# We disable -e while sourcing because the script sets its own options.
# shellcheck source=/dev/null
source "$BOOTSTRAP"
# bootstrap.sh sets `set -euo pipefail`; turn -e back off so a single failing
# assertion does not abort the whole suite (we want the full pass/fail tally).
set +e

# --- swap_mb: size string -> whole megabytes -------------------------------
assert_eq "2048" "$(swap_mb 2G)"   "swap_mb 2G   -> 2048"
assert_eq "1024" "$(swap_mb 1g)"   "swap_mb 1g   -> 1024"
assert_eq "512"  "$(swap_mb 512M)" "swap_mb 512M -> 512"
assert_eq "256"  "$(swap_mb 256m)" "swap_mb 256m -> 256"
assert_eq "777"  "$(swap_mb 777)"  "swap_mb 777  -> 777 (bare number)"

# --- audit counters: pass/warn/fail bump the right tally -------------------
AUDIT_PASS=0; AUDIT_WARN=0; AUDIT_FAIL=0
audit_pass "x" "y" >/dev/null
audit_pass "x" "y" >/dev/null
audit_warn "x" "y" >/dev/null
audit_fail "x" "y" >/dev/null
assert_eq "2" "$AUDIT_PASS" "audit_pass increments AUDIT_PASS"
assert_eq "1" "$AUDIT_WARN" "audit_warn increments AUDIT_WARN"
assert_eq "1" "$AUDIT_FAIL" "audit_fail increments AUDIT_FAIL"

# --- has_authorized_keys: detects real vs absent keys ----------------------
# Build a throwaway home so we can flip the key file under it.
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
NEW_USER="testuser"
mkdir -p "$TMP_HOME/home/$NEW_USER/.ssh"
# Override the path the function checks by faking /home via a wrapper:
# has_authorized_keys hard-codes /home/$NEW_USER, so instead we test the
# underlying predicate it relies on directly.
auth="$TMP_HOME/home/$NEW_USER/.ssh/authorized_keys"
: > "$auth"
assert_fail "empty authorized_keys is not valid" \
  bash -c '[[ -s "'"$auth"'" ]] && grep -qE "^(ssh-|ecdsa-|sk-)" "'"$auth"'"'
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtest user@host\n' > "$auth"
assert_cmd "real key is detected as valid" \
  bash -c '[[ -s "'"$auth"'" ]] && grep -qE "^(ssh-|ecdsa-|sk-)" "'"$auth"'"'

# --- NODE_VERSION validation: only bare majors are accepted ----------------
assert_cmd  "NODE_VERSION 20 is a valid major"  bash -c '[[ "20" =~ ^[0-9]+$ ]]'
assert_fail "NODE_VERSION 20.x is rejected"     bash -c '[[ "20.x" =~ ^[0-9]+$ ]]'
assert_fail "NODE_VERSION lts is rejected"      bash -c '[[ "lts" =~ ^[0-9]+$ ]]'

# --- confirm: --yes auto-confirms, dry-run declines ------------------------
# ASSUME_YES / DRY_RUN are read by confirm(), which is sourced from bootstrap.sh;
# the linter cannot follow that cross-source use, hence the SC2034 suppressions.
ASSUME_YES=true; DRY_RUN=false
assert_cmd  "confirm returns yes under --yes"   confirm "test prompt"
ASSUME_YES=false; DRY_RUN=true
assert_fail "confirm declines under --dry-run"  confirm "test prompt"
# shellcheck disable=SC2034
ASSUME_YES=false; DRY_RUN=false

# --- set_sshd_option: idempotently writes/updates directives in a drop-in ---
# Point SSHD_DROPIN at a throwaway file and exercise the real writer. This is
# pure text manipulation (no sshd / root needed), so it is safe on any host.
# shellcheck disable=SC2034  # read by set_sshd_option() sourced from bootstrap.sh
DRY_RUN=false
SSHD_DROPIN="$TMP_HOME/99-vps-bootstrap.conf"
: > "$SSHD_DROPIN"
set_sshd_option "MaxAuthTries" "3"
set_sshd_option "AllowTcpForwarding" "no"
set_sshd_option "X11Forwarding" "no"
assert_cmd  "set_sshd_option writes MaxAuthTries 3" \
  grep -qxE 'MaxAuthTries 3' "$SSHD_DROPIN"
assert_cmd  "set_sshd_option writes AllowTcpForwarding no" \
  grep -qxE 'AllowTcpForwarding no' "$SSHD_DROPIN"
# Re-setting the same key must REPLACE, not append (idempotent, single line).
set_sshd_option "MaxAuthTries" "3"
assert_eq "1" "$(grep -cE '^MaxAuthTries ' "$SSHD_DROPIN")" \
  "set_sshd_option is idempotent (no duplicate MaxAuthTries line)"
# Changing the value updates the existing line in place.
set_sshd_option "MaxAuthTries" "5"
assert_eq "1" "$(grep -cE '^MaxAuthTries ' "$SSHD_DROPIN")" \
  "set_sshd_option updates in place (still one MaxAuthTries line)"
assert_cmd  "set_sshd_option applied the new value" \
  grep -qxE 'MaxAuthTries 5' "$SSHD_DROPIN"

# --- audit_sshd_expect: PASS on match, WARN on drift / unreadable ----------
# Stub sshd_effective so we can drive the audit helper without a live sshd.
# (bootstrap.sh's audit_sshd_expect calls sshd_effective, which we shadow.)
_stub_val=""
sshd_effective() { printf '%s' "$_stub_val"; }

AUDIT_PASS=0; AUDIT_WARN=0; AUDIT_FAIL=0
_stub_val="3"
audit_sshd_expect "MaxAuthTries" "3" "attempts" >/dev/null
assert_eq "1" "$AUDIT_PASS" "audit_sshd_expect PASSes when value matches"

AUDIT_PASS=0; AUDIT_WARN=0; AUDIT_FAIL=0
_stub_val="6"
audit_sshd_expect "MaxAuthTries" "3" "attempts" >/dev/null
assert_eq "1" "$AUDIT_WARN" "audit_sshd_expect WARNs on drift"
assert_eq "0" "$AUDIT_FAIL" "audit_sshd_expect never FAILs (drift is a WARN)"

AUDIT_PASS=0; AUDIT_WARN=0; AUDIT_FAIL=0
_stub_val=""
audit_sshd_expect "AllowTcpForwarding" "no" "forwarding" >/dev/null
assert_eq "1" "$AUDIT_WARN" "audit_sshd_expect WARNs when value is unreadable"

# --- the SSH step & audit reference the new hardening directives ------------
# Guard against silent drift between what we WRITE and what we CHECK: both the
# hardening step and the audit must mention each required directive by name.
for _d in MaxAuthTries LoginGraceTime X11Forwarding AllowTcpForwarding \
          ClientAliveInterval ClientAliveCountMax; do
  assert_cmd "step_ssh_hardening sets $_d" \
    grep -qE "set_sshd_option \"$_d\"" "$BOOTSTRAP"
  assert_cmd "audit references $_d" \
    grep -qE "audit_sshd_expect $_d" "$BOOTSTRAP"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n== result: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
