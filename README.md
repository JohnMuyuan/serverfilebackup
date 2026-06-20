# Server Archive Backup

这是一个运行在 Linux 备份机上的多服务器归档工具。它通过 SSH 在远端即时创建 `tar.gz`，直接传输到本地备份盘，适合 Minecraft、博客、邮件服务和普通文件目录。

## 最简单的使用方法（一键安装）

先把整个项目上传到公开 GitHub 仓库。假设仓库地址是：

```text
https://github.com/zhangsan/server-backup
```

那么在备份服务器执行下面这一行（把两处用户名和仓库名换成自己的）：

```bash
curl -fsSL https://raw.githubusercontent.com/zhangsan/server-backup/main/install.sh | sudo bash -s -- --repo zhangsan/server-backup
```

安装器会自动：

1. 安装 SSH、rsync、tar、gzip 等依赖。
2. 把程序安装到 `/opt/server-archive-backup`。
3. 询问运行备份的 Linux 用户。
4. 询问 2T 硬盘上的归档目录。
5. 创建 systemd 服务并打开中文管理菜单。

如果仓库默认分支不是 `main`，在命令最后加上分支：

```bash
curl -fsSL https://raw.githubusercontent.com/zhangsan/server-backup/master/install.sh | sudo bash -s -- --repo zhangsan/server-backup --branch master
```

以后只需运行下面这条命令重新打开菜单：

```bash
sudo backupctl
```

菜单如下：

```text
========================================
        服务器自动备份管理器
========================================
1. 添加或修改备份任务
2. 查看已有任务
3. 立即运行一个任务
4. 立即运行全部任务
5. 为任务设置独立备份周期（日/周/月/自定义）
6. 查看定时器状态和最近日志
7. 删除任务（保留归档）
0. 退出
```

### 第一次添加服务器

选择菜单 `1`，然后按提示回答：

```text
任务名称：my-blog
服务器 IP 或域名：blog.example.com
SSH 用户名：backup
SSH 端口：22
SSH 私钥路径：直接回车使用默认值
远端绝对路径：/var/www/my-blog
远端绝对路径：直接回车结束路径输入
排除规则：直接回车表示不排除
最多保留：100
压缩级别：6
是否启用断点续传和后续增量同步：Y
并行下载连接数：4
```

菜单可以自动创建 SSH 密钥，并询问是否把公钥复制到远端。选择“是”后输入一次远端 SSH 密码；以后自动备份便不再需要密码。最后选择立即测试和首次备份。

选择断点续传后，菜单还会检查远端是否存在 `rsync`。如果缺少，它会先询问是否允许安装；确认后才会使用远端的 `apt`、`dnf` 或 `yum` 自动安装。

添加完服务器后选择菜单 `5`，先选择一个任务，再为它选择每天、每周、每月或自定义周期。每个任务都可以使用不同周期，例如博客每天、Halo 每周、归档服务器每月。也可以选择“全部任务”继续使用统一周期。

### 安装前确认 2T 硬盘位置

在备份服务器运行：

```bash
lsblk -f
findmnt
```

找到 2T 硬盘真实挂载点，例如 `/mnt/backup-disk`。安装器询问归档目录时填写：

```text
/mnt/backup-disk/server-archives
```

不要把一个未挂载的普通空目录误认为 2T 硬盘，否则备份可能写入系统盘。

## 能做什么

- 任意数量的服务器和任务，每个任务一份 `jobs.d/*.conf`。
- 一个任务可归档多个绝对路径。
- 默认用 rsync 把远端文件增量同步到 2T 备份盘的本地缓存，断线后可续传。
- 同步完成后在备份机本地生成 `tar.gz`，远端不会遗留临时归档包。
- 文件按 `任务名_UTC时间.tar.gz` 命名，例如 `my-blog_20260620T083000Z.tar.gz`。
- 下载完成后执行 gzip 完整性检查并生成 SHA-256 校验文件。
- 内容与历史归档完全相同时自动删除本次副本。
- 每个任务可独立设置保留数量，超过数量时自动删除最老归档。
- 支持远端备份前/后命令，可用于数据库导出和临时文件清理。
- 使用进程锁避免 cron 或 systemd 重复运行。
- 某个任务失败后继续执行其他任务，最终以非零状态退出以便监控发现问题。

旧版 Minecraft 拉取脚本 `mc_backup_pull.sh` 仍然保留；其配置模板为 `backup.legacy.conf.example`。新部署建议使用 `backup.sh`。

旧脚本如需继续运行，可复制旧模板并显式指定配置：

