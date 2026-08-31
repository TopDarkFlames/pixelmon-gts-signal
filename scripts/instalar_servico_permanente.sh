#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="pixelmon-gts.service"
USER_SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_PATH="$USER_SERVICE_DIR/$SERVICE_NAME"

for command in tailscale tailscaled systemctl loginctl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Comando não encontrado: $command" >&2
    exit 1
  }
done

echo "1/6 Ativando o daemon Tailscale no boot..."
sudo systemctl enable --now tailscaled

echo "2/6 Conectando sua máquina ao Tailscale..."
if tailscale status >/dev/null 2>&1; then
  sudo tailscale set --operator="$USER"
else
  sudo tailscale up --operator="$USER" --hostname=pixelmon-gts
fi

echo "3/6 Habilitando a URL HTTPS permanente..."
funnel_output="$(tailscale funnel --bg 8080 2>&1 || true)"
printf '%s\n' "$funnel_output"
if grep -qiE 'not enabled|contact your administrator' <<<"$funnel_output"; then
  echo "Aviso: o administrador da tailnet ainda não liberou Funnel."
  echo "O serviço usará Cloudflare automaticamente até essa liberação."
fi

echo "4/6 Instalando serviço do Pixelmon GTS..."
mkdir -p "$USER_SERVICE_DIR"
sed "s|__PROJECT_DIR__|$ROOT_DIR|g" "$ROOT_DIR/systemd/pixelmon-gts.service" >"$SERVICE_PATH"
chmod 600 "$SERVICE_PATH"

echo "5/6 Permitindo que o serviço inicie antes do login gráfico..."
sudo loginctl enable-linger "$USER"

echo "6/6 Instalando o serviço para controle manual pelo launcher..."
systemctl --user daemon-reload
systemctl --user disable "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true

echo
echo "Instalação concluída. O serviço não iniciará mais automaticamente."
echo "Abra o launcher em:"
echo "  $ROOT_DIR/scripts/abrir_launcher.sh"
echo
echo "Ou instale o atalho no menu:"
echo "  mkdir -p ~/.local/share/applications && cp '$ROOT_DIR/pixelmon-gts-launcher.desktop' ~/.local/share/applications/"
echo
echo "Para consultar o serviço manualmente:"
echo "  systemctl --user status $SERVICE_NAME"
