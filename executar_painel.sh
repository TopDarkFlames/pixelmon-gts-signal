#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

env_value() {
  local key="$1"
  local fallback="$2"
  local value=""
  if [[ -n "${!key:-}" ]]; then
    value="${!key}"
  elif [[ -f .env ]]; then
    value="$(awk -v key="$key" -F= '$1 == key { print substr($0, index($0, "=") + 1) }' .env | tail -n 1)"
  fi
  printf '%s\n' "${value:-$fallback}"
}

RUBY_ABI="$(ruby -e 'print RbConfig::CONFIG.fetch("ruby_version")')"
GEM_ROOT="$ROOT_DIR/vendor/bundle/ruby/$RUBY_ABI"
PUMA_BIN="$(find "$GEM_ROOT/gems" -path '*/puma-*/bin/puma' -type f | sort -V | tail -n 1)"
PANEL_HOST="$(env_value PANEL_HOST 127.0.0.1)"
PANEL_PORT="$(env_value PANEL_PORT 8080)"

if [[ -z "$PUMA_BIN" ]]; then
  echo "Puma não encontrado. Rode: bundle install" >&2
  exit 1
fi

export GEM_HOME="$GEM_ROOT"
export GEM_PATH="$GEM_ROOT:/usr/lib/ruby/gems/$RUBY_ABI"

exec ruby "$PUMA_BIN" --bind "tcp://$PANEL_HOST:$PANEL_PORT" --threads 2:8 config.ru
