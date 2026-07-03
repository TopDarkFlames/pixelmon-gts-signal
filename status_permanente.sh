#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Serviço Pixelmon GTS ==="
systemctl --user status pixelmon-gts.service --no-pager || true
echo
echo "=== Tailscale Funnel ==="
tailscale funnel status || true
echo
echo "=== Link fixo no Discord ==="
if [[ -f "$ROOT_DIR/runtime/permanent_access_url.txt" ]]; then
  cat "$ROOT_DIR/runtime/permanent_access_url.txt"
else
  echo "Link fixo ainda não gerado."
fi
echo
echo "=== URL web atual ==="
if [[ -f "$ROOT_DIR/runtime/site_url.txt" ]]; then
  cat "$ROOT_DIR/runtime/site_url.txt"
else
  echo "URL ainda não gerada."
fi
echo
echo "=== Últimos eventos ==="
journalctl --user -u pixelmon-gts.service -n 20 --no-pager || true