```bash
cp backup.legacy.conf.example backup.legacy.conf
CONFIG_FILE="$PWD/backup.legacy.conf" ./mc_backup_pull.sh
```

## 目录结构

```text
backup.sh                  通用备份入口
backupctl                  中文交互式管理菜单
install.sh                 GitHub 一键安装器
backup.conf.example        全局配置模板
backup.legacy.conf.example 旧 Minecraft 脚本配置模板
jobs.d/
  minecraft.conf.example  Minecraft 示例
  blog.conf.example       博客和 MySQL 示例
  mail.conf.example       邮件服务示例
archive/                   未另行配置时的本地存储目录
```

## 准备备份机

推荐 Ubuntu 22.04/24.04 或 Debian 12：

```bash
sudo apt update
sudo apt install -y openssh-client gzip coreutils findutils util-linux
chmod +x backup.sh
cp backup.conf.example backup.conf
```

编辑 `backup.conf`，将 `BACKUP_ROOT` 指向 2T 硬盘的实际挂载点：

```bash
BACKUP_ROOT="/mnt/backup-disk/server-archives"
DEFAULT_RETENTION_COUNT="100"
```

确保硬盘已经挂载，并且运行脚本的账号可写：

```bash
findmnt /mnt/backup-disk
mkdir -p /mnt/backup-disk/server-archives
```

不要只凭目录存在判断硬盘已挂载，否则挂载失败时可能把归档写满系统盘。生产环境可在 systemd 服务中添加：

```ini
RequiresMountsFor=/mnt/backup-disk
```

## SSH 配置

在备份机生成专用密钥：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/backup_ed25519
ssh-copy-id -i ~/.ssh/backup_ed25519.pub backup@server.example.com
```

先手动连接一次，确认主机指纹并写入 `known_hosts`：

```bash
ssh -i ~/.ssh/backup_ed25519 backup@server.example.com
```

定时任务使用 `BatchMode`，不会卡在密码提示。远端账号需要有权读取配置中的所有源路径，并且需要安装 Bash、GNU tar 和 gzip：

```bash
sudo apt install -y bash tar gzip
```

建议为备份建立只读、低权限账号。不要为了方便直接开放 root SSH 登录。

## 添加任务

示例文件后缀为 `.example`，不会执行。复制并编辑后才会启用：

```bash
cp jobs.d/minecraft.conf.example jobs.d/minecraft.conf
nano jobs.d/minecraft.conf
```

基本任务：

```bash
JOB_NAME="minecraft-main"
REMOTE_HOST="mc.example.com"
REMOTE_USER="backup"
REMOTE_PORT="22"
SSH_KEY="$HOME/.ssh/backup_ed25519"

SOURCE_PATHS=(
  "/srv/minecraft/world"
  "/srv/minecraft/server.properties"
)

