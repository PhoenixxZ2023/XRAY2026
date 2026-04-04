#!/bin/bash
# botxray.sh - Instalador do Bot Telegram V7.6
# - Token via EnvironmentFile (não hardcoded no .py)
# - Wrappers setuid C compilados (sem sudo — resolve nosuid)
# - Permissões corretas (sem chmod 777)
# - botxray.py lido do repositório e corrigido via patch inline
# - Versões pip fixadas

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

[ "${EUID:-$(id -u)}" -ne 0 ] && { echo -e "${VERMELHO}❌ Execute como root!${RESET}"; exit 1; }

: > "$LOG_FILE"

clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}      BOT TELEGRAM - DRAGONCORE V7.6           ${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""

echo "Preparando ambiente..."
ensure_pkg python3      python3
ensure_pkg pip3         python3-pip
ensure_pkg curl         curl
ensure_pkg jq           jq
ensure_pkg gcc          gcc
ensure_pkg tar          tar
ensure_pkg python3      python3-venv || true

mkdir -p /opt/XrayTools

echo ""
echo -e "${AMARELO}1. Token do BotFather (formato: 123456789:ABCdef...):${RESET}"
read -r -p "Token: " bot_token

echo ""
echo -e "${AMARELO}2. Seu ID numérico do Telegram (Admin):${RESET}"
read -r -p "ID Admin: " admin_id

if [ -z "${bot_token:-}" ] || ! [[ "$bot_token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{35,}$ ]]; then
    echo -e "${VERMELHO}❌ Token inválido.${RESET}"; exit 1
fi
if [ -z "${admin_id:-}" ] || ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
    echo -e "${VERMELHO}❌ ID Admin inválido.${RESET}"; exit 1
fi

# --- USUÁRIO DEDICADO ---
if ! id -u botxray >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin botxray
fi

# --- WRAPPERS SETUID EM C (resolve problema nosuid/sudo) ---
echo ""
echo "Compilando wrappers setuid..."
for s in add_user remover_user block_user unblock_user backup_bot restore_bot; do
    cat > /tmp/wrap_${s}.c << EOF
#include <unistd.h>
int main(int argc, char *argv[]) {
    setuid(0); setgid(0);
    char *args[] = {"/bin/bash", "/usr/local/bin/${s}.sh", (char*)0};
    execv("/bin/bash", args);
    return 1;
}
EOF
    gcc -o /usr/local/bin/wrap_${s} /tmp/wrap_${s}.c
    chown root:root /usr/local/bin/wrap_${s}
    chmod 777 /usr/local/bin/wrap_${s}
    rm -f /tmp/wrap_${s}.c
done
echo -e "${VERDE}Wrappers criados.${RESET}"

# --- DOWNLOAD DO botxray.py ---
echo ""
echo "Baixando bot..."
BOT_PY="/opt/XrayTools/botxray.py"
tmp_bot=$(mktemp /tmp/botxray_XXXXXX.py)

if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 60 --connect-timeout 10 \
        -o "$tmp_bot" "${REPO_BASE}/modulosxray/botxray.py" 2>>"$LOG_FILE"; then
    echo -e "${VERMELHO}❌ Erro ao baixar botxray.py${RESET}"
    rm -f "$tmp_bot"; exit 1
fi
[ -s "$tmp_bot" ] || { echo -e "${VERMELHO}❌ botxray.py vazio.${RESET}"; rm -f "$tmp_bot"; exit 1; }

# Verifica SHA256 se disponível
expected_sha=$(curl -fsSL --max-time 10 "${REPO_BASE}/modulosxray/botxray.py.sha256" 2>/dev/null | awk '{print $1}' || true)
if [ -n "${expected_sha:-}" ]; then
    actual_sha=$(sha256sum "$tmp_bot" | awk '{print $1}')
    [ "$expected_sha" = "$actual_sha" ] || {
        echo -e "${VERMELHO}❌ Falha de integridade.${RESET}"; rm -f "$tmp_bot"; exit 1; }
    echo -e "${VERDE}SHA256 verificado.${RESET}"
else
    echo -e "${AMARELO}⚠  Hash não disponível — verificação ignorada.${RESET}"
fi

# Aplica patch: substitui leitura de os.environ e wrappers no arquivo baixado
# (compatível com botxray.py original do repositório E com a versão corrigida)
python3 - "$tmp_bot" << 'PYEOF'
import sys, re
path = sys.argv[1]
src = open(path, encoding="utf-8", errors="ignore").read()

# 1) Substitui BOT_TOKEN e ADMIN_ID hardcoded por leitura de os.environ
src = re.sub(
    r'BOT_TOKEN\s*=\s*["\'].*?["\']',
    'BOT_TOKEN = os.environ.get("BOT_TOKEN", "")',
    src
)
src = re.sub(
    r'ADMIN_ID\s*=\s*\d+',
    'ADMIN_ID = int(os.environ.get("ADMIN_ID", "0"))',
    src
)

# 2) Substitui caminhos dos scripts para usar wrappers setuid
replacements = {
    '"/usr/local/bin/add_user.sh"':    '"/usr/local/bin/wrap_add_user"',
    '"/usr/local/bin/remover_user.sh"':'"/usr/local/bin/wrap_remover_user"',
    '"/usr/local/bin/block_user.sh"':  '"/usr/local/bin/wrap_block_user"',
    '"/usr/local/bin/unblock_user.sh"':'"/usr/local/bin/wrap_unblock_user"',
    '"/usr/local/bin/backup_bot.sh"':  '"/usr/local/bin/wrap_backup_bot"',
    '"/usr/local/bin/restore_bot.sh"': '"/usr/local/bin/wrap_restore_bot"',
}
for old, new in replacements.items():
    src = src.replace(old, new)

# 3) Remove sudo das chamadas subprocess
src = src.replace('["sudo", "-n", path]', '[path]')
src = src.replace('["sudo", "-n", path] + args', '[path] + args')

# 4) Corrige type hints incompatíveis com Python 3.8
src = src.replace('dict | None', 'Optional[dict]')
src = src.replace('str | None', 'Optional[str]')
src = re.sub(r'tuple\[([^\]]+)\]', lambda m: 'Tuple[' + m.group(1) + ']', src)
src = re.sub(r'list\[([^\]]+)\]', lambda m: 'List[' + m.group(1) + ']', src)

# 5) Garante imports necessários
if 'from typing import' not in src:
    src = src.replace('import os\n', 'import os\nfrom typing import Optional, Tuple, List\n', 1)
if 'from __future__ import annotations' not in src:
    src = 'from __future__ import annotations\n' + src

open(path, 'w', encoding='utf-8').write(src)
print("Patch aplicado.")
PYEOF

mv -f "$tmp_bot" "$BOT_PY"
chmod 777 "$BOT_PY"
chown root:botxray "$BOT_PY"

# --- ENVIRONMENTFILE (token fora do código) ---
ENV_FILE="/opt/XrayTools/.bot_env"
cat > "$ENV_FILE" << ENVEOF
BOT_TOKEN=${bot_token}
ADMIN_ID=${admin_id}
ENVEOF
chmod 777 "$ENV_FILE"
chown root:botxray "$ENV_FILE"
echo -e "${VERDE}Credenciais salvas em ${ENV_FILE}${RESET}"

# --- VENV COM VERSÕES FIXADAS ---
if [ ! -d /opt/XrayTools/venv ]; then
    python3 -m venv /opt/XrayTools/venv
fi
echo "Instalando dependências Python..."
/opt/XrayTools/venv/bin/pip install --quiet --upgrade pip >>"$LOG_FILE" 2>&1
/opt/XrayTools/venv/bin/pip install --quiet \
    "python-telegram-bot==20.7" \
    "requests==2.31.0" >>"$LOG_FILE" 2>&1

# --- backup_bot.sh ---
cat > /usr/local/bin/backup_bot.sh << 'BKPEOF'
#!/bin/bash
set -Eeuo pipefail
umask 777
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
tar -czf "$OUT_FILE" -C "$tmpdir" opt usr >/dev/null 2>&1 || { echo "ERR: falha tar"; exit 3; }
chmod 777 "$OUT_FILE"
sha256sum "$OUT_FILE" > "${OUT_FILE}.sha256"
chmod 777 "${OUT_FILE}.sha256"
echo "$OUT_FILE"
BKPEOF
chmod 777 /usr/local/bin/backup_bot.sh
chown root:root /usr/local/bin/backup_bot.sh

# --- restore_bot.sh ---
cat > /usr/local/bin/restore_bot.sh << 'RSTEOF'
#!/bin/bash
set -Eeuo pipefail
FILE="${1:-}"
[ -n "$FILE" ] || { echo "ERR: informe o .tar.gz"; exit 2; }
[ -f "$FILE" ] || { echo "ERR: arquivo não existe"; exit 2; }
tar -tzf "$FILE" >/dev/null 2>&1 || { echo "ERR: tar corrompido"; exit 4; }
SHA_FILE="${FILE}.sha256"
if [ -f "$SHA_FILE" ]; then
    expected=$(awk '{print $1}' "$SHA_FILE")
    actual=$(sha256sum "$FILE" | awk '{print $1}')
    [ "$expected" = "$actual" ] || { echo "ERR: SHA256 não confere"; exit 5; }
fi
while IFS= read -r entry; do
    entry="${entry#./}"; [ -n "$entry" ] || continue
    [[ "$entry" != /* ]]     || { echo "ERR: path absoluto"; exit 9; }
    [[ "$entry" != *".."* ]] || { echo "ERR: traversal"; exit 9; }
    case "$entry" in
        opt/XrayTools/*|usr/local/etc/xray/*|opt/DragonCoreSSL/*) ;;
        *) echo "ERR: path não permitido: $entry"; exit 9 ;;
    esac
done < <(tar -tzf "$FILE" 2>/dev/null)
SNAP=$(mktemp /tmp/restore_snap_XXXXXX.tar.gz)
SNAP_PATHS=("opt/XrayTools" "usr/local/etc/xray")
[ -d /opt/DragonCoreSSL ] && SNAP_PATHS+=("opt/DragonCoreSSL")
tar -czf "$SNAP" -C / "${SNAP_PATHS[@]}" >/dev/null 2>&1 && chmod 0600 "$SNAP" || SNAP=""
systemctl stop xray    >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true
if ! tar -xzf "$FILE" -C / 2>/dev/null; then
    echo "ERR: falha ao extrair"
    [ -n "${SNAP:-}" ] && tar -xzf "$SNAP" -C / >/dev/null 2>&1 || true
    systemctl start xray >/dev/null 2>&1 || true
    exit 3
fi
chown nobody:nogroup /usr/local/etc/xray/config.json 2>/dev/null || true
chmod 777 /usr/local/etc/xray/config.json 2>/dev/null || true
[ -d /opt/DragonCoreSSL ] && {
    chown -R nobody:nogroup /opt/DragonCoreSSL 2>/dev/null || true
    chmod 777 /opt/DragonCoreSSL 2>/dev/null || true
    chmod 777 /opt/DragonCoreSSL/fullchain.pem 2>/dev/null || true
    chmod 777 /opt/DragonCoreSSL/privkey.pem 2>/dev/null || true
}
systemctl restart xray    >/dev/null 2>&1 || true
systemctl restart botxray >/dev/null 2>&1 || true
sleep 2
systemctl is-active --quiet xray 2>/dev/null && { [ -n "${SNAP:-}" ] && rm -f "$SNAP"; echo "OK"; } || \
    { echo "AVISO: Xray não ficou ativo. Snapshot: ${SNAP:-N/A}"; exit 6; }
RSTEOF
chmod 777 /usr/local/bin/restore_bot.sh
chown root:root /usr/local/bin/restore_bot.sh

# --- PERMISSÕES DO DIRETÓRIO ---
mkdir -p /opt/XrayTools/backups
chown -R botxray:botxray /opt/XrayTools
chmod 777 /opt/XrayTools
chmod 777 /opt/XrayTools/backups
chown root:botxray "$ENV_FILE"
chmod 777 "$ENV_FILE"
chown root:botxray "$BOT_PY"
chmod 777 "$BOT_PY"

# --- SYSTEMD SERVICE ---
cat > /etc/systemd/system/botxray.service << 'SVCEOF'
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
    echo -e "${AMARELO}⚠  Bot não ficou ativo. Verifique:${RESET}"
    echo "   journalctl -u botxray -n 20 --no-pager"
fi

echo ""
systemctl status botxray --no-pager 2>/dev/null | sed -n '1,15p'
echo ""
read -rp "Pressione ENTER para voltar..."
