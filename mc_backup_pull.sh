#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/backup.conf}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif have_cmd sudo; then
    sudo "$@"
  else
    fail "Need root permission to install dependencies. Install them manually or install sudo."
  fi
}

install_apt_packages() {
  local -a packages=("$@")
  (( ${#packages[@]} > 0 )) || return 0

  have_cmd apt-get || fail "Automatic dependency installation only supports apt-get. Install manually: ${packages[*]}"

  log "Installing missing dependencies with apt-get: ${packages[*]}"
  run_as_root apt-get update
  run_as_root apt-get install -y "${packages[@]}"
}

ensure_dependencies() {
  local -a packages=()

  have_cmd rsync || packages+=(rsync)
  have_cmd ssh || packages+=(openssh-client)

  if [[ -n "$SSH_PASSWORD_FILE" ]] && ! have_cmd sshpass; then
    packages+=(sshpass)
  fi

  if (( ${#packages[@]} > 0 )); then
    if [[ "$AUTO_INSTALL_DEPS" == "1" ]]; then
      install_apt_packages "${packages[@]}"
    else
      fail "Missing dependencies: ${packages[*]}. Install them manually or set AUTO_INSTALL_DEPS=1."
    fi
  fi

  need_cmd rsync
  need_cmd ssh
  if [[ -n "$SSH_PASSWORD_FILE" ]]; then
    need_cmd sshpass
  fi
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || fail "Config file not found: $CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  : "${REMOTE_HOST:?Set REMOTE_HOST in backup.conf}"
  : "${REMOTE_PATH:?Set REMOTE_PATH in backup.conf}"

  REMOTE_USER="${REMOTE_USER:-}"
  REMOTE_PORT="${REMOTE_PORT:-22}"
  SSH_KEY="${SSH_KEY:-}"
  SSH_PASSWORD_FILE="${SSH_PASSWORD_FILE:-}"
  BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/archive}"
  RETENTION_COUNT="${RETENTION_COUNT:-0}"
  RSYNC_EXTRA_ARGS="${RSYNC_EXTRA_ARGS:-}"
  AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"
}

build_remote() {
  local remote="$REMOTE_HOST:$REMOTE_PATH"
  if [[ -n "$REMOTE_USER" ]]; then
    remote="$REMOTE_USER@$remote"
  fi
  printf '%s' "$remote"
}

build_ssh_cmd() {
  local cmd="ssh -p $REMOTE_PORT -o ServerAliveInterval=30 -o ServerAliveCountMax=3"
  if [[ -z "$SSH_PASSWORD_FILE" ]]; then
    cmd="$cmd -o BatchMode=yes"
  fi
  if [[ -n "$SSH_KEY" ]]; then
    cmd="$cmd -i $SSH_KEY"
  fi
  if [[ -n "$SSH_PASSWORD_FILE" ]]; then
    cmd="sshpass -f $SSH_PASSWORD_FILE $cmd"
  fi
  printf '%s' "$cmd"
}

cleanup_old_files() {
  local keep="$RETENTION_COUNT"
  [[ "$keep" =~ ^[0-9]+$ ]] || fail "RETENTION_COUNT must be a non-negative integer"

  if (( keep == 0 )); then
    return
  fi

  local index timestamp file
  index=0

  while IFS=$'\t' read -r -d '' timestamp file; do
    ((index += 1))
    if (( index <= keep )); then
      continue
    fi

    [[ -n "$file" ]] || continue
    log "Removing old archive file: $file"
    rm -f -- "$file"
  done < <(
    find "$BACKUP_DIR" -type f -printf '%T@\t%p\0' 2>/dev/null \
      | sort -z -nr
  )
}

main() {
  load_config
  ensure_dependencies
  need_cmd find
  need_cmd sort
  need_cmd date

  if [[ -n "$SSH_PASSWORD_FILE" ]]; then
    [[ -f "$SSH_PASSWORD_FILE" ]] || fail "SSH_PASSWORD_FILE not found: $SSH_PASSWORD_FILE"
  fi
  mkdir -p -- "$BACKUP_DIR"

  local remote ssh_cmd
  remote="$(build_remote)"
  ssh_cmd="$(build_ssh_cmd)"

  local -a rsync_args
  rsync_args=(
    -a
    --numeric-ids
    --ignore-existing
    --partial
    --info=stats2,progress2
    -e "$ssh_cmd"
  )

  if [[ -n "$RSYNC_EXTRA_ARGS" ]]; then
    # Intentionally split user-provided rsync flags from backup.conf.
    # shellcheck disable=SC2206
    rsync_args+=($RSYNC_EXTRA_ARGS)
  fi

  log "Archiving new files from $remote to $BACKUP_DIR"
  rsync "${rsync_args[@]}" "$remote" "$BACKUP_DIR/"

  cleanup_old_files
  log "Archive sync completed: $BACKUP_DIR"
}

main "$@"
