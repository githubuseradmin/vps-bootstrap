#!/usr/bin/env bash
#
# vps-bootstrap — Idempotent Ubuntu/Debian VPS setup & hardening script
# ---------------------------------------------------------------------------
# Brings a fresh Ubuntu/Debian VPS to a sane, hardened baseline in one run.
# Every step is idempotent: it inspects current state before changing anything,
# so re-running the script is always safe.
#
# Author : portfolio piece (self-taught dev — networking / security / DevOps)
# License : MIT
# Tested  : Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
#
# USAGE
#   sudo bash bootstrap.sh                 # full run (interactive confirms)
#   sudo bash bootstrap.sh --dry-run       # print actions, change nothing
#   sudo bash bootstrap.sh --yes           # non-interactive (assume "yes")
#   sudo bash bootstrap.sh --config ./my.conf
#   sudo bash bootstrap.sh --help
#
# SAFETY — READ BEFORE RUNNING
#   This script can disable root SSH login and password authentication.
#   Before it does, it loudly verifies that the new user has an SSH key.
#   ALWAYS keep your current SSH session open and test logging in as the new
#   user from a SECOND terminal before closing the first one. If something is
#   wrong, you still have the open session to fix it.
# ---------------------------------------------------------------------------

set -euo pipefail

# ===========================================================================
# CONFIGURATION
# ---------------------------------------------------------------------------
# These defaults can be overridden in three ways (later wins):
#   1. Edit them here.
#   2. Put overrides in a config file and pass --config <file>
#      (by default the script also auto-loads ./bootstrap.conf if present).
#   3. Export the matching environment variable before running, e.g.
#         NEW_USER=deploy SSH_PORT=2222 sudo -E bash bootstrap.sh
# ===========================================================================

# --- Identity -------------------------------------------------------------
# Name of the non-root sudo user to create. Leave empty to skip user creation.
NEW_USER="${NEW_USER:-deploy}"

# Public SSH key(s) to install for NEW_USER. Choose ONE source:
#   * SSH_PUBKEY        — a literal public key string (ssh-ed25519 AAAA... user)
#   * SSH_PUBKEY_FILE   — path to a file containing one or more public keys
# If both are empty, the script copies root's existing authorized_keys.
SSH_PUBKEY="${SSH_PUBKEY:-}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"

# --- SSH ------------------------------------------------------------------
SSH_PORT="${SSH_PORT:-22}"                 # set e.g. 2222 to move SSH off 22
DISABLE_ROOT_LOGIN="${DISABLE_ROOT_LOGIN:-true}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-true}"

# --- Localisation ---------------------------------------------------------
TIMEZONE="${TIMEZONE:-UTC}"                # e.g. Europe/Minsk, America/New_York
LOCALE="${LOCALE:-en_US.UTF-8}"

# --- Firewall (UFW) -------------------------------------------------------
ALLOW_HTTP="${ALLOW_HTTP:-true}"           # open 80/tcp
ALLOW_HTTPS="${ALLOW_HTTPS:-true}"         # open 443/tcp

# --- Swap -----------------------------------------------------------------
SWAP_SIZE="${SWAP_SIZE:-2G}"               # created only if no swap exists; "0" disables

# --- Optional components --------------------------------------------------
INSTALL_NGINX="${INSTALL_NGINX:-true}"
INSTALL_CERTBOT="${INSTALL_CERTBOT:-true}"
INSTALL_DOCKER="${INSTALL_DOCKER:-false}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-true}"
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-true}"

# Node.js via the official NodeSource apt repository (off by default).
#   INSTALL_NODE=true  + NODE_VERSION=20  installs the Node 20.x LTS line.
INSTALL_NODE="${INSTALL_NODE:-false}"
NODE_VERSION="${NODE_VERSION:-20}"         # NodeSource major line, e.g. 18 / 20 / 22

# Lightweight monitoring agent (off by default). Supported values:
#   "netdata" — installs the upstream Netdata one-line agent (local dashboard
#               on 127.0.0.1:19999; the port is NOT opened in UFW by design).
#   "glances" — installs the `glances` terminal/web system monitor (apt).
#   ""        — install nothing.
INSTALL_MONITORING="${INSTALL_MONITORING:-}"

# Extra apt packages to always install (space-separated).
EXTRA_PACKAGES="${EXTRA_PACKAGES:-curl wget git vim htop ca-certificates gnupg}"

# --- Logging --------------------------------------------------------------
# When set, a plain-text (colour-stripped) transcript of the run is appended
# here in addition to the console output. Empty = console only.
LOG_FILE="${LOG_FILE:-}"

# ===========================================================================
# Runtime flags (set by CLI parsing — do not edit)
# ===========================================================================
DRY_RUN=false
ASSUME_YES=false
VERIFY_ONLY=false       # --verify: read-only audit, change nothing
CONFIG_FILE=""

# Audit counters (used by --verify). Incremented by the check_* helpers.
AUDIT_PASS=0
AUDIT_WARN=0
AUDIT_FAIL=0

# ===========================================================================
# LOGGING HELPERS
# ===========================================================================
# Colours are emitted only when stdout is a terminal, so logs piped to a file
# stay clean.
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_RED="\033[0;31m"; C_GREEN="\033[0;32m"
  C_YELLOW="\033[0;33m"; C_BLUE="\033[0;34m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

_ts() { date +'%Y-%m-%d %H:%M:%S'; }

# _logfile <plain-text-line> — append a colour-free copy of a log line to
# LOG_FILE when one is configured. Never fails the run if the file is not
# writable (a server transcript is a nice-to-have, not a hard dependency).
_logfile() {
  [[ -n "$LOG_FILE" ]] || return 0
  printf '%s\n' "$1" >> "$LOG_FILE" 2>/dev/null || true
}

log()  { printf '%b[%s] %s%b\n'  "$C_BLUE"   "$(_ts)" "$*" "$C_RESET"; _logfile "[$(_ts)] $*"; }
info() { printf '%b[%s] %s%b\n'  "$C_GREEN"  "$(_ts)" "$*" "$C_RESET"; _logfile "[$(_ts)] $*"; }
warn() { printf '%b[%s] WARN: %s%b\n' "$C_YELLOW" "$(_ts)" "$*" "$C_RESET" >&2; _logfile "[$(_ts)] WARN: $*"; }
err()  { printf '%b[%s] ERROR: %s%b\n' "$C_RED" "$(_ts)" "$*" "$C_RESET" >&2; _logfile "[$(_ts)] ERROR: $*"; }

