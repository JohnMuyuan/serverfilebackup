#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_CONFIG="${BACKUP_CONFIG:-$SCRIPT_DIR/backup.conf}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

shell_quote() {
  printf '%q' "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令: $1"
}

load_global_config() {
  [[ -f "$GLOBAL_CONFIG" ]] || fail "找不到全局配置: $GLOBAL_CONFIG（请复制 backup.conf.example）"
  # shellcheck source=/dev/null
  source "$GLOBAL_CONFIG"

  BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/archive}"
  JOBS_DIR="${JOBS_DIR:-$SCRIPT_DIR/jobs.d}"
  DEFAULT_RETENTION_COUNT="${DEFAULT_RETENTION_COUNT:-0}"
  DEFAULT_COMPRESSION_LEVEL="${DEFAULT_COMPRESSION_LEVEL:-6}"
  DEFAULT_TRANSFER_MODE="${DEFAULT_TRANSFER_MODE:-mirror}"
  LOCK_FILE="${LOCK_FILE:-$BACKUP_ROOT/.backup.lock}"
}

reset_job_config() {
  JOB_NAME=""
  REMOTE_HOST=""
  REMOTE_USER=""
  REMOTE_PORT="22"
  SSH_KEY=""
  SSH_PASSWORD_FILE=""
  SSH_KNOWN_HOSTS_FILE=""
  SOURCE_PATHS=()
  EXCLUDE_PATTERNS=()
  REMOTE_PRE_COMMAND=""
  REMOTE_POST_COMMAND=""
  BACKUP_SUBDIR=""
  STAGING_DIR=""
  RETENTION_COUNT="$DEFAULT_RETENTION_COUNT"
  COMPRESSION_LEVEL="$DEFAULT_COMPRESSION_LEVEL"
  TRANSFER_MODE="$DEFAULT_TRANSFER_MODE"
}

