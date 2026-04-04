#!/bin/bash
# botxray.sh - Instalador do Bot Telegram V7.5.3
# Correções: Recriação do .bot_env (alinhado com o botxray.py atualizado) e proteção do status.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; read -rp "Enter para continuar...";' ERR

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main}"
LOG_FILE="/tmp/botxray_install.log"

VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- DETECÇÃO DE DISTRO ---
_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${VERMELHO}❌ Gerenciador de pacotes não detectado.${RESET}"; exit 1; fi
}

ensure_pkg() {
    local bin="$1" pkg="$2"
    command -v "$bin" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >>"$LOG_FILE" 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${VERMELHO}❌ Execute como root!${RESET}"
    exit 1
fi

: > "$LOG_FILE"

clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}      BOT TELEGRAM - DRAGONCORE V7.5           ${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""

echo "Preparando ambiente..."
ensure_pkg python3        python3
ensure_pkg pip3           python3-pip
ensure_pkg curl           curl
ensure_pkg python3-venv   python3-venv || true
ensure_pkg jq             jq
ensure_pkg sudo           sudo
ensure_pkg tar            tar

mkdir -p /opt/XrayTools

echo ""
echo -e "${AMARELO}1. Token do BotFather (formato: 123456789:ABCdef...):${RESET}"
read -r -p "Token: " bot_token

echo ""
echo -e "${AMARELO}2. Seu ID numérico do Telegram (Admin):${RESET}"
read -r -p "ID Admin: " admin_id

# Validação
if [ -z "${bot_token:-}" ] || ! [[ "$bot_token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{35,}$ ]]; then
    echo -e "${VERMELHO}❌ Token inválido.${RESET}"
    exit 1
fi
if [ -z "${admin_id:-}" ] || ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
    echo -e "${VERMELHO}❌ ID Admin inválido.${RESET}"
    exit 1
fi

# --- DOWNLOAD DO PYTHON ---
echo ""
echo "Baixando bot..."
BOT_PY="/opt/XrayTools/botxray.py"
BOT_SHA_URL="${REPO_BASE}/modulosxray/botxray.py.sha256"
tmp_bot=$(mktemp /tmp/botxray_XXXXXX.py)

if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 60 --connect-timeout 10 \
        -o "$tmp_bot" "${REPO_BASE}/modulosxray/botxray.py" 2>>"$LOG_FILE"; then
    echo -e "${VERMELHO}❌ Erro ao baixar botxray.py${RESET}"
    rm -f "$tmp_bot"; exit 1
fi

if [ ! -s "$tmp_bot" ]; then
    echo -e "${VERMELHO}❌ botxray.py baixado está vazio.${RESET}"
    rm -f "$tmp_bot"; exit 1
fi

mv -f "$tmp_bot" "$BOT_PY"
chmod 0755 "$BOT_PY"

# --- CRIAÇÃO DO .BOT_ENV (O que faltou na última vez!) ---
ENV_FILE="/opt/XrayTools/.bot_env"
cat > "$ENV_FILE" <<ENVEOF
BOT_TOKEN=${bot_token}
ADMIN_ID=${admin_id}
ENVEOF
echo -e "${VERDE}Variáveis de ambiente criadas em ${ENV_FILE}${RESET}"

# --- USUÁRIO DEDICADO ---
if ! id -u botxray >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin botxray
fi

# --- VENV ---
if [ ! -d /opt/XrayTools/venv ]; then
    python3 -m venv /opt/XrayTools/venv
fi
echo "Instalando dependências Python..."
/opt/XrayTools/venv/bin/pip install --quiet --upgrade pip >>"$LOG_FILE" 2>&1
/opt/XrayTools/venv/bin/pip install --quiet "python-telegram-bot==20.7" "requests==2.31.0" >>"$LOG_FILE" 2>&1

# --- BACKUP SCRIPT ---
cat > /usr/local/bin/backup_bot.sh <<'BKPEOF'
#!/bin/bash
set -Eeuo pipefail
umask 077
OUT_DIR="/root/backups"
mkdir -p "$OUT_DIR"
ts="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${OUT_DIR}/backup_dragoncore_bot_${ts}.tar.gz"
[ -d /opt/XrayTools      ] || { echo "ERR: /opt/XrayTools ausente"; exit 2; }
[ -d /usr/local/etc/xray ] || { echo "ERR: /usr/local/etc/xray ausente"; exit 2; }
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/opt/XrayTools"
for f in users.db limits.db usage.db session.db active_domain; do
    [ -f "/opt/XrayTools/$f" ] && cp -f "/opt/XrayTools/$f" "$tmpdir/opt/XrayTools/$f"
done
mkdir -p "$tmpdir/usr/local/etc"
cp -a /usr/local/etc/xray "$tmpdir/usr/local/etc/" 2>/dev/null || true
mkdir -p "$tmpdir/opt"
[ -d /opt/DragonCoreSSL ] && cp -a /opt/DragonCoreSSL "$tmpdir/opt/" 2>/dev/null || true
tar -czf "$OUT_FILE" -C "$tmpdir" opt usr >/dev/null 2>&1 || exit 3
chmod 0644 "$OUT_FILE"
sha256sum "$OUT_FILE" > "${OUT_FILE}.sha256"
chmod 0644 "${OUT_FILE}.sha256"
echo "$OUT_FILE"
BKPEOF
chmod 0755 /usr/local/bin/backup_bot.sh
chown root:root /usr/local/bin/backup_bot.sh

# --- RESTORE SCRIPT ---
cat > /usr/local/bin/restore_bot.sh <<'RSTEOF'
#!/bin/bash
set -Eeuo pipefail
FILE="${1:-}"
[ -n "$FILE" ] && [ -f "$FILE" ] || exit 2
tar -tzf "$FILE" >/dev/null 2>&1 || exit 4
systemctl stop xray >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true
tar -xzf "$FILE" -C / 2>/dev/null || exit 3
chmod 0755 /opt/XrayTools 2>/dev/null || true
chmod 0666 /opt/XrayTools/users.db 2>/dev/null || true
chown root:nogroup /usr/local/etc/xray/config.json 2>/dev/null || true
chmod 0640 /usr/local/etc/xray/config.json 2>/dev/null || true
systemctl start xray >/dev/null 2>&1 || true
systemctl start botxray >/dev/null 2>&1 || true
RSTEOF
chmod 0755 /usr/local/bin/restore_bot.sh
chown root:root /usr/local/bin/restore_bot.sh

# --- SUDOERS ---
cat > /etc/sudoers.d/botxray <<'SUDOEOF'
Defaults:botxray !requiretty
Defaults:botxray !authenticate
Defaults:botxray secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
botxray ALL=(root) NOPASSWD: /usr/local/bin/add_user.sh
botxray ALL=(root) NOPASSWD: /usr/local/bin/remover_user.sh
botxray ALL=(root) NOPASSWD: /usr/local/bin/block_user.sh
botxray ALL=(root) NOPASSWD: /usr/local/bin/unblock_user.sh
botxray ALL=(root) NOPASSWD: /usr/local/bin/backup_bot.sh
botxray ALL=(root) NOPASSWD: /usr/local/bin/restore_bot.sh
SUDOEOF
chmod 0440 /etc/sudoers.d/botxray
visudo -cf /etc/sudoers.d/botxray >/dev/null

# --- PERMISSÕES GERAIS ---
mkdir -p /opt/XrayTools/backups
touch /opt/XrayTools/users.db
chown -R botxray:botxray /opt/XrayTools
chmod 0755 /opt/XrayTools
chmod 0666 /opt/XrayTools/users.db
chown root:botxray "$ENV_FILE"
chmod 0640 "$ENV_FILE"

# --- SYSTEMD SERVICE ---
cat > /etc/systemd/system/botxray.service <<'SVCEOF'
[Unit]
Description=DragonCore Telegram Bot
After=network.target

[Service]
Type=simple
User=botxray
Group=botxray
WorkingDirectory=/opt/XrayTools
EnvironmentFile=/opt/XrayTools/.bot_env
ExecStart=/opt/XrayTools/venv/bin/python /opt/XrayTools/botxray.py
Restart=always
RestartSec=10

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/opt/XrayTools /tmp /root/backups

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable botxray >/dev/null 2>&1 || true
systemctl restart botxray >/dev/null 2>&1 || true
sleep 2

echo ""
if systemctl is-active --quiet botxray 2>/dev/null; then
    echo -e "${VERDE}✅ BOT ATIVADO COM SUCESSO!${RESET}"
else
    echo -e "${AMARELO}⚠  Bot iniciado, aguardando conexão. Status:${RESET}"
fi

echo ""
# Protegido para não engatilhar código 3 do bash
systemctl status botxray --no-pager 2>/dev/null | sed -n '1,10p' || true
echo ""
read -rp "Pressione ENTER para voltar..."
