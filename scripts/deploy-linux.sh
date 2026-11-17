#!/bin/bash
# Deploy from a Linux machine on the iPad's LAN when the Mac build host cannot reach the iPad.
# Syncs the tree to the Mac, builds there (scripts/build.sh), pulls the binary back, then pushes,
# signs and swaps it on the iPad over sshpass. Keeps the previous binary as pi5mon.bak-<date>.
# Env: IPAD_PASS (required), IPAD_HOST (default 192.168.0.139),
#      BUILD_HOST (default server@server), BUILD_DIR (default pi5mon-build, relative to its home).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${IPAD_PASS:?set IPAD_PASS (iPad root password)}"
IPAD_HOST="${IPAD_HOST:-192.168.0.139}"
BUILD_HOST="${BUILD_HOST:-server@server}"
BUILD_DIR="${BUILD_DIR:-pi5mon-build}"
O=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=10)
export SSHPASS="$IPAD_PASS"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

rsync -a --delete --exclude .git --exclude native/pi5mon --exclude native/index_gz.h --exclude '*.o' \
  "$ROOT/" "$BUILD_HOST:$BUILD_DIR/"
ssh "$BUILD_HOST" "cd $BUILD_DIR && ./scripts/build.sh" >/dev/null
scp -q "$BUILD_HOST:$BUILD_DIR/native/pi5mon" "$BUILD_HOST:$BUILD_DIR/native/index_gz.h" "$TMP/"
ETAG=$(grep INDEX_ETAG "$TMP/index_gz.h" | cut -d'"' -f2)

sshpass -e scp -O "${O[@]}" "$TMP/pi5mon" "root@$IPAD_HOST:/var/root/pi5monitor/pi5mon.new"
sshpass -e ssh "${O[@]}" "root@$IPAD_HOST" "cd /var/root/pi5monitor && cp -p pi5mon pi5mon.bak-$(date +%Y%m%d) && ldid -S pi5mon.new && mv pi5mon.new pi5mon && { killall -9 pi5mon 2>/dev/null; true; }"

# The daemon listens on the iPad's loopback only: check the served ETag through a tunnel.
sshpass -e ssh "${O[@]}" -o ExitOnForwardFailure=yes -L 18899:127.0.0.1:8899 -N "root@$IPAD_HOST" & TUN=$!
trap 'kill $TUN 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in 1 2 3 4 5; do sleep 1; GOT=$(curl -s -m5 -D- -o /dev/null http://127.0.0.1:18899/ | grep -i '^etag' | cut -d'"' -f2) && [ -n "$GOT" ] && break; done
[ "${GOT:-}" = "$ETAG" ] || { echo "deployed binary serves ETag '${GOT:-none}', expected $ETAG"; exit 1; }
echo "deployed $ETAG"
