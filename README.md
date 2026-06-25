English | [Русский](README.ru.md)

# vps-bootstrap

> One idempotent Bash script to take a **fresh Ubuntu/Debian VPS** from
> "root password over port 22" to a sane, hardened baseline — a non-root sudo
> user, key-only SSH, a firewall, brute-force protection, automatic security
> updates, swap, kernel hardening, and an optional web/app stack — plus a
> read-only **audit mode** to confirm (or re-check) a box's state any time.

Re-running the script is always safe: **every action checks current state
before changing anything**. No half-applied state, no duplicate firewall rules,
no clobbered config on the second run.

```bash
# See what's planned, change nothing
sudo bash bootstrap.sh --dry-run

# Harden the box
sudo bash bootstrap.sh

# Re-check the box's state any time — read-only, changes nothing
sudo bash bootstrap.sh --verify     # or: sudo bash harden-check.sh
```

---

## Why

Spinning up a new server means doing the same dozen chores every time, and the
security-sensitive ones (SSH hardening, firewall) are exactly the ones you do
*not* want to fat-finger. This script encodes that checklist once, does it
idempotently, and — crucially — **refuses to lock you out silently**. Before it
disables password login it verifies your new user actually has a working SSH
key, and it walks you through testing a second session before you close the
first.

It is plain Bash with **no third-party dependencies** — just the tools already
on a stock Ubuntu/Debian image (`apt`, `ufw`, `systemd`, `sshd`).

---

## What it does

Each step is a self-contained function and is **idempotent**:

| # | Step | What it does | Idempotency check |
|---|------|--------------|-------------------|
| 1 | **System update** | `apt-get update && upgrade`, install base tools | only installs missing packages |
| 2 | **Non-root user** | create `NEW_USER`, add to `sudo`, install SSH key | skips if user / key already exists |
| 3 | **Swap** | create a swap file if the box has none | skips if any swap is active |
| 4 | **Timezone & locale** | set timezone, generate locale | skips if already set |
| 5 | **Firewall (UFW)** | deny incoming, allow SSH / HTTP / HTTPS, enable | adds a rule only if absent |
| 6 | **SSH hardening** | `PermitRootLogin no`, `PasswordAuthentication no`, optional port change, sane limits | writes a drop-in; validates with `sshd -t` before reload |
| 7 | **fail2ban** | install + `sshd` jail (ban after 5 fails) | skips if jail file exists |
| 8 | **Unattended-upgrades** | enable automatic security updates | skips if already enabled |
| 9 | **sysctl hardening** | SYN cookies, rp_filter, ignore ICMP redirects, etc. | skips if drop-in exists |
| 10 | **nginx** *(optional)* | install + enable + start | skips install/start if present/running |
| 11 | **certbot** *(optional)* | install certbot (+ nginx plugin) for Let's Encrypt | only installs missing packages |
| 12 | **Docker** *(optional)* | official Docker CE repo + add user to `docker` group | skips if Docker already installed |
| 13 | **Node.js** *(optional)* | official NodeSource repo, pinned major (`NODE_VERSION`) | skips if the requested major is already installed |
| 14 | **Monitoring** *(optional)* | `netdata` (bound to localhost) or `glances` | skips if already installed |

It finishes with a **summary** and a **post-run checklist**.

---

## Audit mode (`--verify`) — check, don't change

Run a **read-only** health/hardening audit at any time. It inspects the same
areas the script hardens — SSH config, UFW, fail2ban, swap, automatic updates,
sysctl — and prints a `PASS` / `WARN` / `FAIL` report **without changing
anything**. Use it right after a run, on a schedule (cron), or in CI to catch
config drift.

```bash
sudo bash bootstrap.sh --verify        # or the friendly wrapper:
sudo bash harden-check.sh
```

Example output:

```
===== SSH =====
  [PASS] Port                   2222 (moved off 22)
  [PASS] PermitRootLogin        no
  [PASS] PasswordAuthentication no (key-only)
  [PASS] Drop-in present        /etc/ssh/sshd_config.d/99-vps-bootstrap.conf

===== Firewall (UFW) =====
  [PASS] UFW status             active
  [ -- ] Allowed                2222/tcp 443/tcp 80/tcp

===== fail2ban =====
  [PASS] Service                active
  [PASS] sshd jail              enabled (currently banned: 3)

===== Audit result =====
  PASS: 14   WARN: 1   FAIL: 0
```