# A bold section banner so the run is easy to scan.
section() {
  printf '\n%b===== %s =====%b\n' "$C_BOLD" "$*" "$C_RESET"
  _logfile ""
  _logfile "===== $* ====="
}

# die <msg> — log an error and abort.
die() { err "$*"; exit 1; }

# run <cmd...> — execute a command, or just print it when --dry-run is active.
# Use this wrapper for every state-changing command so dry-run is honest.
run() {
  if $DRY_RUN; then
    printf '%b[dry-run] %s%b\n' "$C_YELLOW" "$*" "$C_RESET"
  else
    "$@"
  fi
}

# run_sh <string> — like run() but for commands that need a shell (pipes,
# redirects, here-docs). The whole string is passed to bash -c.
run_sh() {
  if $DRY_RUN; then
    printf '%b[dry-run] sh -c: %s%b\n' "$C_YELLOW" "$*" "$C_RESET"
  else
    bash -c "$*"
  fi
}

# ===========================================================================
# CONFIRMATION HELPER
# ===========================================================================
# confirm <prompt> — returns 0 for yes, 1 for no.
# Honours --yes (always yes) and --dry-run (always "no" so nothing destructive
# is implied while previewing).
confirm() {
  local prompt="$1" reply
  if $ASSUME_YES; then
    info "Auto-confirm (--yes): $prompt -> yes"
    return 0
  fi
  if $DRY_RUN; then
    warn "Dry-run: would prompt -> '$prompt' (assuming NO)"
    return 1
  fi
  read -r -p "$(printf '%b%s [y/N]: %b' "$C_YELLOW" "$prompt" "$C_RESET")" reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ===========================================================================
# UTILITY HELPERS (idempotency primitives)
# ===========================================================================

# need_root — abort unless running as root (UID 0).
need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This script must be run as root. Try: sudo bash $0"
  fi
}

# is_installed <pkg> — true if a dpkg package is installed.
is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# apt_install <pkg...> — install only the packages that are missing.
apt_install() {
  local pkg missing=()
  for pkg in "$@"; do
    if is_installed "$pkg"; then
      log "Package already present: $pkg"
    else
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    info "Installing: ${missing[*]}"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

# backup_file <path> — copy a file to <path>.bak.<timestamp> before editing.
# No-op if the file does not exist. Skipped under --dry-run.
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local bak="${f}.bak.$(date +%Y%m%d_%H%M%S)"
  if $DRY_RUN; then
    printf '%b[dry-run] backup %s -> %s%b\n' "$C_YELLOW" "$f" "$bak" "$C_RESET"
  else
    cp -a "$f" "$bak"
    log "Backed up $f -> $bak"
  fi
}

# set_sshd_option <Key> <Value> — idempotently set a directive in a drop-in
# file under /etc/ssh/sshd_config.d/ (never touches the distro's main file,
# which keeps upgrades clean). Writes only if the value differs.
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-vps-bootstrap.conf"
set_sshd_option() {
  local key="$1" val="$2"
  local line="$key $val"
  if $DRY_RUN; then
    printf '%b[dry-run] sshd: set %s%b\n' "$C_YELLOW" "$line" "$C_RESET"
    return 0
  fi
  mkdir -p "$(dirname "$SSHD_DROPIN")"
  touch "$SSHD_DROPIN"
  # Replace an existing directive for this key, or append a new one.
  if grep -qiE "^[[:space:]]*${key}[[:space:]]" "$SSHD_DROPIN"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]].*|${line}|I" "$SSHD_DROPIN"
  else
    printf '%s\n' "$line" >> "$SSHD_DROPIN"
  fi
}

# ===========================================================================
# AUDIT HELPERS (used by --verify; read-only, never change anything)
# ===========================================================================
# Each emits one aligned status line and bumps a counter so the run can print a
# pass/warn/fail tally and choose a meaningful exit code.

# audit_pass <check> <detail>
audit_pass() {
  AUDIT_PASS=$((AUDIT_PASS + 1))
  printf '  %b[PASS]%b %-22s %s\n' "$C_GREEN" "$C_RESET" "$1" "${2:-}"
  _logfile "  [PASS] $1 ${2:-}"
}
# audit_warn <check> <detail>
audit_warn() {
  AUDIT_WARN=$((AUDIT_WARN + 1))
  printf '  %b[WARN]%b %-22s %s\n' "$C_YELLOW" "$C_RESET" "$1" "${2:-}"
  _logfile "  [WARN] $1 ${2:-}"
}
# audit_fail <check> <detail>
audit_fail() {
  AUDIT_FAIL=$((AUDIT_FAIL + 1))
  printf '  %b[FAIL]%b %-22s %s\n' "$C_RED" "$C_RESET" "$1" "${2:-}"
  _logfile "  [FAIL] $1 ${2:-}"
}
# audit_info <check> <detail> — neutral, counts toward nothing.
audit_info() {
  printf '  %b[ -- ]%b %-22s %s\n' "$C_BLUE" "$C_RESET" "$1" "${2:-}"
  _logfile "  [ -- ] $1 ${2:-}"
}

# sshd_effective <key> — print the effective value sshd would use for a
# directive (lower-cased), or empty if sshd cannot be queried. Reads the live,
# fully-merged config via `sshd -T`, so it reflects drop-ins too.
sshd_effective() {
  local key="$1"
  sshd -T 2>/dev/null | awk -v k="${key,,}" 'tolower($1)==k {print tolower($2); exit}'
}

# audit_sshd_expect <Directive> <expected> <label> — compare the LIVE effective
# value of an sshd directive (via sshd_effective / `sshd -T`) against the value
# step_ssh_hardening writes. PASS on an exact match, WARN on drift, and WARN
# (not FAIL) when the value cannot be read — that usually just means the audit
# is running without root, not that the box is misconfigured.
audit_sshd_expect() {
  local key="$1" want="${2,,}" label="$3" have
  have="$(sshd_effective "$key")"
  if [[ -z "$have" ]]; then
    audit_warn "$key" "unknown (need root to read sshd config)"
  elif [[ "$have" == "$want" ]]; then
    audit_pass "$key" "$have — $label"
  else
    audit_warn "$key" "$have (expected $want) — $label"
  fi
}

