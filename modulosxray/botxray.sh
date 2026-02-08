#!/bin/bash
# botxray.sh - Instalador Automatizado (DragonCore V7.7 FIX)
# - Usa venv (não quebra system python)
# - Cria usuário dedicado (não roda como root)
# - curl -fsSL
# - substituição segura de token/admin

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; read -rp "Enter...";' ERR

REPO_BASE="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main"

VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

ensure_pkg() {
  local bin="$1" pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "$pkg" >/dev/null 2>&1
  fi
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${VERMELHO}❌ Execute como root!${RESET}"
    exit 1
  fi
}

require_root

clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}      🤖 CONFIGURAÇÃO DO BOT TELEGRAM 🤖       ${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""

echo "Preparando ambiente..."
ensure_pkg python3 python3
ensure_pkg pip3 python3-pip
ensure_pkg curl curl
ensure_pkg python3-venv python3-venv

mkdir -p /opt/XrayTools

echo ""
echo -e "${AMARELO}1. Digite o Token do BotFather:${RESET}"
read -r -p "Token: " bot_token

echo ""
echo -e "${AMARELO}2. Digite o SEU ID Numérico (Admin):${RESET}"
read -r -p "ID Admin: " admin_id

if [ -z "${bot_token:-}" ] || [ -z "${admin_id:-}" ]; then
  echo -e "${VERMELHO}❌ Dados incompletos!${RESET}"
  sleep 2
  exit 1
fi

if ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
  echo -e "${VERMELHO}❌ ID Admin inválido (deve ser numérico).${RESET}"
  sleep 2
  exit 1
fi

echo ""
echo "Baixando bot..."
curl -fsSL -o /opt/XrayTools/botxray.py "$REPO_BASE/botxray.py"

if [ ! -s "/opt/XrayTools/botxray.py" ]; then
  echo -e "${VERMELHO}Erro ao baixar botxray.py do GitHub!${RESET}"
  exit 1
fi

# Substituição segura via python (evita problemas de sed)
python3 - <<PY
from pathlib import Path
p = Path("/opt/XrayTools/botxray.py")
s = p.read_text(encoding="utf-8", errors="ignore")
s = s.replace("SEU_TOKEN_AQUI", ${bot_token!r})
s = s.replace("123456789", str(${admin_id}))
p.write_text(s, encoding="utf-8")
PY

# Usuário dedicado pro bot
if ! id -u botxray >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin botxray
fi

chown -R botxray:botxray /opt/XrayTools

# venv isolado
if [ ! -d /opt/XrayTools/venv ]; then
  python3 -m venv /opt/XrayTools/venv
fi

/opt/XrayTools/venv/bin/pip install -U pip >/dev/null 2>&1
/opt/XrayTools/venv/bin/pip install -U python-telegram-bot requests >/dev/null 2>&1

# Service systemd com hardening básico
cat > /etc/systemd/system/botxray.service <<'EOF'
[Unit]
Description=DragonCore Telegram Bot
After=network.target

[Service]
Type=simple
User=botxray
Group=botxray
WorkingDirectory=/opt/XrayTools
ExecStart=/opt/XrayTools/venv/bin/python /opt/XrayTools/botxray.py
Restart=always
RestartSec=10

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/XrayTools
# Se o bot precisar ler configs do xray, libere só leitura:
ReadOnlyPaths=/usr/local/etc/xray /opt/DragonCoreSSL /opt/XrayTools

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable botxray >/dev/null 2>&1 || true
systemctl restart botxray >/dev/null 2>&1 || true

echo ""
echo -e "${VERDE}🤖 BOT ATIVADO COM SUCESSO!${RESET}"
echo "Vá no Telegram e digite /menu ou /start."
echo ""
read -rp "Pressione ENTER para voltar..."