The exit code reflects the worst finding, so you can wire it into monitoring:

| Exit | Meaning |
|------|---------|
| `0`  | all checks passed |
| `1`  | passed with warnings |
| `2`  | one or more critical checks failed |

> Run the audit as **root** to let it read the live `sshd` config and
> `fail2ban`. Without root it still runs, but a few checks downgrade to `WARN`.

---

## Prerequisites

- A **fresh** Ubuntu (20.04 / 22.04 / 24.04) or Debian (11 / 12) VPS.
- **Root access** (you run the script with `sudo` / as root).
- **Your SSH public key.** Either:
  - root already has it in `/root/.ssh/authorized_keys` (typical when your
    provider injected your key at create time), **or**
  - you provide it via `SSH_PUBKEY` / `SSH_PUBKEY_FILE` (see config below).

> If the new user has **no** SSH key, the script will **refuse** to disable
> password authentication and warn you loudly — so you can't accidentally lock
> yourself out.

---

## Quick start

```bash
# 1. Copy the script to the server (scp, or paste it into a file).
scp bootstrap.sh root@SERVER_IP:/root/

# 2. (Recommended) create your config from the example.
cp bootstrap.conf.example bootstrap.conf
$EDITOR bootstrap.conf          # set NEW_USER, SSH_PUBKEY, TIMEZONE, ...

# 3. Preview everything first — changes NOTHING:
sudo bash bootstrap.sh --dry-run

# 4. Run it for real:
sudo bash bootstrap.sh
```

### Configuration

Settings can come from three places (later wins):

1. The `CONFIGURATION` section at the top of `bootstrap.sh`.
2. A config file — `./bootstrap.conf` is auto-loaded, or pass `--config FILE`.
   Start from [`bootstrap.conf.example`](./bootstrap.conf.example).
3. Environment variables, e.g.:

```bash
NEW_USER=deploy SSH_PORT=2222 INSTALL_DOCKER=true \
  INSTALL_NODE=true NODE_VERSION=20 INSTALL_MONITORING=netdata \
  SSH_PUBKEY="ssh-ed25519 AAAA... you@laptop" \
  sudo -E bash bootstrap.sh
```

Key variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `NEW_USER` | `deploy` | non-root sudo user (`""` = skip) |
| `SSH_PUBKEY` / `SSH_PUBKEY_FILE` | empty | public key to install (else copies root's) |
| `SSH_PORT` | `22` | SSH port |
| `DISABLE_ROOT_LOGIN` | `true` | set `PermitRootLogin no` |
| `DISABLE_PASSWORD_AUTH` | `true` | key-only SSH login |
| `TIMEZONE` / `LOCALE` | `UTC` / `en_US.UTF-8` | localisation |
| `SWAP_SIZE` | `2G` | swap size (`0` = skip) |
| `INSTALL_NGINX` / `INSTALL_CERTBOT` | `true` | web stack |
| `INSTALL_DOCKER` | `false` | optional Docker CE |
| `INSTALL_NODE` / `NODE_VERSION` | `false` / `20` | optional Node.js via NodeSource (pinned major) |
| `INSTALL_MONITORING` | `""` | `netdata`, `glances`, or empty (off) |
| `INSTALL_FAIL2BAN` | `true` | brute-force protection |
| `ENABLE_UNATTENDED_UPGRADES` | `true` | automatic security updates |
| `LOG_FILE` | `""` | append a colour-free transcript of the run here |

### CLI flags

| Flag | Effect |
|------|--------|
| `--verify`, `--audit` | **read-only audit** — check state, change nothing (see above) |
| `--dry-run` | print every action, change nothing |
| `--yes`, `-y` | assume "yes" to all confirmations (non-interactive) |
| `--config FILE` | load config overrides from `FILE` |
| `--log FILE` | append a colour-free transcript of the run to `FILE` |
| `--help`, `-h` | show usage |

---

## ⚠️ BIG SAFETY WARNING — don't lock yourself out

This script can **disable root login and password authentication**. If your key
setup is wrong, you could be locked out of your own server and need to recover
through your provider's web console/VNC.

**Follow this every time:**

1. **Keep your current SSH session OPEN** for the whole run and afterwards.
2. Before closing it, **open a SECOND terminal** and log in as the new user:
   ```bash
   ssh -p 22 deploy@SERVER_IP        # use -p <SSH_PORT> if you changed it
   sudo whoami                       # should print: root
   ```
3. Only when that second login **and** `sudo` work, close the first session.

The script helps you at every lock-out-prone step:

- It **validates** the SSH config with `sshd -t` and refuses to reload a broken
  one.
- It **refuses to disable passwords** when the new user has no SSH key.
- It asks for an explicit confirmation before applying SSH hardening, and a
  **second, separate confirmation** specifically before going key-only.
- If you move SSH to a non-standard port, it **opens that port in UFW first**,
  before telling `sshd` to switch — so the next login is never firewalled out.
- After reloading SSH it prints the exact `ssh -p <port> user@host` command to
  test from a second terminal.

But the final "test a second session" step is **on you** — do it.

> Changed `SSH_PORT`? Also make sure your **provider's cloud firewall** (AWS
> security group, Hetzner/DO firewall, etc.) allows the new port — UFW is not
> the only firewall in front of your box.