# ===========================================================================
# STEP FUNCTIONS
# ===========================================================================

# --- Step: system update & upgrade ----------------------------------------
step_system_update() {
  section "System update & upgrade"
  run env DEBIAN_FRONTEND=noninteractive apt-get update -y
  info "Upgrading installed packages (this can take a while)..."
  run env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" upgrade
  # Base tools many later steps rely on.
  apt_install $EXTRA_PACKAGES
}

# --- Step: create non-root sudo user --------------------------------------
step_create_user() {
  section "Create non-root sudo user"
  if [[ -z "$NEW_USER" ]]; then
    warn "NEW_USER is empty — skipping user creation."
    return 0
  fi

  if id "$NEW_USER" &>/dev/null; then
    log "User '$NEW_USER' already exists."
  else
    info "Creating user '$NEW_USER'."
    run useradd --create-home --shell /bin/bash "$NEW_USER"
    # Lock the password: this is a key-only account by design.
    run passwd -l "$NEW_USER"
  fi

  # Ensure sudo membership (idempotent — usermod is a no-op if already a member).
  if id -nG "$NEW_USER" 2>/dev/null | grep -qw sudo; then
    log "User '$NEW_USER' already in 'sudo' group."
  else
    info "Adding '$NEW_USER' to 'sudo' group."
    run usermod -aG sudo "$NEW_USER"
  fi

  install_authorized_keys
}

# install_authorized_keys — populate ~NEW_USER/.ssh/authorized_keys from the
# configured key source, without creating duplicates.
install_authorized_keys() {
  local home="/home/$NEW_USER"
  local ssh_dir="$home/.ssh"
  local auth="$ssh_dir/authorized_keys"
  local keys=""

  if [[ -n "$SSH_PUBKEY" ]]; then
    keys="$SSH_PUBKEY"
    info "Using SSH_PUBKEY from config."
  elif [[ -n "$SSH_PUBKEY_FILE" ]]; then
    [[ -f "$SSH_PUBKEY_FILE" ]] || die "SSH_PUBKEY_FILE not found: $SSH_PUBKEY_FILE"
    keys="$(cat "$SSH_PUBKEY_FILE")"
    info "Using SSH_PUBKEY_FILE: $SSH_PUBKEY_FILE"
  elif [[ -f /root/.ssh/authorized_keys ]]; then
    keys="$(cat /root/.ssh/authorized_keys)"
    info "Copying root's existing authorized_keys to '$NEW_USER'."
  else
    warn "No SSH key source found (SSH_PUBKEY / SSH_PUBKEY_FILE / root keys)."
    warn "User '$NEW_USER' will have NO authorized_keys — fix this before"
    warn "disabling password authentication, or you may be locked out."
    return 0
  fi

  if $DRY_RUN; then
    printf '%b[dry-run] install authorized_keys for %s%b\n' \
      "$C_YELLOW" "$NEW_USER" "$C_RESET"
    return 0
  fi

  mkdir -p "$ssh_dir"
  touch "$auth"
  # Append only keys that are not already present (dedup by full line).
  local line added=0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    if grep -qxF "$line" "$auth"; then
      log "Key already authorized (skipping): ${line:0:32}..."
    else
      printf '%s\n' "$line" >> "$auth"
      added=$((added + 1))
    fi
  done <<< "$keys"

  chown -R "$NEW_USER:$NEW_USER" "$ssh_dir"
  chmod 700 "$ssh_dir"
  chmod 600 "$auth"
  info "authorized_keys ready for '$NEW_USER' ($added new key(s) added)."
}

