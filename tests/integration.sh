#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export REPO_ROOT TEST_ROOT
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export PATH="$REPO_ROOT/tests/bin:$PATH"
export BACKUP_CONFIG="$REPO_ROOT/tests/fixtures/backup.conf"
chmod +x "$REPO_ROOT/tests/bin/ssh" "$REPO_ROOT/tests/bin/flock" "$REPO_ROOT/tests/bin/rsync"
mkdir -p "$TEST_ROOT/source"

printf 'version-one\n' > "$TEST_ROOT/source/data.txt"
printf 'ignored\n' > "$TEST_ROOT/source/cache.tmp"
"$REPO_ROOT/backup.sh" --job integration

sleep 1
"$REPO_ROOT/backup.sh" --job integration
[[ "$(find "$TEST_ROOT/archive/integration" -name '*.tar.gz' | wc -l)" -eq 1 ]]

sleep 1
printf 'version-two\n' > "$TEST_ROOT/source/data.txt"
"$REPO_ROOT/backup.sh" --job integration

sleep 1
printf 'version-three\n' > "$TEST_ROOT/source/data.txt"
"$REPO_ROOT/backup.sh" --job integration

[[ "$(find "$TEST_ROOT/archive/integration" -name '*.tar.gz' | wc -l)" -eq 2 ]]
[[ "$(find "$TEST_ROOT/archive/integration" -name '*.sha256' | wc -l)" -eq 2 ]]
! tar -tzf "$(find "$TEST_ROOT/archive/integration" -name '*.tar.gz' | head -n 1)" | grep -q 'cache.tmp'

# Mirror mode keeps partial rsync state after a simulated disconnect and succeeds on retry.
touch "$TEST_ROOT/fail-rsync-once"
if "$REPO_ROOT/backup.sh" --job mirror; then
  echo "mirror mode should have reported the simulated disconnect" >&2
  exit 1
fi
[[ -f "$TEST_ROOT/archive/.staging/mirror/${TEST_ROOT#/}/source/.rsync-partial/interrupted" ]]
"$REPO_ROOT/backup.sh" --job mirror
[[ "$(find "$TEST_ROOT/archive/mirror" -name '*.tar.gz' | wc -l)" -eq 1 ]]
gzip -t "$(find "$TEST_ROOT/archive/mirror" -name '*.tar.gz' | head -n 1)"

# Parallel mirror mode partitions one directory across multiple rsync workers.
rm -f -- "$TEST_ROOT/rsync-workers.log"
for number in 1 2 3 4 5 6 7 8; do
  printf 'parallel-%s\n' "$number" > "$TEST_ROOT/source/parallel-$number.txt"
done
"$REPO_ROOT/backup.sh" --job parallel
[[ "$(sort -u "$TEST_ROOT/rsync-workers.log" | wc -l)" -eq 4 ]]
[[ "$(find "$TEST_ROOT/archive/.staging/parallel" -name 'parallel-*.txt' | wc -l)" -eq 8 ]]
gzip -t "$(find "$TEST_ROOT/archive/parallel" -name '*.tar.gz' | head -n 1)"

printf 'integration test: OK\n'
