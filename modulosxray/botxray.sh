#!/bin/bash
# botxray.sh - Instalador Completo (SAFE) com venv + sudoers + backup

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

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo -e "${VERMELHO}❌ Execute como root!${RESET}"
  exit 1
fi

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
ensure_pkg jq jq
ensure_pkg sudo sudo

mkdir -p /opt/XrayTools

echo ""
echo -e "${AMARELO}1. Digite o Token do BotFather:${RESET}"
read -r -p "Token: " bot_token

echo ""
echo -e "${AMARELO}2. Digite o SEU ID Numérico (Admin):${RESET}"
read -r -p "ID Admin: " admin_id

if [ -z "${bot_token:-}" ] || [ -z "${admin_id:-}" ] || ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
  echo -e "${VERMELHO}❌ Dados inválidos/incompletos!${RESET}"
  exit 1
fi

# cria usuário do bot
if ! id -u botxray >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin botxray
fi

# baixa bot
echo ""
echo "Baixando bot..."
curl -fsSL -o /opt/XrayTools/botxray.py "$REPO_BASE/botxray.py"
if [ ! -s /opt/XrayTools/botxray.py ]; then
  echo -e "${VERMELHO}Erro ao baixar botxray.py.${RESET}"
  exit 1
fi

# substitui token/admin com segurança
python3 - <<PY
from pathlib import Path
p = Path("/opt/XrayTools/botxray.py")
s = p.read_text(encoding="utf-8", errors="ignore")
s = s.replace("SEU_TOKEN_AQUI", ${bot_token!r})
s = s.replace("123456789", str(${admin_id}))
p.write_text(s, encoding="utf-8")
PY

# venv isolado
if [ ! -d /opt/XrayTools/venv ]; then
  python3 -m venv /opt/XrayTools/venv
fi
/opt/XrayTools/venv/bin/pip install -U pip >/dev/null 2>&1
/opt/XrayTools/venv/bin/pip install -U python-telegram-bot requests >/dev/null 2>&1

# script de backup do bot (se não existir, cria)
if [ ! -f /usr/local/bin/backup_bot.sh ]; then
cat > /usr/local/bin/backup_bot.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail
OUT_DIR="/opt/XrayTools/backups"
mkdir -p "$OUT_DIR"
ts="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${OUT_DIR}/backup_dragoncore_${ts}.tar.gz"
tar -czf "$OUT_FILE" /opt/XrayTools /usr/local/etc/xray /opt/DragonCoreSSL >/dev/null 2>&1 || { echo "ERROR"; exit 1; }
chown botxray:botxray "$OUT_FILE" 2>/dev/null || true
chmod 640 "$OUT_FILE" 2>/dev/null || true
echo "$OUT_FILE"
EOF
chmod +x /usr/local/bin/backup_bot.sh
fi

# sudoers restrito: permite somente os scripts do painel + backup do bot
cat > /etc/sudoers.d/botxray <<'EOF'
Defaults:botxray !requiretty
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/add_user.sh
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/remover_user.sh
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/block_user.sh
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/unblock_user.sh
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/backup_bot.sh
EOF
chmod 440 /etc/sudoers.d/botxray
visudo -cf /etc/sudoers.d/botxray >/dev/null

# permissões do diretório do bot
mkdir -p /opt/XrayTools/backups
chown -R botxray:botxray /opt/XrayTools
chmod 750 /opt/XrayTools
chmod 750 /opt/XrayTools/backups

# bot precisa ler config/users para listar/gerar link:
# coloca bot no grupo xray (se você já mudou xray.service para User=xray)
groupadd --system xray 2>/dev/null || true
usermod -aG xray botxray 2>/dev/null || true

# tenta ajustar grupos/perms de leitura (não quebra se falhar)
chgrp -R xray /usr/local/etc/xray 2>/dev/null || true
chmod 750 /usr/local/etc/xray 2>/dev/null || true
chmod 640 /usr/local/etc/xray/config.json 2>/dev/null || true

# service systemd hardened
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

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/XrayTools
ReadOnlyPaths=/usr/local/etc/xray /opt/DragonCoreSSL

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable botxray >/dev/null 2>&1 || true
systemctl restart botxray >/dev/null 2>&1 || true

echo ""
echo -e "${VERDE}🤖 BOT ATIVADO COM SUCESSO!${RESET}"
echo "Teste no Telegram: /start ou /menu"
echo ""
systemctl status botxray --no-pager | sed -n '1,20p'
echo ""
read -rp "Pressione ENTER para voltar..."