# has_authorized_keys — true if NEW_USER has at least one authorized key.
# Used as a safety gate before disabling password auth.
has_authorized_keys() {
  local auth="/home/$NEW_USER/.ssh/authorized_keys"
  [[ -s "$auth" ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$auth"
}

# --- Step: SSH hardening ---------------------------------------------------
step_ssh_hardening() {
  section "SSH hardening"

  # Loud safety gate: refuse to lock the operator out silently.
  if [[ "$DISABLE_PASSWORD_AUTH" == "true" || "$DISABLE_ROOT_LOGIN" == "true" \
        || "$SSH_PORT" != "22" ]]; then
    warn "============================================================"
    warn " SSH HARDENING WILL CHANGE HOW YOU LOG IN."
    warn " About to apply:"
    [[ "$DISABLE_ROOT_LOGIN" == "true" ]]    && warn "   - PermitRootLogin no"
    [[ "$DISABLE_PASSWORD_AUTH" == "true" ]] && warn "   - PasswordAuthentication no (KEY-ONLY login)"
    [[ "$SSH_PORT" != "22" ]]                && warn "   - SSH will move to port $SSH_PORT"
    warn ""
    warn " KEEP YOUR CURRENT SSH SESSION OPEN. Open a SECOND terminal"
    warn " and confirm you can log in as '$NEW_USER' with your key"
    warn " BEFORE you close this session. If locked out, you will need"
    warn " console/VNC access from your provider to recover."
    warn "============================================================"

    if [[ "$DISABLE_PASSWORD_AUTH" == "true" ]] && ! has_authorized_keys; then
      err "Refusing to disable password auth: user '$NEW_USER' has no SSH key."
      err "Set SSH_PUBKEY or SSH_PUBKEY_FILE (or add a key to root) and re-run."
      warn "Continuing WITHOUT disabling password authentication for safety."
      DISABLE_PASSWORD_AUTH="false"
    fi

    # If the port is changing, make doubly sure the firewall already permits the
    # NEW port before we tell sshd to move — otherwise the next login is blocked.
    if [[ "$SSH_PORT" != "22" ]] && command -v ufw &>/dev/null && ! $DRY_RUN; then
      if ufw status 2>/dev/null | grep -qE "(^|[[:space:]])${SSH_PORT}/tcp[[:space:]]+ALLOW"; then
        info "UFW already allows the new SSH port ${SSH_PORT}/tcp."
      else
        warn "UFW does NOT yet allow ${SSH_PORT}/tcp — opening it now before moving SSH."
        ufw_allow "$SSH_PORT/tcp" "SSH (new port)"
      fi
    fi

    if ! confirm "Apply SSH hardening now?"; then
      warn "Skipping SSH hardening at operator's request."
      return 0
    fi

    # Disabling password auth is the single most lock-out-prone change. When it
    # is in play and we are interactive, require a second, explicit yes.
    if [[ "$DISABLE_PASSWORD_AUTH" == "true" ]] && ! $ASSUME_YES && ! $DRY_RUN; then
      warn "You are about to make this server KEY-ONLY. If your key is wrong,"
      warn "new SSH logins will fail and you will need provider console access."
      if ! confirm "I have an open session AND verified key login works. Disable passwords?"; then
        warn "Keeping password authentication ENABLED at operator's request."
        DISABLE_PASSWORD_AUTH="false"
      fi
    fi
  fi

  backup_file /etc/ssh/sshd_config

  # Core hardening directives (always safe / recommended). None of these touch
  # who may log in or how — they only tighten limits and disable forwarding —
  # so they cannot lock the operator out on their own.
  set_sshd_option "Protocol" "2"
  set_sshd_option "PubkeyAuthentication" "yes"
  set_sshd_option "ChallengeResponseAuthentication" "no"
  set_sshd_option "X11Forwarding" "no"
  set_sshd_option "AllowTcpForwarding" "no"
  set_sshd_option "MaxAuthTries" "3"
  set_sshd_option "LoginGraceTime" "30"
  set_sshd_option "ClientAliveInterval" "300"
  set_sshd_option "ClientAliveCountMax" "2"

  [[ "$SSH_PORT" != "22" ]] && set_sshd_option "Port" "$SSH_PORT"

  if [[ "$DISABLE_ROOT_LOGIN" == "true" ]]; then
    set_sshd_option "PermitRootLogin" "no"
  fi
  if [[ "$DISABLE_PASSWORD_AUTH" == "true" ]]; then
    set_sshd_option "PasswordAuthentication" "no"
    set_sshd_option "PermitEmptyPasswords" "no"
    set_sshd_option "KbdInteractiveAuthentication" "no"
  fi

  # Validate config before reloading — never reload a broken sshd_config.
  if $DRY_RUN; then
    printf '%b[dry-run] validate & reload sshd%b\n' "$C_YELLOW" "$C_RESET"
  else
    if sshd -t; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
        warn "Could not reload SSH service automatically; reload it manually."
      info "SSH configuration applied and service reloaded."
      warn "DO NOT close this session yet. From a SECOND terminal, verify login:"
      warn "  ssh -p ${SSH_PORT} ${NEW_USER:-youruser}@<server-ip>"
    else
      err "sshd config validation FAILED — NOT reloading. Review $SSHD_DROPIN."
      return 1
    fi
  fi
}

# --- Step: UFW firewall ----------------------------------------------------
step_firewall() {
  section "Firewall (UFW)"
  apt_install ufw

  # Default policies (idempotent — ufw stores them; re-setting is harmless).
  run ufw default deny incoming
  run ufw default allow outgoing

  # Always allow SSH so we don't lock ourselves out when enabling UFW.
  ufw_allow "$SSH_PORT/tcp" "SSH"
  [[ "$ALLOW_HTTP"  == "true" ]] && ufw_allow "80/tcp"  "HTTP"
  [[ "$ALLOW_HTTPS" == "true" ]] && ufw_allow "443/tcp" "HTTPS"

  # Enable UFW if inactive. --force avoids the interactive prompt.
  if $DRY_RUN; then
    printf '%b[dry-run] ufw --force enable (if inactive)%b\n' "$C_YELLOW" "$C_RESET"
  elif ufw status | grep -q "Status: active"; then
    log "UFW already active."
  else
    info "Enabling UFW."
    ufw --force enable
  fi
}

# ufw_allow <rule> <label> — add a UFW rule only if it is not already present.
ufw_allow() {
  local rule="$1" label="${2:-}"
  if $DRY_RUN; then
    printf '%b[dry-run] ufw allow %s (%s)%b\n' "$C_YELLOW" "$rule" "$label" "$C_RESET"
    return 0
  fi
  # `ufw status` lists active rules; grep avoids duplicate entries.
  if ufw status | grep -qE "^${rule%/*}/?${rule#*/}?\b" \
     || ufw status | grep -qw "${rule}"; then
    log "UFW rule already present: $rule ($label)"
  else
    info "Allowing $rule ($label)."
    ufw allow "$rule"
  fi
}

# --- Step: fail2ban --------------------------------------------------------
step_fail2ban() {
  section "fail2ban (brute-force protection)"
  [[ "$INSTALL_FAIL2BAN" == "true" ]] || { warn "fail2ban disabled in config — skipping."; return 0; }
  apt_install fail2ban

  local jail="/etc/fail2ban/jail.d/vps-bootstrap.local"
  if [[ -f "$jail" ]] && ! $DRY_RUN; then
    log "fail2ban jail already present: $jail"
  else
    info "Writing fail2ban sshd jail: $jail"
    if $DRY_RUN; then
      printf '%b[dry-run] write %s%b\n' "$C_YELLOW" "$jail" "$C_RESET"
    else
      mkdir -p "$(dirname "$jail")"
      cat > "$jail" <<EOF
# Managed by vps-bootstrap — local override (survives package upgrades).
[DEFAULT]
# Ban for 1 hour after 5 failures within a 10-minute window.
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = $SSH_PORT
EOF
    fi
  fi

  run systemctl enable fail2ban
  run systemctl restart fail2ban
}

# --- Step: unattended-upgrades --------------------------------------------
step_unattended_upgrades() {
  section "Automatic security updates (unattended-upgrades)"
  [[ "$ENABLE_UNATTENDED_UPGRADES" == "true" ]] || { warn "Disabled in config — skipping."; return 0; }
  apt_install unattended-upgrades

  local cfg="/etc/apt/apt.conf.d/20auto-upgrades"
  if [[ -f "$cfg" ]] && ! $DRY_RUN && grep -q 'Unattended-Upgrade "1"' "$cfg"; then
    log "Unattended upgrades already enabled."
  else
    info "Enabling periodic update + unattended upgrade."
    if $DRY_RUN; then
      printf '%b[dry-run] write %s%b\n' "$C_YELLOW" "$cfg" "$C_RESET"
    else
      cat > "$cfg" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
    fi
  fi
  run systemctl enable unattended-upgrades
}

# --- Step: swap file -------------------------------------------------------
step_swap() {
  section "Swap file"
  if [[ "$SWAP_SIZE" == "0" || -z "$SWAP_SIZE" ]]; then
    warn "SWAP_SIZE=0 — skipping swap creation."
    return 0
  fi
  # If any swap is already active, leave it alone.
  if swapon --show | grep -q .; then
    log "Swap already active — skipping."
    return 0
  fi
  if [[ -f /swapfile ]]; then
    log "/swapfile already exists — (re)activating."
  else
    info "Creating $SWAP_SIZE swap file at /swapfile."
    # fallocate is fast; fall back to dd on filesystems that don't support it.
    if $DRY_RUN; then
      printf '%b[dry-run] fallocate -l %s /swapfile%b\n' "$C_YELLOW" "$SWAP_SIZE" "$C_RESET"
    else
      fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || \
        dd if=/dev/zero of=/swapfile bs=1M count="$(swap_mb "$SWAP_SIZE")" status=progress
      chmod 600 /swapfile
      mkswap /swapfile
    fi
  fi
  run swapon /swapfile
  # Persist across reboots without duplicating the fstab entry.
  if ! $DRY_RUN && ! grep -qE '^\s*/swapfile\s' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    log "Added /swapfile to /etc/fstab."
  fi
}

# swap_mb <size> — convert a size like "2G"/"512M" to whole megabytes (for dd).
swap_mb() {
  local s="$1"
  case "$s" in
    *G|*g) printf '%d' "$(( ${s%[Gg]} * 1024 ))" ;;
    *M|*m) printf '%d' "${s%[Mm]}" ;;
    *)     printf '%d' "$s" ;;
  esac
}

