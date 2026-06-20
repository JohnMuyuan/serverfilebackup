#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/server-archive-backup"
CONFIG_DIR="/etc/server-archive-backup"
REPOSITORY="${SERVER_BACKUP_REPOSITORY:-}"
BRANCH="${SERVER_BACKUP_BRANCH:-main}"

say() { printf '%s\n' "$*"; }
die() { say "安装失败：$*" >&2; exit 1; }

prompt_tty() {
  local message="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$message" "$default" > /dev/tty
  else
    printf '%s: ' "$message" > /dev/tty
  fi
  IFS= read -r answer < /dev/tty || true
  printf '%s' "${answer:-$default}"
}

usage() {
  say "用法：install.sh --repo GitHub用户名/仓库名 [--branch main]"
}

while (( $# > 0 )); do
  case "$1" in
    --repo) REPOSITORY="${2:?--repo 缺少参数}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch 缺少参数}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

(( EUID == 0 )) || die "请在 curl 后使用 | sudo bash，或直接 sudo ./install.sh"
[[ -r /dev/tty ]] || die "需要交互终端，请不要在无 TTY 环境运行"

if [[ -z "$REPOSITORY" ]]; then
  REPOSITORY="$(prompt_tty '请输入 GitHub 仓库（用户名/仓库名）')"
fi
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GitHub 仓库格式应为 用户名/仓库名"

install_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssh-client gzip coreutils findutils util-linux tar rsync
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssh-clients gzip coreutils findutils util-linux tar rsync
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssh-clients gzip coreutils findutils util-linux tar rsync
  else
    die "暂不支持此包管理器，请先安装 curl、SSH 客户端、tar、gzip、coreutils、findutils、util-linux"
  fi
}

say "[1/5] 安装依赖..."
install_dependencies

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
archive_url="https://github.com/$REPOSITORY/archive/refs/heads/$BRANCH.tar.gz"
say "[2/5] 从 $REPOSITORY 下载程序..."
curl -fL --retry 3 "$archive_url" -o "$tmp_dir/project.tar.gz"
mkdir -p "$tmp_dir/source"
tar -xzf "$tmp_dir/project.tar.gz" --strip-components=1 -C "$tmp_dir/source"
[[ -f "$tmp_dir/source/backup.sh" && -f "$tmp_dir/source/backupctl" ]] || die "仓库中缺少 backup.sh 或 backupctl"

say "[3/5] 安装到 $INSTALL_DIR ..."
install -d -m 755 "$INSTALL_DIR"
install -m 755 "$tmp_dir/source/backup.sh" "$INSTALL_DIR/backup.sh"
install -m 755 "$tmp_dir/source/backupctl" "$INSTALL_DIR/backupctl"
install -m 644 "$tmp_dir/source/README.md" "$INSTALL_DIR/README.md"
ln -sfn "$INSTALL_DIR/backupctl" /usr/local/bin/backupctl

default_user="${SUDO_USER:-root}"
if [[ -f "$CONFIG_DIR/install.conf" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_DIR/install.conf"
  default_user="${RUN_USER:-$default_user}"
fi
run_user="$(prompt_tty '运行备份的 Linux 用户' "$default_user")"
id "$run_user" >/dev/null 2>&1 || die "Linux 用户不存在：$run_user"
default_backup_root="/mnt/backup-disk/server-archives"
if [[ -f "$CONFIG_DIR/backup.conf" ]]; then
  default_backup_root="$(bash -c 'source "$1"; printf "%s" "$BACKUP_ROOT"' _ "$CONFIG_DIR/backup.conf")"
fi
backup_root="$(prompt_tty '2T 备份硬盘上的归档目录' "$default_backup_root")"
[[ "$backup_root" == /* ]] || die "归档目录必须是绝对路径"
[[ "$backup_root" != *[[:space:]]* ]] || die "归档目录暂不支持空格"

say "[4/5] 创建配置和 systemd 服务..."
install -d -m 750 -o root -g "$run_user" "$CONFIG_DIR" "$CONFIG_DIR/jobs.d"
install -d -m 750 -o "$run_user" -g "$run_user" "$backup_root"

if [[ ! -f "$CONFIG_DIR/backup.conf" ]]; then
  cat > "$CONFIG_DIR/backup.conf" <<EOF
BACKUP_ROOT=$(printf '%q' "$backup_root")
JOBS_DIR=$(printf '%q' "$CONFIG_DIR/jobs.d")
DEFAULT_RETENTION_COUNT="100"
DEFAULT_COMPRESSION_LEVEL="6"
DEFAULT_TRANSFER_MODE="mirror"
DEFAULT_PARALLEL_TRANSFERS="1"
LOCK_FILE="\$BACKUP_ROOT/.backup.lock"
LOCK_WAIT_SECONDS="86400"
EOF
fi
cat > "$CONFIG_DIR/install.conf" <<EOF
RUN_USER=$(printf '%q' "$run_user")
EOF
chown root:"$run_user" "$CONFIG_DIR/backup.conf" "$CONFIG_DIR/install.conf"
chmod 640 "$CONFIG_DIR/backup.conf" "$CONFIG_DIR/install.conf"

cat > /etc/systemd/system/server-archive-backup.service <<EOF
[Unit]
Description=Archive remote servers to local backup disk
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$backup_root

[Service]
Type=oneshot
User=$run_user
Environment=BACKUP_CONFIG=$CONFIG_DIR/backup.conf
ExecStart=$INSTALL_DIR/backup.sh
NoNewPrivileges=true
PrivateTmp=true
EOF

cat > /etc/systemd/system/server-archive-backup@.service <<EOF
[Unit]
Description=Archive remote server backup job %i
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$backup_root

[Service]
Type=oneshot
User=$run_user
Environment=BACKUP_CONFIG=$CONFIG_DIR/backup.conf
ExecStart=$INSTALL_DIR/backup.sh --job %i
NoNewPrivileges=true
PrivateTmp=true
EOF

cat > /etc/systemd/system/server-archive-backup.timer <<'EOF'
[Unit]
Description=Run server archive backup every day

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload

say "[5/5] 安装完成。现在进入中文配置菜单。"
say "以后随时运行：sudo backupctl"
sleep 1
SERVER_BACKUP_APP_DIR="$INSTALL_DIR" SERVER_BACKUP_CONFIG_DIR="$CONFIG_DIR" \
  "$INSTALL_DIR/backupctl" menu < /dev/tty > /dev/tty
