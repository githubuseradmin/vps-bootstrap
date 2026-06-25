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

# Extra apt packages to always install (space-separated).
EXTRA_PACKAGES="${EXTRA_PACKAGES:-curl wget git vim htop ca-certificates gnupg}"

# ===========================================================================
# Runtime flags (set by CLI parsing — do not edit)
# ===========================================================================
DRY_RUN=false
ASSUME_YES=false
CONFIG_FILE=""

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

log()  { printf '%b[%s] %s%b\n'  "$C_BLUE"   "$(_ts)" "$*" "$C_RESET"; }
info() { printf '%b[%s] %s%b\n'  "$C_GREEN"  "$(_ts)" "$*" "$C_RESET"; }
warn() { printf '%b[%s] WARN: %s%b\n' "$C_YELLOW" "$(_ts)" "$*" "$C_RESET" >&2; }
err()  { printf '%b[%s] ERROR: %s%b\n' "$C_RED" "$(_ts)" "$*" "$C_RESET" >&2; }

# A bold section banner so the run is easy to scan.
section() {
  printf '\n%b===== %s =====%b\n' "$C_BOLD" "$*" "$C_RESET"
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

    if ! confirm "Apply SSH hardening now?"; then
      warn "Skipping SSH hardening at operator's request."
      return 0
    fi
  fi

  backup_file /etc/ssh/sshd_config

  # Core hardening directives (always safe / recommended).
  set_sshd_option "Protocol" "2"
  set_sshd_option "PubkeyAuthentication" "yes"
  set_sshd_option "ChallengeResponseAuthentication" "no"
  set_sshd_option "X11Forwarding" "no"
  set_sshd_option "MaxAuthTries" "4"
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

$(warn "POST-RUN CHECKLIST — do this BEFORE closing your current session:")
  1. Open a SECOND terminal and log in as the new user:
        ssh -p ${SSH_PORT} ${NEW_USER:-youruser}@<server-ip>
  2. Confirm sudo works:   sudo whoami     (should print 'root')
  3. Confirm the firewall: sudo ufw status verbose
  4. Confirm fail2ban:     sudo fail2ban-client status sshd
  5. Only after all the above succeed, close your original session.

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
  --dry-run            Print every action without changing anything.
  --yes, -y            Assume "yes" to all confirmations (non-interactive).
  --config <file>      Load configuration overrides from <file>.
  --help, -h           Show this help and exit.

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
      --dry-run)      DRY_RUN=true ;;
      --yes|-y)       ASSUME_YES=true ;;
      --config)       CONFIG_FILE="${2:-}"; shift ;;
      --config=*)     CONFIG_FILE="${1#*=}" ;;
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

  printf '%b' "$C_BOLD"
  cat <<'BANNER'
 _   ______  ____    __                __       __
| | / / __ \/ __/   / /  ___  ___ ___ / /________ ___  ___
| |/ / /_/ /\ \    / _ \/ _ \/ _ \(_-</ __/ __/ _ `/ _ \/ _ \
|___/\____/___/   /_.__/\___/\___/___/\__/_/  \_,_/ .__/ .__/
                                                 /_/   /_/
BANNER
  printf '%b' "$C_RESET"

  load_config
  need_root

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

  print_summary
}

main "$@"