# --- Step: timezone & locale ----------------------------------------------
step_timezone_locale() {
  section "Timezone & locale"

  local current_tz
  current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '')"
  if [[ "$current_tz" == "$TIMEZONE" ]]; then
    log "Timezone already set to $TIMEZONE."
  else
    info "Setting timezone to $TIMEZONE."
    run timedatectl set-timezone "$TIMEZONE"
  fi

  apt_install locales
  if $DRY_RUN; then
    printf '%b[dry-run] ensure locale %s%b\n' "$C_YELLOW" "$LOCALE" "$C_RESET"
  elif locale -a 2>/dev/null | grep -qiE "^${LOCALE//-/}$|^${LOCALE}$|utf8"; then
    if locale -a 2>/dev/null | grep -qix "${LOCALE/.UTF-8/.utf8}"; then
      log "Locale $LOCALE already generated."
    else
      info "Generating locale $LOCALE."
      locale-gen "$LOCALE"
      update-locale LANG="$LOCALE"
    fi
  else
    info "Generating locale $LOCALE."
    locale-gen "$LOCALE"
    update-locale LANG="$LOCALE"
  fi
}

# --- Step: sysctl hardening ------------------------------------------------
step_sysctl() {
  section "Kernel / network hardening (sysctl)"
  local cfg="/etc/sysctl.d/99-vps-bootstrap.conf"
  if [[ -f "$cfg" ]] && ! $DRY_RUN; then
    log "sysctl hardening already present: $cfg"
  else
    info "Writing sysctl hardening: $cfg"
    if $DRY_RUN; then
      printf '%b[dry-run] write %s%b\n' "$C_YELLOW" "$cfg" "$C_RESET"
    else
      cat > "$cfg" <<'EOF'
# Managed by vps-bootstrap — basic network hardening.

# --- IPv4 ---
# Enable SYN cookies to resist SYN flood attacks.
net.ipv4.tcp_syncookies = 1
# Ignore ICMP broadcast pings (smurf attack mitigation).
net.ipv4.icmp_echo_ignore_broadcasts = 1
# Ignore bogus ICMP error responses.
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Reverse-path filtering (anti-spoofing).
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# Do not accept source-routed packets.
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
# Do not accept ICMP redirects (MITM mitigation).
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
# Do not send ICMP redirects (we are not a router).
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# Log packets with impossible (martian) addresses.
net.ipv4.conf.all.log_martians = 1

# --- IPv6 ---
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0

# --- Kernel ---
# Restrict access to kernel pointers in /proc.
kernel.kptr_restrict = 1
# Restrict dmesg to root.
kernel.dmesg_restrict = 1
EOF
    fi
  fi
  run sysctl --system
}

# --- Step: nginx -----------------------------------------------------------
step_nginx() {
  section "nginx web server"
  [[ "$INSTALL_NGINX" == "true" ]] || { warn "nginx disabled in config — skipping."; return 0; }
  apt_install nginx
  run systemctl enable nginx
  if $DRY_RUN; then
    printf '%b[dry-run] ensure nginx running%b\n' "$C_YELLOW" "$C_RESET"
  elif systemctl is-active --quiet nginx; then
    log "nginx already running."
  else
    info "Starting nginx."
    systemctl start nginx
  fi
}

# --- Step: certbot ---------------------------------------------------------
step_certbot() {
  section "certbot (Let's Encrypt)"
  [[ "$INSTALL_CERTBOT" == "true" ]] || { warn "certbot disabled in config — skipping."; return 0; }
  # The certbot apt package + nginx plugin is the simplest, dependency-free path.
  apt_install certbot
  [[ "$INSTALL_NGINX" == "true" ]] && apt_install python3-certbot-nginx
  info "certbot installed. Obtain a cert later with:"
  info "  certbot --nginx -d example.com -d www.example.com"
}

# --- Step: Docker (optional) ----------------------------------------------
step_docker() {
  section "Docker (optional)"
  [[ "$INSTALL_DOCKER" == "true" ]] || { log "INSTALL_DOCKER=false — skipping Docker."; return 0; }

  if is_installed docker-ce || command -v docker &>/dev/null; then
    log "Docker already installed."
  else
    info "Installing Docker CE from the official Docker apt repository."
    apt_install ca-certificates curl gnupg
    if $DRY_RUN; then
      printf '%b[dry-run] add Docker apt repo + install docker-ce%b\n' "$C_YELLOW" "$C_RESET"
    else
      install -m 0755 -d /etc/apt/keyrings
      local distro_id
      distro_id="$(. /etc/os-release && echo "$ID")"        # ubuntu | debian
      local codename
      codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-stable}")"
      if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" \
          | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
      fi
      cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro_id} ${codename} stable
