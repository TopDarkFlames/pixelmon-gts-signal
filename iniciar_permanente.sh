#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

RUNTIME_DIR="$ROOT_DIR/runtime"
mkdir -p "$RUNTIME_DIR"

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

need_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Comando não encontrado: $1" >&2
    exit 1
  }
}

rotate_log() {
  local path="$1"
  if [[ -f "$path" ]] && (( $(stat -c %s "$path") > 5242880 )); then
    mv -f "$path" "$path.1"
  fi
}

backup_database() {
  local configured_path
  local database_path
  local backup_dir="$RUNTIME_DIR/backups"
  local retention_days
  local backup_path

  configured_path="$(env_value PANEL_DB_PATH access_panel.db)"
  if [[ "$configured_path" = /* ]]; then
    database_path="$configured_path"
  else
    database_path="$ROOT_DIR/$configured_path"
  fi
  [[ -f "$database_path" ]] || return 0

  retention_days="$(env_value PANEL_BACKUP_RETENTION_DAYS 14)"
  [[ "$retention_days" =~ ^[0-9]+$ ]] || retention_days=14
  mkdir -p "$backup_dir"
  backup_path="$backup_dir/access_panel-$(date +%Y%m%d-%H%M%S).db"
  sqlite3 "$database_path" ".backup '$backup_path'"
  find "$backup_dir" -type f -name 'access_panel-*.db' -mtime "+$retention_days" -delete
  echo "Backup SQLite criado: $backup_path"
}

extract_funnel_url() {
  tailscale funnel status --json 2>/dev/null | python3 -c '
import json, re, sys

def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

for value in strings(data):
    match = re.search(r"https://[A-Za-z0-9.-]+\.ts\.net", value)
    if match:
        print(match.group(0))
        break
else:
    raise SystemExit(1)
'
}

wait_for_panel() {
  echo "Aguardando painel em $PANEL_URL..."
  for _ in $(seq 1 120); do
    if python3 - "$PANEL_URL/health" <<'PY' >/dev/null 2>&1
import sys
import urllib.request

try:
    body = urllib.request.urlopen(sys.argv[1], timeout=2).read().decode()
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if body.strip() == "ok" else 1)
PY
    then
      echo "Painel online."
      return 0
    fi
    sleep 0.5
  done
  echo "Painel não respondeu." >&2
  tail -n 60 "$PANEL_LOG" >&2 || true
  return 1
}

wait_for_tailscale() {
  echo "Aguardando Tailscale conectar..."
  for _ in $(seq 1 20); do
    if tailscale status >/dev/null 2>&1; then
      echo "Tailscale conectado."
      return 0
    fi
    sleep 1
  done
  echo "Tailscale não conectado. Execute o instalador novamente em um terminal." >&2
  return 1
}

configure_funnel() {
  echo "Configurando Funnel permanente..."
  if ! tailscale funnel --bg --yes "$PANEL_PORT" >"$FUNNEL_LOG" 2>&1; then
    echo "Falha ao configurar Tailscale Funnel:" >&2
    tail -n 60 "$FUNNEL_LOG" >&2 || true
    return 1
  fi
  if grep -qiE 'not enabled|contact your administrator|error|denied' "$FUNNEL_LOG"; then
    echo "Funnel indisponível nesta tailnet; usando Cloudflare como contingência."
    return 1
  fi

  local url=""
  for _ in $(seq 1 60); do
    url="$(extract_funnel_url || true)"
    [[ -n "$url" ]] && break
    sleep 0.5
  done
  if [[ -z "$url" ]]; then
    url="$(grep -Eo 'https://[A-Za-z0-9.-]+\.ts\.net' "$FUNNEL_LOG" | head -n 1 || true)"
  fi
  if [[ -z "$url" ]]; then
    url="$(tailscale funnel status 2>/dev/null | grep -Eo 'https://[A-Za-z0-9.-]+\.ts\.net' | head -n 1 || true)"
  fi
  if [[ -z "$url" ]]; then
    echo "Funnel foi configurado, mas não consegui descobrir a URL." >&2
    tailscale funnel status >&2 || true
    return 1
  fi

  printf '%s\n' "$url" >"$SITE_URL_FILE"
  echo "Site permanente: $url"
  write_tunnel_status online "$url"
  announce_site "$url"
}

announce_site() {
  local url="$1"
  if python3 -u gts_dm_bot.py --announce-site "$url" >"$ANNOUNCE_LOG" 2>&1; then
    echo "Mensagem oficial atualizada no Discord e URL enviada ao Telegram."
  else
    echo "Falha ao anunciar URL:" >&2
    tail -n 60 "$ANNOUNCE_LOG" >&2 || true
  fi
}

announce_site_unavailable() {
  local reason="$1"
  if python3 -u gts_dm_bot.py --announce-site-unavailable "$reason" >"$ANNOUNCE_LOG" 2>&1; then
    echo "Mensagem oficial marcada como reconectando."
  else
    echo "Falha ao marcar URL como reconectando:" >&2
    tail -n 60 "$ANNOUNCE_LOG" >&2 || true
  fi
}

write_tunnel_status() {
  local status="$1"
  local detail="$2"
  printf '%s\t%s\t%s\n' "$status" "$(date +%s)" "$detail" >"$TUNNEL_STATUS_FILE"
}

cloudflare_retry_seconds() {
  local seconds
  seconds="$(env_value CLOUDFLARE_RETRY_SECONDS 300)"
  [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=300
  (( seconds >= 30 )) || seconds=30
  printf '%s\n' "$seconds"
}

public_health_ok() {
  local url="$1"
  python3 - "$url/health" <<'PY' >/dev/null 2>&1
import sys
import urllib.request

try:
    body = urllib.request.urlopen(sys.argv[1], timeout=8).read().decode()
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if body.strip() == "ok" else 1)
PY
}

mark_tunnel_offline() {
  local reason="$1"
  rm -f "$SITE_URL_FILE"
  write_tunnel_status offline "$reason"
  announce_site_unavailable "$reason"
}

cloudflare_manager_loop() {
  local retry_seconds
  local tunnel_pid=""
  local url=""
  local health_failures=0
  retry_seconds="$(cloudflare_retry_seconds)"

  cleanup_cloudflare_child() {
    if [[ -n "${tunnel_pid:-}" ]]; then
      kill "$tunnel_pid" >/dev/null 2>&1 || true
      wait "$tunnel_pid" >/dev/null 2>&1 || true
      tunnel_pid=""
    fi
  }
  trap cleanup_cloudflare_child INT TERM EXIT

  while true; do
    : >"$CLOUDFLARE_LOG"
    echo "Iniciando Cloudflare Quick Tunnel como contingência..."
    cloudflared tunnel --url "$PANEL_URL" >>"$CLOUDFLARE_LOG" 2>&1 &
    tunnel_pid="$!"
    url=""

    for _ in $(seq 1 120); do
      url="$(grep -Eo 'https://[A-Za-z0-9-]+\.trycloudflare\.com' "$CLOUDFLARE_LOG" | tail -n 1 || true)"
      [[ -n "$url" ]] && break
      if ! kill -0 "$tunnel_pid" >/dev/null 2>&1; then
        wait "$tunnel_pid" >/dev/null 2>&1 || true
        break
      fi
      sleep 0.5
    done

    if [[ -z "$url" ]]; then
      cleanup_cloudflare_child
      local reason="Cloudflare ainda não liberou URL pública; nova tentativa em ${retry_seconds}s."
      echo "$reason" >&2
      tail -n 60 "$CLOUDFLARE_LOG" >&2 || true
      mark_tunnel_offline "$reason"
      sleep "$retry_seconds"
      continue
    fi

    printf '%s\n' "$url" >"$SITE_URL_FILE"
    write_tunnel_status online "$url"
    echo "Site público temporário: $url"
    announce_site "$url"

    health_failures=0
    while kill -0 "$tunnel_pid" >/dev/null 2>&1; do
      sleep 30
      if public_health_ok "$url"; then
        health_failures=0
      else
        health_failures=$((health_failures + 1))
        echo "Falha de health-check público ($health_failures/3): $url" >&2
      fi

      if (( health_failures >= 3 )); then
        echo "Túnel público ficou indisponível; reiniciando apenas o Cloudflare." >&2
        cleanup_cloudflare_child
        break
      fi
    done

    wait "$tunnel_pid" >/dev/null 2>&1 || true
    tunnel_pid=""
    local reason="Túnel Cloudflare caiu; nova tentativa em ${retry_seconds}s."
    mark_tunnel_offline "$reason"
    sleep "$retry_seconds"
  done
}

start_process() {
  local name="$1"
  local logfile="$2"
  shift 2
  echo "Iniciando $name..."
  "$@" >>"$logfile" 2>&1 &
  PIDS+=("$!")
  NAMES+=("$name")
  LOGS+=("$logfile")
}

cleanup() {
  local code=$?
  trap - INT TERM EXIT
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  for pid in "${PIDS[@]:-}"; do
    wait "$pid" >/dev/null 2>&1 || true
  done
  exit "$code"
}

monitor_processes() {
  while true; do
    for i in "${!PIDS[@]}"; do
      if ! kill -0 "${PIDS[$i]}" >/dev/null 2>&1; then
        echo "Processo parou: ${NAMES[$i]}" >&2
        tail -n 60 "${LOGS[$i]}" >&2 || true
        return 1
      fi
    done
    sleep 3
  done
}

main() {
  need_command python3
  need_command ruby
  need_command tailscale
  need_command cloudflared
  need_command flock
  need_command sqlite3

  exec 9>"$RUNTIME_DIR/permanent.lock"
  if ! flock -n 9; then
    echo "O serviço Pixelmon GTS já está rodando." >&2
    exit 1
  fi

  PANEL_HOST="$(env_value PANEL_HOST 127.0.0.1)"
  PANEL_PORT="$(env_value PANEL_PORT 8080)"
  PANEL_URL="http://$PANEL_HOST:$PANEL_PORT"
  PANEL_LOG="$RUNTIME_DIR/painel-permanente.log"
  BOT_LOG="$RUNTIME_DIR/gts-bot-permanente.log"
  FUNNEL_LOG="$RUNTIME_DIR/tailscale-funnel.log"
  CLOUDFLARE_LOG="$RUNTIME_DIR/cloudflare-contingencia.log"
  ANNOUNCE_LOG="$RUNTIME_DIR/anuncio-site-permanente.log"
  SITE_URL_FILE="$RUNTIME_DIR/site_url.txt"
  TUNNEL_STATUS_FILE="$RUNTIME_DIR/tunnel_status.txt"

  backup_database

  for log in "$PANEL_LOG" "$BOT_LOG" "$FUNNEL_LOG" "$CLOUDFLARE_LOG" "$ANNOUNCE_LOG"; do
    rotate_log "$log"
  done

  PIDS=()
  NAMES=()
  LOGS=()
  trap cleanup INT TERM EXIT

  start_process "painel Ruby" "$PANEL_LOG" ./executar_painel.sh
  wait_for_panel
  start_process "bot GTS" "$BOT_LOG" python3 -u gts_dm_bot.py

  if wait_for_tailscale && configure_funnel; then
    echo "Hospedagem permanente ativa via Tailscale Funnel."
  else
    start_process "gerenciador Cloudflare" "$CLOUDFLARE_LOG" cloudflare_manager_loop
  fi

  echo "Pixelmon GTS permanente está online."
  monitor_processes
}

main "$@"