EXCLUDE_PATTERNS=("*.tmp" "*/cache/*")
RETENTION_COUNT="100"
```

常用字段：

- `JOB_NAME`：任务名，也是本地目录及归档文件名前缀，必须唯一。
- `REMOTE_HOST`、`REMOTE_USER`、`REMOTE_PORT`：远端 SSH 信息。
- `SSH_KEY`：备份机上的私钥路径。
- `SOURCE_PATHS`：要归档的远端绝对路径数组。
- `EXCLUDE_PATTERNS`：传给 GNU tar 的排除规则数组。
- `BACKUP_SUBDIR`：可选的本地子目录；默认使用 `JOB_NAME`。
- `RETENTION_COUNT`：保留最新多少份；`0` 表示不按数量清理。
- `COMPRESSION_LEVEL`：gzip 压缩级别 1–9，默认 6。
- `TRANSFER_MODE`：`mirror` 使用 rsync 断点续传和增量同步；`stream` 使用旧版远端压缩流。
- `PARALLEL_TRANSFERS`：同一目录使用多少条 SSH/rsync 连接并行下载，范围 1–16；跨地区建议先用 4。
- `REMOTE_PRE_COMMAND`、`REMOTE_POST_COMMAND`：可选的远端前置和清理命令。

配置文件是 Bash 文件，可以使用 `$HOME`，但请勿放入来源不可信的代码。真实配置和密钥不会被 Git 跟踪。

`mirror` 模式会在 `$BACKUP_ROOT/.staging/任务名` 保留一份最新文件镜像。首次运行需要传输全部数据；中断后再次运行会继续未完成文件，之后通常只传输新增或变化的文件。镜像同步完成后仍会生成一份完整 `tar.gz` 归档。

并行模式会取得远端文件清单，将文件分成多个队列，再同时启动多条 SSH 连接；全部完成后还会进行一次目录和删除项核对。因此它不会让多个进程同时删除同一目录。并发对大量文件、跨地区高延迟链路最有效；单个超大文件仍由一条 rsync 连接传输。建议从 4 开始，只有远端和备份盘负载较低时再尝试 8，通常不建议直接使用 16。

容量规划时需要计算“一份最新镜像 + 所有保留归档”。例如 26GB 且不易压缩的附件，保留 30 份可能占用约 806GB。建议按照硬盘空间设置合理的 `RETENTION_COUNT`。

如因特殊环境必须使用 SSH 密码，可在任务中设置 `SSH_PASSWORD_FILE` 并在备份机安装 `sshpass`；密码文件应执行 `chmod 600`。SSH 密钥仍是首选。

## 数据库和动态服务

单纯打包正在写入的数据库文件通常无法保证可恢复。博客应先调用数据库自身的导出工具，再把导出文件与站点文件一起归档：

```bash
SOURCE_PATHS=("/var/www/my-blog" "/tmp/my-blog.sql")
REMOTE_PRE_COMMAND='mysqldump --defaults-extra-file=$HOME/.my-backup.cnf my_blog > /tmp/my-blog.sql'
REMOTE_POST_COMMAND='rm -f /tmp/my-blog.sql'
```

PostgreSQL 可使用 `pg_dump`。大型数据库更适合快照或专用增量备份工具，而不是每次完整压缩。

邮件目录和 Minecraft 世界也可能在归档期间变化。重要服务推荐先使用服务自身的快照/暂停写入机制：例如 Minecraft 在前置命令中执行保存并暂停写盘，归档后再恢复；邮件系统可优先归档存储快照。脚本遇到 tar 报错会把该任务视为失败，不会把不完整文件冒充成功归档。

## 运行和验证

列出任务：

```bash
./backup.sh --list
```

只运行一个任务：

```bash
./backup.sh --job my-blog
```

运行全部任务：

```bash
./backup.sh
```

归档结果：

```text
/mnt/backup-disk/server-archives/
  my-blog/
    my-blog_20260620T083000Z.tar.gz
    my-blog_20260620T083000Z.tar.gz.sha256
  mail-server/
    mail-server_20260620T090000Z.tar.gz
    mail-server_20260620T090000Z.tar.gz.sha256
```

手动验证和查看内容：

```bash
cd /mnt/backup-disk/server-archives/my-blog
sha256sum -c my-blog_20260620T083000Z.tar.gz.sha256
tar -tzf my-blog_20260620T083000Z.tar.gz | head
```

## 定时运行

安装版用户推荐直接运行 `sudo backupctl` 并选择菜单 `5`。菜单会为每个任务创建独立的 `server-archive-backup@任务名.timer`，因此不同任务可以使用不同周期。若多个任务恰好同时触发，它们会排队执行，最长等待一天，而不会互相抢占备份盘和网络。

全局定时器 `server-archive-backup.timer` 会一次运行所有任务。开始使用单任务定时器时，菜单会询问是否禁用全局定时器，避免同一任务重复备份。

### Cron

每天凌晨 03:15 执行：

```cron
15 3 * * * /absolute/path/backup.sh >> /absolute/path/backup.log 2>&1
```

### Systemd（更推荐）

`/etc/systemd/system/server-archive-backup.service`：

```ini
[Unit]
Description=Archive remote servers to backup disk
RequiresMountsFor=/mnt/backup-disk
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=backup
WorkingDirectory=/absolute/path/to/project
ExecStart=/absolute/path/to/project/backup.sh
```

`/etc/systemd/system/server-archive-backup.timer`：

```ini
[Unit]
Description=Run server archive backup daily

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
```

启用：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now server-archive-backup.timer
systemctl list-timers server-archive-backup.timer
```

## 恢复

先在临时目录验证，不建议直接覆盖线上文件：

```bash
mkdir /tmp/restore-test
tar -xzf my-blog_20260620T083000Z.tar.gz -C /tmp/restore-test
```

归档内部保存的是去掉开头 `/` 的路径，例如 `/var/www/my-blog` 会显示为 `var/www/my-blog`。确认文件后再使用 `rsync` 或服务自身的恢复工具还原。

备份只有在成功做过恢复演练后才真正可信。建议定期抽查 SHA-256、解压测试，并至少保留一份不与这块 2T 硬盘同机的副本以应对硬盘损坏或整机事故。