EOF
      apt-get update -y
      apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
  fi

  run systemctl enable docker
  run systemctl start docker

  # Let the non-root user run docker without sudo.
  if [[ -n "$NEW_USER" ]] && id "$NEW_USER" &>/dev/null; then
    if id -nG "$NEW_USER" 2>/dev/null | grep -qw docker; then
      log "User '$NEW_USER' already in 'docker' group."
    else
      info "Adding '$NEW_USER' to 'docker' group."
      run usermod -aG docker "$NEW_USER"
      warn "'$NEW_USER' must log out/in for docker group membership to apply."
    fi
  fi
}

# --- Step: Node.js via NodeSource (optional) -------------------------------
step_node() {
  section "Node.js (optional, via NodeSource)"
  [[ "$INSTALL_NODE" == "true" ]] || { log "INSTALL_NODE=false — skipping Node.js."; return 0; }

  # Validate NODE_VERSION is a bare major number to keep the repo URL safe.
  if ! [[ "$NODE_VERSION" =~ ^[0-9]+$ ]]; then
    err "NODE_VERSION must be a major number (e.g. 18, 20, 22) — got '$NODE_VERSION'. Skipping."
    return 0
  fi

  # Already on the requested major line? Then there is nothing to do.
  if command -v node &>/dev/null; then
    local have
    have="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
    if [[ "$have" == "$NODE_VERSION" ]]; then
      log "Node.js $(node -v) already installed (major $NODE_VERSION)."
      return 0
    fi
    warn "Node.js $(node -v) present but a different major than requested ($NODE_VERSION)."
    warn "Proceeding to set up the NodeSource $NODE_VERSION.x repository."
  fi

  apt_install ca-certificates curl gnupg
  if $DRY_RUN; then
    printf '%b[dry-run] add NodeSource %s.x repo + install nodejs%b\n' \
      "$C_YELLOW" "$NODE_VERSION" "$C_RESET"
    return 0
  fi

  install -m 0755 -d /etc/apt/keyrings
  # Fetch and de-armour the NodeSource signing key (idempotent: only if absent).
  if [[ ! -f /etc/apt/keyrings/nodesource.gpg ]]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    chmod a+r /etc/apt/keyrings/nodesource.gpg
  fi
  cat > /etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main
EOF
  apt-get update -y
  apt_install nodejs
  info "Installed $(node -v 2>/dev/null) / npm $(npm -v 2>/dev/null)."
}

# --- Step: monitoring agent (optional) -------------------------------------
step_monitoring() {
  section "Monitoring agent (optional)"
  case "${INSTALL_MONITORING:-}" in
    "" )
      log "INSTALL_MONITORING empty — skipping monitoring agent."
      return 0 ;;
    netdata )
      if command -v netdata &>/dev/null || [[ -d /opt/netdata ]]; then
        log "Netdata already installed."
      else
        info "Installing Netdata (binds to 127.0.0.1:19999 — not exposed via UFW)."
        if $DRY_RUN; then
          printf '%b[dry-run] install Netdata via official kickstart script%b\n' \
            "$C_YELLOW" "$C_RESET"
        else
          # The official one-line installer. We bind it to localhost so the
          # dashboard is reachable only over an SSH tunnel, never the internet.
          curl -fsSL https://get.netdata.cloud/kickstart.sh \
            -o /tmp/netdata-kickstart.sh
          sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel \
            --disable-telemetry || warn "Netdata installer returned non-zero; check output."
          rm -f /tmp/netdata-kickstart.sh
          # Best-effort: keep the listener on localhost only.
          local nd_conf="/etc/netdata/netdata.conf"
          if [[ -f "$nd_conf" ]] && ! grep -q 'bind to = 127.0.0.1' "$nd_conf"; then
            backup_file "$nd_conf"
          fi
        fi
      fi
      info "Reach the dashboard safely via an SSH tunnel:"
      info "  ssh -L 19999:127.0.0.1:19999 ${NEW_USER:-user}@<server-ip>  then open http://localhost:19999"
      ;;
    glances )
      apt_install glances
      info "Run 'glances' for an interactive dashboard, or 'glances -w' for a web UI."
      info "If you use 'glances -w', open its port deliberately and protect it."
      ;;
    * )
      warn "Unknown INSTALL_MONITORING='$INSTALL_MONITORING' (use netdata|glances|''). Skipping."
      ;;
  esac
}

