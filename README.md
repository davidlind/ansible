# ansible-pull — Gitea on AlmaLinux 10

Self-contained Ansible configuration for a single AlmaLinux 10 VM running a
Gitea instance, converged with **ansible-pull** from this repository.

```
                 ┌────────────────────────── VM (AlmaLinux 10) ─────────────────────────────┐
                 │                                                                          │
  clients ──443──▶ Caddy (systemd, caddy user)                                             │
                 │   • local-CA HTTPS (auto certs for gitea.lan)                           │
                 │   └── reverse_proxy ──▶ Gitea (systemd, git user)                       │
                 │                             • /usr/local/bin/gitea (checksum-verified)  │
                 │                             • SQLite: /var/lib/gitea/data/gitea.db      │
                 │                             • built-in SSH server on :2222              │
                 │                                                                          │
                 │  ansible-pull.timer (hourly, installed by the pull role):                │
                 │    pull this repo → run playbooks/site.yml                               │
                 └──────────────────────────────────────────────────────────────────────────┘
```

Both services are plain upstream binaries managed by systemd — no package
repositories involved. HTTPS is terminated by Caddy using its internal local
CA, so certificates are issued automatically and are trusted on your LAN
after a one-time import of the root CA (see [Trust the certificate](#trust-the-certificate)).

## Repository layout

| Path | Purpose |
|---|---|
| `playbooks/site.yml` | Entry point — roles: `common` → `caddy` → `gitea` → `pull` |
| `roles/common/` | Packages, firewalld (80, 443, 2222), architecture check |
| `roles/caddy/` | Caddy binary + unit + Caddyfile, local-CA HTTPS |
| `roles/gitea/` | Gitea user/dirs/binary, secrets, `app.ini`, unit, admin account |
| `roles/pull/` | Self-installs the ansible-pull runner config, systemd service + timer |
| `group_vars/all.yml` | Site config: domain, ports, versions, paths, repo URL |
| `group_vars/vault.yml` | Admin credentials (**ansible-vault encrypted**) |
| `scripts/ansible-pull-run.sh` | The runner invoked by the timer (lives in the checkout) |

## Prerequisites

* Fresh AlmaLinux 10 VM booted with cloud-init and outbound internet
  (binary downloads, `ansible-galaxy`).
* A git repository URL to push **this repo** to — an existing git host
  (GitHub/GitLab/existing Gitea). Bootstrapping Gitea from a repo served by
  the Gitea it creates doesn't work on the first run, hence "existing host".
* A DNS record (or `/etc/hosts` entries on clients) pointing `gitea.lan`
  at the VM. Change `gitea_domain` in `group_vars/all.yml` to your real
  hostname — it's what goes into certificates and clone URLs.

## Setup

### 1. Configure and push this repo

```bash
# domain, versions, ports, and ansible_pull_repo_url (the URL you push to)
vi group_vars/all.yml

# admin account
vi group_vars/vault.yml           # set a real password (>= 12 chars)
ansible-vault encrypt group_vars/vault.yml

git add -A && git commit -m "gitea host config" && git push
```

`ansible_pull_repo_url` must be the URL of this repository — it is what the
systemd timer pulls from after first boot (`ansible_pull_branch` defaults
to `main`).

### 2. Boot the VM with cloud-init

No bootstrap script: cloud-init's built-in `ansible` module installs
Ansible and runs `ansible-pull` against this repo. Give the VM this
user-data:

```yaml
#cloud-config
# ansible-pull clones the repo with the git module, so git must exist first.
packages:
  - git

# Only needed while group_vars/vault.yml is ansible-vault encrypted.
# write_files runs in cloud-init's init stage, before the ansible module.
write_files:
  - path: /etc/ansible-pull/vault-password-file
    permissions: '0600'
    content: |
      <the ansible-vault password>

ansible:
  install_method: distro
  package_name: ansible-core
  galaxy:
    actions:
      # ansible.posix must be available before the playbook runs; the
      # timer's runner re-installs it from requirements.yml on every run.
      - [ansible-galaxy, collection, install, ansible.posix]
  pull:
    - url: https://git.example.com/ops/ansible-pull.git   # same as ansible_pull_repo_url
      checkout: main                                       # same as ansible_pull_branch
      playbook_names:
        - playbooks/site.yml
      inventory: inventory.ini
      vault_password_file: /etc/ansible-pull/vault-password-file
```

Notes:

* `install_method` + `package_name` make cloud-init run
  `dnf install ansible-core`; every key in `pull[]` is forwarded verbatim to
  `ansible-pull` as `--flag=value` (`playbook_names` become positional
  arguments).
* Drop `vault_password_file` (and the `write_files` entry) if you left
  `group_vars/vault.yml` unencrypted.
* cloud-init cannot choose ansible-pull's checkout directory, so its
  one-shot checkout lands in `~/.ansible/pull/<hostname>`. That copy is
  only used for the first run: the playbook itself then converges the
  canonical checkout at `/opt/ansible-pull` (`ansible_pull_dir`) and
  installs the timer that keeps pulling there. From then on the VM
  converges on its own — the `pull` role handles all of it on every run.
* The `ansible` module runs in cloud-init's final stage and is part of the
  upstream default module list. If your image's `/etc/cloud/cloud.cfg`
  does not contain `- ansible`, add it to `cloud_init_modules`/`final`
  list (or check `journalctl -u cloud-init` for `cc_ansible`).

**Not using cloud-init?** Install `ansible-core` + `git`, clone this repo
to `/opt/ansible-pull`, and run `ansible-playbook playbooks/site.yml` as
root (with `ANSIBLE_VAULT_PASSWORD_FILE` set if the vault is encrypted).
The `pull` role installs the timer, so that is the only manual step.

### 3. Trust the certificate

Caddy issues certs from its internal local CA stored on the VM:

```bash
scp vm:/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt .
```

Import `root.crt` into the OS/browser trust store on machines that should
get a green padlock (one time per client). Until then `https://gitea.lan`
works but shows a warning.

To also cover the IP address, add it to `gitea_site_addresses`:

```yaml
gitea_site_addresses:
  - "{{ gitea_domain }}"
  - 192.168.1.50
```

### 4. Log in

`https://gitea.lan` with the admin account from `group_vars/vault.yml`
(no forced password change). Registration is disabled by default
(`gitea_disable_registration`) — create users as admin or flip the var.

## Day-2 operations

**Apply any change:** push to the repo and either wait for the hourly timer
or run it immediately:

```bash
systemctl start ansible-pull.service   # journal: journalctl -u ansible-pull.service
```

**Upgrade Gitea/Caddy:** bump `gitea_version` / `caddy_version` in
`group_vars/all.yml`, push, trigger the timer run. Downloads are verified
against upstream checksum files; only a version change causes a service
restart (steady-state runs report `changed=0`).

**Manual run from the repo checkout:**

```bash
cd /opt/ansible-pull
export ANSIBLE_VAULT_PASSWORD_FILE=/etc/ansible-pull/vault-password-file
ansible-playbook playbooks/site.yml
```

**Timer & runner:** `systemctl list-timers ansible-pull.timer`,
`systemctl status ansible-pull.service`. The runner refuses to start twice
concurrently (`/run/ansible-pull.lock`) and logs to the journal.

**Logs:** `journalctl -u gitea -u caddy -f` (Gitea logs to console → journald).

**Backup:** stop the service and copy `/var/lib/gitea` (or use
`sqlite3 /var/lib/gitea/data/gitea.db ".backup /path/gitea.db")` — repos and
the DB both live under `/var/lib/gitea/data`.

## How the secrets work

Gitea 28 would normally auto-generate four secrets and *write them back into
`app.ini`* on first boot — which would fight with config-as-code. Instead the
playbook runs `gitea generate secret` exactly once (`creates:`-guarded) into
`/etc/gitea/secrets/` (root:`git`, 0640) and `app.ini` references them:

```ini
[security]  SECRET_KEY_URI   = file:/etc/gitea/secrets/secret_key
[security]  INTERNAL_TOKEN_URI = file:/etc/gitea/secrets/internal_token
[oauth2]    JWT_SECRET_URI   = file:/etc/gitea/secrets/oauth2_jwt_secret
[server]    LFS_JWT_SECRET_URI = file:/etc/gitea/secrets/lfs_jwt_secret
```

So `app.ini` contains no secrets, Gitea never needs to rewrite it, and every
key in it is owned by this repository. Delete the files to rotate a secret
(then restart gitea).

## Notes & gotchas

* **`app.ini` is config-as-code.** Changes made in Gitea's admin *Site
  Configuration* that touch `app.ini` will be reverted on the next pull.
  Change `group_vars/all.yml` / the template instead.
* **Admin password** is applied only at creation; changing it later in the
  vault has no effect on the existing account.
* **Ports:** 443 (+80 redirect) and 2222 are opened in firewalld; port 22 is
  untouched. Gitea SSH clone URL: `ssh://git@gitea.lan:2222`.
* **SELinux** stays enforcing: binaries get explicit `bin_t` file contexts;
  data lives under `/var/lib/gitea`.
* **`INSTALL_LOCK = true`** from the start — the web install wizard is
  disabled; everything is provisioned by this playbook.
* SQLite is embedded in the Gitea binary — no database server involved.
* **Two checkouts, one source of truth.** cloud-init's initial checkout and
  the timer's checkout at `/opt/ansible-pull` are both plain clones of the
  same repo; only the latter is used after first boot.

## Key variables (`group_vars/all.yml`)

| Variable | Default | Meaning |
|---|---|---|
| `gitea_domain` | `gitea.lan` | Hostname in cert, ROOT_URL, SSH domain |
| `gitea_site_addresses` | `[gitea_domain]` | Caddy site addresses (= cert SANs) |
| `gitea_http_port` | `3000` | Gitea HTTP on loopback |
| `gitea_ssh_port` | `2222` | Gitea built-in SSH server |
| `gitea_version` | `28.1.0` | Pinned Gitea release |
| `caddy_version` | `2.11.7` | Pinned Caddy release |
| `gitea_disable_registration` | `true` | Self-explanatory |
| `gitea_require_signin_view` | `false` | Require login just to browse |
| `ansible_pull_repo_url` | *placeholder* | Git URL the timer pulls from |
| `ansible_pull_branch` | `main` | Branch to track |
| `ansible_pull_dir` | `/opt/ansible-pull` | Checkout the timer runs from |
| `ansible_pull_boot_delay` | `10min` | First timer run after boot |
| `ansible_pull_interval` | `1h` | Period between timer runs |
