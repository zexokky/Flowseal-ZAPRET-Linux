#!/usr/bin/env bash
# Installs dependencies and builds nfqws from bol-van/zapret.
# Usage: sudo ./install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BIN="$ROOT/bin"
SRC="$ROOT/.build/zapret"
ZAPRET_REPO="https://github.com/bol-van/zapret.git"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

echo "==> Installing packages (apt)..."
apt-get update
apt-get install -y build-essential git curl nftables \
    libnetfilter-queue-dev libnfnetlink-dev libmnl-dev zlib1g-dev libcap-dev

echo "==> Downloading zapret sources..."
mkdir -p "$(dirname "$SRC")"
if [[ -d "$SRC/.git" ]]; then
    git -C "$SRC" pull --ff-only
else
    git clone --depth 1 "$ZAPRET_REPO" "$SRC"
fi

echo "==> Building nfqws..."
make -C "$SRC/nfq" clean >/dev/null 2>&1 || true
make -C "$SRC/nfq"
install -m 755 "$SRC/nfq/nfqws" "$BIN/nfqws"

echo "==> Converting lists to Unix line endings..."
for f in "$ROOT"/lists/*.txt "$ROOT"/lists/*.backup "$ROOT"/utils/targets.txt; do
    [[ -f "$f" ]] && sed -i 's/\r$//' "$f"
done

chmod +x "$ROOT"/zapret.sh

echo
"$BIN/nfqws" --version 2>/dev/null | head -1 || true
echo "Done. nfqws installed to: $BIN/nfqws"
echo
echo "Next steps:"
echo "  sudo ./zapret.sh start general      # run a strategy"
echo "  sudo ./zapret.sh                    # open the service menu"
