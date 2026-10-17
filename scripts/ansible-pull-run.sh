#!/usr/bin/env bash
# Converges this host from the playbook repo with ansible-pull.
# Invoked by the systemd unit (ansible-pull.service, started by
# ansible-pull.timer) or directly:
#   sudo /opt/ansible-pull/scripts/ansible-pull-run.sh
set -euo pipefail

# Never run twice concurrently (boot-time run vs. cloud-init's first run
# vs. timer tick). A held lock means a run is already in progress, which
# is success from the timer's point of view.
exec 9>/run/ansible-pull.lock
if ! flock -n 9; then
  echo "another ansible-pull run is in progress — exiting"
  exit 0
fi

CONF="${ANSIBLE_PULL_CONF:-/etc/ansible-pull.conf}"
[[ -r "$CONF" ]] && source "$CONF"

: "${REPO_URL:?REPO_URL missing from $CONF}"
: "${REPO_BRANCH:=main}"
: "${CLONE_DIR:=/opt/ansible-pull}"

VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE:-/etc/ansible-pull/vault-password-file}"

export ANSIBLE_CONFIG="$CLONE_DIR/ansible.cfg"
export ANSIBLE_ROLES_PATH="$CLONE_DIR/roles"
[[ -r "$VAULT_PASSWORD_FILE" ]] && export ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PASSWORD_FILE"

cd "$CLONE_DIR"

# Installed by this same repo (see requirements.yml); a no-op when present.
ansible-galaxy collection install -r "$CLONE_DIR/requirements.yml"

# ansible-pull updates the checkout at CLONE_DIR, then runs the playbook
# from it (cwd ends up in CLONE_DIR, so relative paths in ansible.cfg work).
exec ansible-pull \
  --url "$REPO_URL" \
  --ref "$REPO_BRANCH" \
  --directory "$CLONE_DIR" \
  --inventory "$CLONE_DIR/inventory.ini" \
  --connection local \
  playbooks/site.yml