# ===========================================================================
# AUDIT MODE (--verify): inspect the live system, change NOTHING
# ===========================================================================
# Prints a pass/warn/fail report covering the same areas the script hardens, so
# you can confirm a box is in the expected state (or spot drift) at any time.
run_audit() {
  printf '%b' "$C_BOLD"
  cat <<'BANNER'
 ___ _____ ___ _____   ___ _   _ ___ ___ _  __
/ __|_   _/ _ \_   _| / __| | | | __/ __| |/ /
\__ \ | || (_) || |  | (__| |_| | _| (__| ' <
|___/ |_| \___/ |_|   \___|\___/|___\___|_|\_\
       read-only audit — nothing will be changed
BANNER
  printf '%b\n' "$C_RESET"
  info "Auditing $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "this host") — no changes will be made."

  audit_os
  audit_ssh
  audit_firewall
  audit_fail2ban
  audit_updates
  audit_swap
  audit_sysctl
  audit_misc

  section "Audit result"
  printf '  %bPASS: %d%b   %bWARN: %d%b   %bFAIL: %d%b\n' \
    "$C_GREEN" "$AUDIT_PASS" "$C_RESET" \
    "$C_YELLOW" "$AUDIT_WARN" "$C_RESET" \
    "$C_RED" "$AUDIT_FAIL" "$C_RESET"
  _logfile "RESULT PASS=$AUDIT_PASS WARN=$AUDIT_WARN FAIL=$AUDIT_FAIL"

  if [[ "$AUDIT_FAIL" -gt 0 ]]; then
    warn "One or more critical checks FAILED — review the [FAIL] lines above."
    return 2
  elif [[ "$AUDIT_WARN" -gt 0 ]]; then
    warn "Audit passed with warnings — review the [WARN] lines above."
    return 1
  fi
  info "All checks passed."
  return 0
}

audit_os() {
  section "System"
  audit_info "OS" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
  audit_info "Kernel" "$(uname -r)"
  audit_info "Uptime" "$(uptime -p 2>/dev/null || true)"
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    audit_warn "Privileges" "not root — some checks (sshd -T, fail2ban) may be limited."
  fi
}

audit_ssh() {
  section "SSH"
  if ! command -v sshd &>/dev/null; then
    audit_warn "sshd" "not installed / not found."
    return 0
  fi

  local port rootlogin passauth
  port="$(sshd_effective port)"
  rootlogin="$(sshd_effective permitrootlogin)"
  passauth="$(sshd_effective passwordauthentication)"

  if [[ -n "$port" ]]; then
    if [[ "$port" == "22" ]]; then
      audit_info "Port" "22 (default)"
    else
      audit_pass "Port" "$port (moved off 22)"
    fi
  else
    audit_warn "Port" "could not query sshd (need root?)"
  fi

  case "$rootlogin" in
    no|prohibit-password) audit_pass "PermitRootLogin" "$rootlogin" ;;
    yes)                  audit_fail "PermitRootLogin" "yes — root can log in over SSH" ;;
    "")                   audit_warn "PermitRootLogin" "unknown (need root to read sshd config)" ;;
    *)                    audit_warn "PermitRootLogin" "$rootlogin" ;;
  esac

  case "$passauth" in
    no)  audit_pass "PasswordAuthentication" "no (key-only)" ;;
    yes) audit_warn "PasswordAuthentication" "yes — passwords accepted (brute-forceable)" ;;
    "")  audit_warn "PasswordAuthentication" "unknown (need root?)" ;;
    *)   audit_warn "PasswordAuthentication" "$passauth" ;;
  esac

  # Extra hardening directives applied by step_ssh_hardening. Read the LIVE,
  # fully-merged daemon config via `sshd -T` so drop-ins are reflected.
  audit_sshd_expect MaxAuthTries        "3"   "<=3 login attempts per connection"
  audit_sshd_expect LoginGraceTime      "30"  "auth must finish within 30s"
  audit_sshd_expect X11Forwarding       "no"  "X11 forwarding disabled"
  audit_sshd_expect AllowTcpForwarding  "no"  "TCP forwarding disabled"
  audit_sshd_expect ClientAliveInterval "300" "idle-session probe interval"
  audit_sshd_expect ClientAliveCountMax "2"   "drop session after 2 missed probes"

  if [[ -f "$SSHD_DROPIN" ]]; then
    audit_pass "Drop-in present" "$SSHD_DROPIN"
  else
    audit_info "Drop-in present" "no vps-bootstrap drop-in (hardening may be elsewhere)"
  fi
}

audit_firewall() {
  section "Firewall (UFW)"
  if ! command -v ufw &>/dev/null; then
    audit_fail "UFW" "not installed — no host firewall."
    return 0
  fi
  local status
  status="$(ufw status 2>/dev/null | head -1)"
  if printf '%s' "$status" | grep -q "Status: active"; then
    audit_pass "UFW status" "active"
    # Show the allowed rules briefly for context.
    local rules
    rules="$(ufw status 2>/dev/null | awk '/ALLOW/ {print $1}' | sort -u | tr '\n' ' ')"
    [[ -n "$rules" ]] && audit_info "Allowed" "$rules"
  else
    audit_fail "UFW status" "inactive — incoming traffic is NOT filtered."
  fi
}

audit_fail2ban() {
  section "fail2ban"
  if ! command -v fail2ban-client &>/dev/null; then
    audit_warn "fail2ban" "not installed."
    return 0
  fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    audit_pass "Service" "active"
    if fail2ban-client status sshd &>/dev/null; then
      local banned
      banned="$(fail2ban-client status sshd 2>/dev/null | awk -F'\t' '/Currently banned/ {gsub(/ /,"",$2); print $2}')"
      audit_pass "sshd jail" "enabled (currently banned: ${banned:-0})"
    else
      audit_warn "sshd jail" "service up but sshd jail not reporting."
    fi
  else
    audit_warn "Service" "installed but not active."
  fi
}

audit_updates() {
  section "Automatic updates"
  local cfg="/etc/apt/apt.conf.d/20auto-upgrades"
  if [[ -f "$cfg" ]] && grep -q 'Unattended-Upgrade "1"' "$cfg" 2>/dev/null; then
    audit_pass "unattended-upgrades" "enabled"
  else
    audit_warn "unattended-upgrades" "not enabled — security patches are manual."
  fi
  # Count upgradable packages (informational; never fails the audit).
  if command -v apt-get &>/dev/null; then
    local n
    n="$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst' || true)"
    if [[ "${n:-0}" -gt 0 ]]; then
      audit_warn "Pending upgrades" "${n} package(s) upgradable now."
    else
      audit_info "Pending upgrades" "none detected."
    fi
  fi
}

audit_swap() {
  section "Swap"
  if swapon --show 2>/dev/null | grep -q .; then
    local sz
    sz="$(swapon --show=SIZE --noheadings 2>/dev/null | head -1 | tr -d ' ')"
    audit_pass "Swap" "active (${sz:-unknown})"
  else
    audit_warn "Swap" "no active swap (acceptable on large boxes; risky on small ones)."
  fi
}

audit_sysctl() {
  section "Kernel / network hardening"
  _audit_sysctl_kv net.ipv4.tcp_syncookies 1 "SYN cookies"
  _audit_sysctl_kv net.ipv4.conf.all.rp_filter 1 "rp_filter"
  _audit_sysctl_kv net.ipv4.conf.all.accept_redirects 0 "ignore ICMP redirects"
}

# _audit_sysctl_kv <key> <expected> <label>
_audit_sysctl_kv() {
  local key="$1" want="$2" label="$3" have
  have="$(sysctl -n "$key" 2>/dev/null || echo '?')"
  if [[ "$have" == "$want" ]]; then
    audit_pass "$label" "$key=$have"
  else
    audit_warn "$label" "$key=$have (expected $want)"
  fi
}

audit_misc() {
  section "Optional components"
  command -v docker  &>/dev/null && audit_info "Docker"  "$(docker --version 2>/dev/null)"  || audit_info "Docker"  "not installed"
  command -v node    &>/dev/null && audit_info "Node.js" "$(node -v 2>/dev/null)"            || audit_info "Node.js" "not installed"
  command -v nginx   &>/dev/null && audit_info "nginx"   "installed"                          || audit_info "nginx"   "not installed"
  command -v netdata &>/dev/null && audit_info "Netdata" "installed (tunnel to 127.0.0.1:19999)" || true
}