---

## What to verify afterwards

The fastest check is the built-in audit, which rolls up everything below:

```bash
sudo bash bootstrap.sh --verify     # or: sudo bash harden-check.sh
```

To inspect things by hand:

```bash
# SSH: key-only login as the new user works (from a second terminal)
ssh -p <SSH_PORT> <NEW_USER>@SERVER_IP

# Firewall
sudo ufw status verbose

# fail2ban is watching sshd
sudo fail2ban-client status sshd

# Automatic updates are configured
cat /etc/apt/apt.conf.d/20auto-upgrades

# Swap is active
swapon --show ; free -h

# sysctl hardening loaded
sudo sysctl net.ipv4.tcp_syncookies      # -> = 1

# nginx is serving (if installed)
curl -I http://SERVER_IP

# SSH config that was applied
sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|^port'
```

---

## Project layout

```
vps-bootstrap/
├── bootstrap.sh                       # the main script (setup + --verify audit)
├── harden-check.sh                    # tiny wrapper -> bootstrap.sh --verify
├── bootstrap.conf.example             # copy to bootstrap.conf and edit
├── README.md                          # this file (English)
├── README.ru.md                       # Russian translation
├── .gitignore
├── templates/
│   ├── nginx-site.conf.template       # static-site / reverse-proxy starter
│   └── fail2ban-sshd.local            # reference sshd jail
└── tests/
    └── run-tests.sh                   # dependency-free test suite
```

---

## Tests

The project ships a small, **dependency-free** test suite (pure bash, no host
required). It `bash -n`-checks every script, runs `shellcheck` when available,
and unit-tests the pure helper functions (size parsing, the audit counters, the
SSH-key safety predicate, `NODE_VERSION` validation, the confirm gate):

```bash
bash tests/run-tests.sh
```

```
== result: 18 passed, 0 failed ==
```

`bootstrap.sh` only runs `main` when executed directly (`if [[ "${BASH_SOURCE[0]}"
== "${0}" ]]`), so the tests can source it and exercise individual functions in
isolation without touching the system.

---

## Design notes

- **Idempotency primitives.** Small helpers (`apt_install`, `ufw_allow`,
  `set_sshd_option`, `backup_file`) each encapsulate a "check then change"
  pattern, so the step functions read like a clean checklist.
- **SSH config drop-in.** Hardening is written to
  `/etc/ssh/sshd_config.d/99-vps-bootstrap.conf` instead of editing the distro's
  main `sshd_config`. This keeps package upgrades clean and makes the changes
  easy to find or remove.
- **Honest `--dry-run`.** Every state-changing command goes through a `run`
  wrapper, so dry-run prints exactly what *would* happen and touches nothing.
- **Backups.** System files are copied to `*.bak.YYYYMMDD_HHMMSS` before edits.
- **Ordering for safety.** The user + key are created, and the firewall opens
  SSH, *before* SSH hardening runs — so password auth can never be disabled
  before a working key path exists.
- **Audit mode shares the source of truth.** `--verify` reads the live system
  with `sshd -T`, `ufw status`, `fail2ban-client`, `swapon` and `sysctl` rather
  than re-parsing files, so it reports what the kernel/daemons *actually* do.
  It is strictly read-only and never requires `--yes`.
- **Sourcing guard for testability.** `main` only runs when the script is
  executed directly, letting the test suite source it and unit-test helpers.

---

## License

MIT — use it, fork it, harden your boxes. No warranty; review the script and
run `--dry-run` before pointing it at anything you care about.
