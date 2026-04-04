#!/bin/bash
# botxray.sh - Instalador do Bot Telegram V7.5
# Correções: token via EnvironmentFile (não hardcoded), sudoers sem /bin/bash,
#            download com verificação de integridade, restore com snapshot,
#            validação de formato do token, versões pip fixadas,
#            backup_bot.sh unificado com /root/backups, detecção de distro.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; read -rp "Enter...";' ERR

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
ensure_pkg python3-venv   python3-venv || true   # nome varia por distro
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

# Validação de token: formato Telegram (NNN:AAAA... — 35+ chars após :)
if [ -z "${bot_token:-}" ] || ! [[ "$bot_token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{35,}$ ]]; then
    echo -e "${VERMELHO}❌ Token inválido. Formato esperado: 123456789:ABCdef... (35+ chars após :)${RESET}"
    exit 1
fi
if [ -z "${admin_id:-}" ] || ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
    echo -e "${VERMELHO}❌ ID Admin inválido — deve ser numérico.${RESET}"
    exit 1
fi

# --- DOWNLOAD COM VERIFICAÇÃO DE INTEGRIDADE ---
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

# Verificação SHA256 (se disponível)
expected_sha=$(curl -fsSL --max-time 10 "$BOT_SHA_URL" 2>/dev/null | awk '{print $1}' || true)
if [ -n "${expected_sha:-}" ]; then
    actual_sha=$(sha256sum "$tmp_bot" | awk '{print $1}')
    if [ "$expected_sha" != "$actual_sha" ]; then
        echo -e "${VERMELHO}❌ Falha de integridade em botxray.py — download rejeitado.${RESET}"
        rm -f "$tmp_bot"; exit 1
    fi
    echo -e "${VERDE}SHA256 verificado.${RESET}"
else
    echo -e "${AMARELO}⚠  Hash não disponível — verificação ignorada.${RESET}"
fi

mv -f "$tmp_bot" "$BOT_PY"
chmod 777 "$BOT_PY"

# --- TOKEN ARMAZENADO EM ENVIRONMENTFILE (não hardcoded no .py) ---
# O botxray.py deve ler: BOT_TOKEN e ADMIN_ID de os.environ
ENV_FILE="/opt/XrayTools/.bot_env"
cat > "$ENV_FILE" <<ENVEOF
BOT_TOKEN=${bot_token}
ADMIN_ID=${admin_id}
ENVEOF
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"

echo -e "${VERDE}Credenciais salvas em ${ENV_FILE} (chmod 600).${RESET}"

# --- USUÁRIO DEDICADO ---
if ! id -u botxray >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin botxray
fi

# --- VENV COM VERSÕES FIXADAS ---
if [ ! -d /opt/XrayTools/venv ]; then
    python3 -m venv /opt/XrayTools/venv
fi
echo "Instalando dependências Python (versões fixadas)..."
/opt/XrayTools/venv/bin/pip install --quiet --upgrade pip >>"$LOG_FILE" 2>&1
# Versões fixadas para evitar breaking changes da API do python-telegram-bot
/opt/XrayTools/venv/bin/pip install --quiet \
    "python-telegram-bot==20.7" \
    "requests==2.31.0" >>"$LOG_FILE" 2>&1

# --- backup_bot.sh — unificado com /root/backups ---
cat > /usr/local/bin/backup_bot.sh <<'BKPEOF'
#!/bin/bash
set -Eeuo pipefail
umask 077

# Unificado com o backup.sh principal: mesmo diretório /root/backups
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

if ! tar -czf "$OUT_FILE" -C "$tmpdir" opt usr >/dev/null 2>&1; then
    echo "ERR: falha no tar"; exit 3
fi

chmod 777 "$OUT_FILE"

# Gera SHA256 ao lado
sha256sum "$OUT_FILE" > "${OUT_FILE}.sha256"
chmod 777 "${OUT_FILE}.sha256"

echo "$OUT_FILE"
BKPEOF
chmod 777 /usr/local/bin/backup_bot.sh
chown root:root /usr/local/bin/backup_bot.sh

# --- restore_bot.sh com snapshot antes de extrair ---
cat > /usr/local/bin/restore_bot.sh <<'RSTEOF'
#!/bin/bash
set -Eeuo pipefail

FILE="${1:-}"
[ -n "$FILE" ] || { echo "ERR: informe o caminho do .tar.gz"; exit 2; }
[ -f "$FILE" ] || { echo "ERR: arquivo não existe: $FILE"; exit 2; }

# Verifica integridade do tar
if ! tar -tzf "$FILE" >/dev/null 2>&1; then
    echo "ERR: arquivo tar corrompido ou ilegível"; exit 4
fi

# Verifica SHA256 se disponível
SHA_FILE="${FILE}.sha256"
if [ -f "$SHA_FILE" ]; then
    expected=$(awk '{print $1}' "$SHA_FILE")
    actual=$(sha256sum "$FILE" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo "ERR: SHA256 não confere — backup rejeitado"; exit 5
    fi
fi

# Valida paths dentro do tar (whitelist)
while IFS= read -r entry; do
    entry="${entry#./}"
    [ -n "$entry" ] || continue
    [[ "$entry" != /* ]]     || { echo "ERR: path absoluto: $entry"; exit 9; }
    [[ "$entry" != *".."* ]] || { echo "ERR: traversal: $entry"; exit 9; }
    case "$entry" in
        opt/XrayTools/*|usr/local/etc/xray/*|opt/DragonCoreSSL/*) ;;
        *) echo "ERR: path não permitido: $entry"; exit 9 ;;
    esac
done < <(tar -tzf "$FILE" 2>/dev/null)

# Snapshot do estado atual antes de sobrescrever
SNAP=$(mktemp /tmp/restore_snap_XXXXXX.tar.gz)
SNAP_PATHS=( "opt/XrayTools" "usr/local/etc/xray" )
[ -d /opt/DragonCoreSSL ] && SNAP_PATHS+=( "opt/DragonCoreSSL" )
if tar -czf "$SNAP" -C / "${SNAP_PATHS[@]}" >/dev/null 2>&1; then
    chmod 777 "$SNAP"
    echo "Snapshot salvo em: $SNAP"
else
    echo "AVISO: não foi possível criar snapshot — continuando."
    SNAP=""
fi

systemctl stop xray    >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true

if ! tar -xzf "$FILE" -C / 2>/dev/null; then
    echo "ERR: falha ao extrair backup."
    if [ -n "${SNAP:-}" ] && [ -f "$SNAP" ]; then
        echo "Restaurando snapshot anterior..."
        tar -xzf "$SNAP" -C / >/dev/null 2>&1 || true
    fi
    systemctl start xray >/dev/null 2>&1 || true
    exit 3
fi

# Permissões pós-restore
chmod 777  /opt/XrayTools               2>/dev/null || true
chmod 777  /opt/XrayTools/users.db      2>/dev/null || true
chmod 777 /usr/local/etc/xray/config.json 2>/dev/null || true
chown root:root /usr/local/etc/xray/config.json 2>/dev/null || true

if [ -d /opt/DragonCoreSSL ]; then
    chown -R nobody:nogroup /opt/DragonCoreSSL 2>/dev/null || true
    chmod 777 /opt/DragonCoreSSL                2>/dev/null || true
    chmod 777 /opt/DragonCoreSSL/fullchain.pem  2>/dev/null || true
    chmod 777 /opt/DragonCoreSSL/privkey.pem    2>/dev/null || true
fi

systemctl restart xray    >/dev/null 2>&1 || true
systemctl restart botxray >/dev/null 2>&1 || true
sleep 2

# Confirma que Xray voltou
if systemctl is-active --quiet xray 2>/dev/null; then
    [ -n "${SNAP:-}" ] && rm -f "$SNAP"
    echo "OK"
else
    echo "AVISO: Xray não ficou ativo após restore. Snapshot: ${SNAP:-N/A}"
    exit 6
fi
RSTEOF
chmod 777 /usr/local/bin/restore_bot.sh
chown root:root /usr/local/bin/restore_bot.sh

# --- SUDOERS CORRIGIDO — sem /bin/bash prefixado ---
# CRÍTICO: /bin/bash script.sh autoriza "sudo /bin/bash QUALQUER_COISA"
# Correto: autorizar apenas o script diretamente
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
chmod 777 /etc/sudoers.d/botxray
visudo -cf /etc/sudoers.d/botxray >/dev/null

# --- PERMISSÕES DO DIRETÓRIO ---
mkdir -p /opt/XrayTools/backups
chown -R botxray:botxray /opt/XrayTools
chmod 777 /opt/XrayTools
chmod 777 /opt/XrayTools/botxray.py 2>/dev/null || true
# .bot_env deve ser acessível pelo botxray via systemd EnvironmentFile
chown root:botxray "$ENV_FILE"
chmod 777 "$ENV_FILE"

# --- SYSTEMD SERVICE com EnvironmentFile ---
cat > /etc/systemd/system/botxray.service <<'SVCEOF'
[Unit]
Description=DragonCore Telegram Bot
After=network.target

[Service]
Type=simple
User=botxray
Group=botxray
WorkingDirectory=/opt/XrayTools

# Token e admin_id carregados via arquivo seguro — não hardcoded no código
EnvironmentFile=/opt/XrayTools/.bot_env

ExecStart=/opt/XrayTools/venv/bin/python /opt/XrayTools/botxray.py
Restart=always
RestartSec=10

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/XrayTools /tmp /root/backups

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable  botxray >/dev/null 2>&1 || true
systemctl restart botxray >/dev/null 2>&1 || true
sleep 2

echo ""
if systemctl is-active --quiet botxray 2>/dev/null; then
    echo -e "${VERDE}✅ BOT ATIVADO COM SUCESSO!${RESET}"
else
    echo -e "${AMARELO}⚠  Bot iniciado mas pode não estar ativo. Verifique:${RESET}"
    echo "   journalctl -u botxray -n 20 --no-pager"
fi

echo ""
echo -e "${AMARELO}IMPORTANTE:${RESET} O botxray.py precisa ler as variáveis de ambiente:"
echo -e "   ${VERDE}BOT_TOKEN${RESET} e ${VERDE}ADMIN_ID${RESET} via ${VERDE}os.environ${RESET}"
echo -e "   (não mais hardcoded no código-fonte)"
echo ""
systemctl status botxray --no-pager 2>/dev/null | sed -n '1,15p'
echo ""
read -rp "Pressione ENTER para voltar..."