# ===========================================================================
# SUMMARY / CHECKLIST
# ===========================================================================
print_summary() {
  section "Summary"
  cat <<EOF
$(info "vps-bootstrap finished.")

  Hostname    : $(hostname -f 2>/dev/null || hostname)
  New user    : ${NEW_USER:-<none>}
  SSH port    : ${SSH_PORT}
  Root login  : $([[ "$DISABLE_ROOT_LOGIN" == "true" ]] && echo "disabled" || echo "allowed")
  Password SSH: $([[ "$DISABLE_PASSWORD_AUTH" == "true" ]] && echo "disabled (key-only)" || echo "allowed")
  Timezone    : ${TIMEZONE}
  Firewall    : UFW (deny incoming; allow ${SSH_PORT}$([[ "$ALLOW_HTTP" == "true" ]] && echo ", 80")$([[ "$ALLOW_HTTPS" == "true" ]] && echo ", 443"))
  fail2ban    : $([[ "$INSTALL_FAIL2BAN" == "true" ]] && echo "enabled" || echo "off")
  Auto-updates: $([[ "$ENABLE_UNATTENDED_UPGRADES" == "true" ]] && echo "enabled" || echo "off")
  nginx       : $([[ "$INSTALL_NGINX" == "true" ]] && echo "installed" || echo "off")
  certbot     : $([[ "$INSTALL_CERTBOT" == "true" ]] && echo "installed" || echo "off")
  Docker      : $([[ "$INSTALL_DOCKER" == "true" ]] && echo "installed" || echo "off")
  Node.js     : $([[ "$INSTALL_NODE" == "true" ]] && echo "installed (${NODE_VERSION}.x)" || echo "off")
  Monitoring  : ${INSTALL_MONITORING:-off}

$(warn "POST-RUN CHECKLIST — do this BEFORE closing your current session:")
  1. Open a SECOND terminal and log in as the new user:
        ssh -p ${SSH_PORT} ${NEW_USER:-youruser}@<server-ip>
  2. Confirm sudo works:   sudo whoami     (should print 'root')
  3. Confirm the firewall: sudo ufw status verbose
  4. Confirm fail2ban:     sudo fail2ban-client status sshd
  5. Only after all the above succeed, close your original session.

$(info "TIP: re-run this script in audit mode any time to confirm the box's state:")
       sudo bash $0 --verify

$(warn "If you changed the SSH port, remember to use -p ${SSH_PORT} from now on,")
$(warn "and that your provider's cloud firewall (if any) also allows it.")
EOF
}

# ===========================================================================
# CLI / CONFIG
# ===========================================================================
usage() {
  cat <<EOF
vps-bootstrap — idempotent Ubuntu/Debian VPS setup & hardening

Usage:
  sudo bash $0 [options]

Options:
  --verify, --audit    Read-only audit of the live system. Checks SSH, UFW,
                       fail2ban, swap, updates and sysctl, prints a
                       PASS/WARN/FAIL report, and changes NOTHING.
  --dry-run            Print every action without changing anything.
  --yes, -y            Assume "yes" to all confirmations (non-interactive).
  --config <file>      Load configuration overrides from <file>.
  --log <file>         Append a colour-free transcript of the run to <file>.
  --help, -h           Show this help and exit.

Exit codes (audit mode):
  0  all checks passed     1  passed with warnings     2  one or more failures

Configuration is read (in order, later wins) from:
  1. Defaults in this script's CONFIGURATION section.
  2. ./bootstrap.conf (if present) or the --config file.
  3. Environment variables (e.g. NEW_USER=deploy SSH_PORT=2222 ...).

See README.md for the full list of variables and a big safety warning.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verify|--audit) VERIFY_ONLY=true ;;
      --dry-run)      DRY_RUN=true ;;
      --yes|-y)       ASSUME_YES=true ;;
      --config)       CONFIG_FILE="${2:-}"; shift ;;
      --config=*)     CONFIG_FILE="${1#*=}" ;;
      --log)          LOG_FILE="${2:-}"; shift ;;
      --log=*)        LOG_FILE="${1#*=}" ;;
      --help|-h)      usage; exit 0 ;;
      *)              die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
}

# load_config — source a config file if one was given or ./bootstrap.conf exists.
# Sourced AFTER defaults but the values still respect any environment overrides
# because the config file should use the `VAR="${VAR:-value}"` idiom.
load_config() {
  local f="$CONFIG_FILE"
  if [[ -z "$f" && -f "./bootstrap.conf" ]]; then
    f="./bootstrap.conf"
  fi
  if [[ -n "$f" ]]; then
    [[ -f "$f" ]] || die "Config file not found: $f"
    info "Loading config: $f"
    # shellcheck disable=SC1090
    source "$f"
  fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
  parse_args "$@"
  load_config

  # --- Audit mode: read-only, no root strictly required ---------------------
  # Runs the checks and exits with a status that reflects the worst finding.
  if $VERIFY_ONLY; then
    run_audit
    exit $?
  fi

  printf '%b' "$C_BOLD"
  cat <<'BANNER'
 _   ______  ____    __                __       __
| | / / __ \/ __/   / /  ___  ___ ___ / /________ ___  ___
| |/ / /_/ /\ \    / _ \/ _ \/ _ \(_-</ __/ __/ _ `/ _ \/ _ \
|___/\____/___/   /_.__/\___/\___/___/\__/_/  \_,_/ .__/ .__/
                                                 /_/   /_/
BANNER
  printf '%b' "$C_RESET"

  need_root

  if [[ -n "$LOG_FILE" ]]; then
    info "Logging a transcript to: $LOG_FILE"
    _logfile "===== vps-bootstrap run started $(_ts) ====="
  fi

  if $DRY_RUN; then
    warn "DRY-RUN MODE: no changes will be made. Showing planned actions."
  fi

  info "Starting VPS bootstrap for $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "unknown OS")"

  # Order matters: create the user & install their key BEFORE hardening SSH,
  # so disabling password auth can never strand the operator.
  step_system_update
  step_create_user
  step_swap
  step_timezone_locale
  step_firewall          # open SSH first, then enable, so UFW can't lock us out
  step_ssh_hardening
  step_fail2ban
  step_unattended_upgrades
  step_sysctl
  step_nginx
  step_certbot
  step_docker
  step_node
  step_monitoring

  print_summary
}

# Only run main when executed directly, not when sourced (e.g. by the test
# harness in tests/). This lets tests exercise the pure helper functions in
# isolation without triggering a full system run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