load_job_config() {
  local config_file="$1"
  reset_job_config
  # shellcheck source=/dev/null
  source "$config_file"

  [[ "$JOB_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || fail "$config_file: JOB_NAME 只能包含字母、数字、点、下划线和短横线"
  [[ -n "$REMOTE_HOST" ]] || fail "$config_file: 未设置 REMOTE_HOST"
  (( ${#SOURCE_PATHS[@]} > 0 )) || fail "$config_file: SOURCE_PATHS 不能为空"
  [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || fail "$config_file: REMOTE_PORT 必须是端口号"
  [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] || fail "$config_file: RETENTION_COUNT 必须是非负整数"
  [[ "$COMPRESSION_LEVEL" =~ ^[1-9]$ ]] || fail "$config_file: COMPRESSION_LEVEL 必须是 1 到 9"
  [[ "$TRANSFER_MODE" == "mirror" || "$TRANSFER_MODE" == "stream" ]] \
    || fail "$config_file: TRANSFER_MODE 必须是 mirror 或 stream"

  local path
  for path in "${SOURCE_PATHS[@]}"; do
    [[ "$path" == /* ]] || fail "$config_file: SOURCE_PATHS 必须使用绝对路径: $path"
  done
}

build_ssh_args() {
  SSH_ARGS=(
    -p "$REMOTE_PORT"
    -o ConnectTimeout=20
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
  )

  [[ -n "$SSH_KEY" ]] && SSH_ARGS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
  [[ -n "$SSH_KNOWN_HOSTS_FILE" ]] \
    && SSH_ARGS+=(-o "UserKnownHostsFile=$SSH_KNOWN_HOSTS_FILE")

  if [[ -n "$SSH_PASSWORD_FILE" ]]; then
    require_command sshpass
    [[ -f "$SSH_PASSWORD_FILE" ]] || fail "密码文件不存在: $SSH_PASSWORD_FILE"
    SSH_PREFIX=(sshpass -f "$SSH_PASSWORD_FILE")
  else
    SSH_PREFIX=()
    SSH_ARGS+=(-o BatchMode=yes)
  fi

  SSH_TARGET="$REMOTE_HOST"
  [[ -n "$REMOTE_USER" ]] && SSH_TARGET="$REMOTE_USER@$REMOTE_HOST"
}

run_remote_hook() {
  local hook_name="$1"
  local command="$2"
  [[ -z "$command" ]] && return 0
  log "$JOB_NAME: 执行远端${hook_name}命令"
  "${SSH_PREFIX[@]}" ssh "${SSH_ARGS[@]}" "$SSH_TARGET" \
    "bash -c $(shell_quote "set -Eeuo pipefail; $command")"
}

build_remote_archive_command() {
  local command="set -Eeuo pipefail; command -v tar >/dev/null; command -v gzip >/dev/null; tar -C / --create --sort=name --format=posix --pax-option=delete=atime,delete=ctime --numeric-owner"
  local pattern path relative

  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    command+=" --exclude=$(shell_quote "$pattern")"
  done
  command+=" --"
  for path in "${SOURCE_PATHS[@]}"; do
    relative="${path#/}"
    [[ -n "$relative" ]] || relative="."
    command+=" $(shell_quote "$relative")"
  done
  command+=" | gzip -n -$COMPRESSION_LEVEL"
  printf '%s' "$command"
}

build_rsync_ssh_command() {
  local -a command=("${SSH_PREFIX[@]}" ssh "${SSH_ARGS[@]}")
  local item output=""
  for item in "${command[@]}"; do
    output+="$(shell_quote "$item") "
  done
  printf '%s' "${output% }"
}

sync_remote_mirror() {
  require_command rsync

  local staging_root="$1" ssh_command path relative target pattern remote_type
  local -a rsync_args
  "${SSH_PREFIX[@]}" ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "command -v rsync >/dev/null" \
    || fail "$JOB_NAME: 远端缺少 rsync；请在远端安装 rsync 后重试"
  ssh_command="$(build_rsync_ssh_command)"
  mkdir -p -- "$staging_root"

  rsync_args=(
    -a
    --numeric-ids
    --protect-args
    --partial
    --partial-dir=.rsync-partial
    --delete
    --delete-excluded
    --info=stats2,progress2
    -e "$ssh_command"
  )
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    rsync_args+=(--exclude "$pattern")
  done

  for path in "${SOURCE_PATHS[@]}"; do
    relative="${path#/}"
    target="$staging_root/$relative"
    remote_type="$("${SSH_PREFIX[@]}" ssh "${SSH_ARGS[@]}" "$SSH_TARGET" \
      "if test -d $(shell_quote "$path"); then printf directory; elif test -f $(shell_quote "$path"); then printf file; else exit 2; fi")" \
      || fail "$JOB_NAME: 远端路径不存在或不可读取: $path"

    if [[ "$remote_type" == "directory" ]]; then
      mkdir -p -- "$target"
      log "$JOB_NAME: 断点续传目录 $path"
      rsync "${rsync_args[@]}" "$SSH_TARGET:$path/" "$target/" || return $?
    else
      mkdir -p -- "$(dirname -- "$target")"
      log "$JOB_NAME: 断点续传文件 $path"
      rsync "${rsync_args[@]}" "$SSH_TARGET:$path" "$target" || return $?
    fi
  done
}

archive_local_mirror() {
  local staging_root="$1" output_file="$2"
  log "$JOB_NAME: 增量同步完成，正在本地生成归档"
  tar -C "$staging_root" --create --sort=name --format=posix \
    --pax-option=delete=atime,delete=ctime --numeric-owner \
    --exclude='.rsync-partial' -- . | gzip -n -"$COMPRESSION_LEVEL" > "$output_file"
}

find_duplicate() {
  local checksum="$1"
  local checksum_file saved_checksum saved_name
  shopt -s nullglob
  for checksum_file in "$JOB_DIR"/*.sha256; do
    read -r saved_checksum saved_name < "$checksum_file" || continue
    saved_name="${saved_name#\*}"
    [[ -f "$JOB_DIR/$saved_name" ]] || continue
    if [[ "$saved_checksum" == "$checksum" ]]; then
      printf '%s' "$saved_name"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

apply_retention() {
  (( RETENTION_COUNT > 0 )) || return 0

  local -a archives=()
  mapfile -d '' archives < <(
    find "$JOB_DIR" -maxdepth 1 -type f -name "${JOB_NAME}_*.tar.gz" -printf '%T@\t%p\0' \
      | sort -z -nr
  )

  local index entry archive
  for (( index=RETENTION_COUNT; index<${#archives[@]}; index++ )); do
    entry="${archives[$index]}"
    archive="${entry#*$'\t'}"
    log "$JOB_NAME: 清理超出保留数量的归档: $(basename -- "$archive")"
    rm -f -- "$archive" "$archive.sha256"
  done
}

run_job() {
  local config_file="$1"
  load_job_config "$config_file"
  build_ssh_args

  JOB_DIR="$BACKUP_ROOT/${BACKUP_SUBDIR:-$JOB_NAME}"
  mkdir -p -- "$JOB_DIR"

  local timestamp filename final_file partial_file remote_command checksum duplicate staging_root
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  filename="${JOB_NAME}_${timestamp}.tar.gz"
  final_file="$JOB_DIR/$filename"
  partial_file="$final_file.part"
  remote_command="$(build_remote_archive_command)"
  staging_root="${STAGING_DIR:-$BACKUP_ROOT/.staging/$JOB_NAME}"

  rm -f -- "$partial_file"
  run_remote_hook "备份前" "$REMOTE_PRE_COMMAND"

  local archive_status=0 post_status=0
  if [[ "$TRANSFER_MODE" == "mirror" ]]; then
    log "$JOB_NAME: 从 $SSH_TARGET 增量同步到本地缓存（支持断点续传）"
    sync_remote_mirror "$staging_root" || archive_status=$?
    if (( archive_status == 0 )); then
      archive_local_mirror "$staging_root" "$partial_file" || archive_status=$?
    fi
  else
    log "$JOB_NAME: 从 $SSH_TARGET 创建并下载流式归档"
    "${SSH_PREFIX[@]}" ssh "${SSH_ARGS[@]}" "$SSH_TARGET" \
      "bash -c $(shell_quote "$remote_command")" > "$partial_file" || archive_status=$?
  fi
  run_remote_hook "备份后" "$REMOTE_POST_COMMAND" || post_status=$?

  if (( archive_status != 0 )); then
    rm -f -- "$partial_file"
    fail "$JOB_NAME: 同步、打包或下载失败（状态码 $archive_status）；镜像模式下次会继续未完成文件"
  fi
  [[ -s "$partial_file" ]] || { rm -f -- "$partial_file"; fail "$JOB_NAME: 收到空归档"; }
  gzip -t "$partial_file" || { rm -f -- "$partial_file"; fail "$JOB_NAME: 归档完整性检查失败"; }

  checksum="$(sha256sum "$partial_file" | awk '{print $1}')"
  if duplicate="$(find_duplicate "$checksum")"; then
    rm -f -- "$partial_file"
    log "$JOB_NAME: 内容与已有归档相同，已去重（$duplicate）"
  else
    mv -- "$partial_file" "$final_file"
    printf '%s *%s\n' "$checksum" "$filename" > "$final_file.sha256"
    log "$JOB_NAME: 已保存 $final_file"
  fi

  apply_retention
  (( post_status == 0 )) || fail "$JOB_NAME: 归档已保存，但远端备份后命令失败（状态码 $post_status）"
}

usage() {
  cat <<'EOF'
用法: ./backup.sh [--job 任务名] [--list] [--help]
  无参数          依次执行 jobs.d 中所有启用的 .conf 任务
  --job 任务名    只执行指定 JOB_NAME
  --list          列出任务，不执行备份
EOF
}

main() {
  require_command bash
  require_command ssh
  require_command tar
  require_command gzip
  require_command sha256sum
  require_command find
  require_command sort
  require_command flock
  load_global_config

  local selected_job="" list_only=0
  while (( $# > 0 )); do
    case "$1" in
      --job) [[ $# -ge 2 ]] || fail "--job 后需要任务名"; selected_job="$2"; shift 2 ;;
      --list) list_only=1; shift ;;
      --help|-h) usage; return 0 ;;
      *) fail "未知参数: $1" ;;
    esac
  done

  mkdir -p -- "$BACKUP_ROOT"
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail "已有备份任务正在运行: $LOCK_FILE"

  local -a configs=()
  shopt -s nullglob
  configs=("$JOBS_DIR"/*.conf)
  shopt -u nullglob
  (( ${#configs[@]} > 0 )) || fail "未找到任务配置: $JOBS_DIR/*.conf"

  local config config_job matched=0 failed=0
  for config in "${configs[@]}"; do
    if ! config_job="$( (load_job_config "$config"; printf '%s' "$JOB_NAME") )"; then
      log "ERROR: 无法载入任务配置，但会继续执行其他任务: $config" >&2
      failed=1
      continue
    fi
    [[ -z "$selected_job" || "$config_job" == "$selected_job" ]] || continue
    matched=1
    if (( list_only )); then
      (load_job_config "$config"; printf '%-24s %s@%s  %s\n' "$JOB_NAME" "${REMOTE_USER:--}" "$REMOTE_HOST" "${SOURCE_PATHS[*]}")
      continue
    fi
    if ! (run_job "$config"); then
      log "ERROR: 任务失败，但会继续执行其他任务: $config_job" >&2
      failed=1
    fi
  done

  (( matched == 1 )) || fail "没有找到任务: $selected_job"
  (( list_only == 1 )) || log "全部任务执行完毕"
  return "$failed"
}

main "$@"
