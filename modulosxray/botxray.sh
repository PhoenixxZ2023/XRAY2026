#!/bin/bash
# botxray.sh - TURBONET XRAY V1.3.5 (PRO + HÍBRIDO)
# Correções V1.3.5:
#   - Permissões 2770/660 em /usr/local/etc/xray e /opt/XrayTools para escrita atômica do bot sem root
#   - Garante `usermod -aG ${XRAY_GRP} botxray` na instalação, no restore e ao iniciar o serviço
#   - Mantida verificação via `python3 -c "import ensurepip, venv"` e recriação automática de venv incompleto

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (codigo: $?)"; read -rp "Enter...";' ERR

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/PhoenixxZ2023/XRAY2026/main}"
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
    else echo -e "${VERMELHO}Gerenciador de pacotes nao detectado.${RESET}"; exit 1; fi
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

[ "${EUID:-$(id -u)}" -ne 0 ] && { echo -e "${VERMELHO}Execute como root!${RESET}"; exit 1; }

_detect_xray_group() {
    local svc_user=""
    if command -v systemctl &>/dev/null; then
        svc_user=$(systemctl show -p User --value xray 2>/dev/null || true)
    fi
    svc_user="${svc_user:-nobody}"
    if ! id "$svc_user" &>/dev/null; then
        svc_user="root"
    fi
    id -gn "$svc_user"
}

_apply_bot_runtime_perms() {
    local xray_grp
    xray_grp="$(_detect_xray_group)"

    if id -u botxray &>/dev/null; then
        usermod -aG "$xray_grp" botxray 2>/dev/null || true
    fi

    if [ -d /usr/local/etc/xray ]; then
        chown -R "root:${xray_grp}" /usr/local/etc/xray
        chmod 2770 /usr/local/etc/xray
        chmod 660 /usr/local/etc/xray/*.json 2>/dev/null || true
    fi

    mkdir -p /opt/XrayTools /opt/XrayTools/backups /opt/XrayTools/users /root/backups
    if id -u botxray &>/dev/null; then
        chown root:botxray /opt/XrayTools
        chmod 2770 /opt/XrayTools

        chown botxray:botxray /opt/XrayTools/backups /opt/XrayTools/users
        chmod 0750 /opt/XrayTools/backups /opt/XrayTools/users

        [ -f /opt/XrayTools/.bot_env ] && { chown root:botxray /opt/XrayTools/.bot_env; chmod 0640 /opt/XrayTools/.bot_env; }
        [ -f /opt/XrayTools/botxray.py ] && { chown root:botxray /opt/XrayTools/botxray.py; chmod 0640 /opt/XrayTools/botxray.py; }
        chown -R botxray:botxray /opt/XrayTools/venv 2>/dev/null || true

        for db in users.db limits.db usage.db session.db; do
            [ -f "/opt/XrayTools/$db" ] && {
                chown botxray:botxray "/opt/XrayTools/$db"
                chmod 0660 "/opt/XrayTools/$db"
            }
        done
        for info in active_domain connection_info.txt; do
            [ -f "/opt/XrayTools/$info" ] && {
                chown root:botxray "/opt/XrayTools/$info"
                chmod 0640 "/opt/XrayTools/$info"
            }
        done
    fi
}

_wait_service_active() {
    local svc="$1" tries=5
    while [ "$tries" -gt 0 ]; do
        systemctl is-active --quiet "$svc" 2>/dev/null && return 0
        sleep 1
        tries=$(( tries - 1 ))
    done
    return 1
}

# ==========================================
# FUNÇÃO DE INSTALAÇÃO
# ==========================================
func_install_bot() {
    : > "$LOG_FILE"
    clear
    echo -e "${AZUL}==================================================${RESET}"
    echo -e "${AMARELO}     INSTALADOR BOT TELEGRAM - V1.3.5 (PRO)      ${RESET}"
    echo -e "${AZUL}==================================================${RESET}"
    echo ""

    echo "Preparando ambiente..."
    ensure_pkg python3    python3
    ensure_pkg curl       curl
    ensure_pkg jq         jq
    ensure_pkg gcc        gcc
    ensure_pkg tar        tar

    if ! python3 -c "import ensurepip, venv" >/dev/null 2>&1; then
        _detect_pkg_manager
        local py_ver
        py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")
        case "$_PKG_MANAGER" in
            apt)
                if [ "$_APT_UPDATED" -eq 0 ]; then
                    apt-get update -y >>"$LOG_FILE" 2>&1 || true
                    _APT_UPDATED=1
                fi
                apt-get install -y python3-venv ${py_ver:+"python${py_ver}-venv"} >>"$LOG_FILE" 2>&1 || true
                ;;
            dnf|yum) "$_PKG_MANAGER" install -y python3-virtualenv >>"$LOG_FILE" 2>&1 || true ;;
            pacman)  pacman -Sy --noconfirm python-virtualenv >>"$LOG_FILE" 2>&1 || true ;;
        esac
    fi

    if ! python3 -c "import ensurepip, venv" >/dev/null 2>&1; then
        echo -e "${VERMELHO}Falha ao instalar python3-venv (ensurepip indisponivel). Veja: ${LOG_FILE}${RESET}"
        sleep 2
        return 1
    fi

    mkdir -p /opt/XrayTools

    echo ""
    echo -e "${AMARELO}1. Token do BotFather (formato: 123456789:ABCdef...):${RESET}"
    echo -e "${AMARELO}   Cole o token e pressione Enter:${RESET}"
    read -r bot_token || true
    bot_token="$(echo "${bot_token:-}" | tr -d '[:space:][:cntrl:]')"

    echo ""
    echo -e "${AMARELO}2. Seu ID numerico do Telegram (Admin):${RESET}"
    read -r -p "ID Admin: " admin_id || true
    admin_id="$(echo "${admin_id:-}" | tr -d '[:space:][:cntrl:]')"

    if [ -z "${bot_token:-}" ] || ! [[ "$bot_token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{35,}$ ]]; then
        echo -e "${VERMELHO}Token invalido.${RESET}"; sleep 2; return 1
    fi
    if [ -z "${admin_id:-}" ] || ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
        echo -e "${VERMELHO}ID Admin invalido.${RESET}"; sleep 2; return 1
    fi

    if ! id -u botxray >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin botxray
    fi

    # --- SCRIPT PRIVILEGIADO DE SINCRONIA SSH ---
    cat > /usr/local/bin/ssh_sync.sh << 'SSHEOF'
#!/bin/bash
set -Eeuo pipefail

ACTION="${1:-}"
NICK="${2:-}"

if [[ ! "$NICK" =~ ^[a-z0-9_-]{2,32}$ ]] || [ "$NICK" = "root" ]; then
    echo "ERR: usuario invalido" >&2
    exit 1
fi

if id "$NICK" &>/dev/null; then
    uid_num=$(id -u "$NICK")
    if [ "$uid_num" -lt 1000 ]; then
        echo "ERR: conta de sistema protegida" >&2
        exit 1
    fi
fi

case "$ACTION" in
    create)
        IFS= read -r PASS || true
        PASS="${PASS:-$NICK}"
        id "$NICK" &>/dev/null || useradd -M -s /bin/false "$NICK"
        printf '%s:%s\n' "$NICK" "$PASS" | chpasswd
        ;;
    delete)
        pkill -9 -u "$NICK" 2>/dev/null || true
        userdel -r -f "$NICK" 2>/dev/null || true
        ;;
    block)
        usermod -L "$NICK" 2>/dev/null || true
        chage -E 0 "$NICK" 2>/dev/null || true
        pkill -9 -u "$NICK" 2>/dev/null || true
        ;;
    unblock|renew)
        usermod -U "$NICK" 2>/dev/null || true
        chage -E -1 "$NICK" 2>/dev/null || true
        passwd -u "$NICK" 2>/dev/null || true
        ;;
    *)
        echo "ERR: acao invalida" >&2
        exit 1
        ;;
esac
SSHEOF
    chmod 0755 /usr/local/bin/ssh_sync.sh
    chown root:root /usr/local/bin/ssh_sync.sh

    # --- WRAPPERS SETUID EM C ---
    echo ""
    echo "Compilando wrappers setuid..."
    for s in ssh_sync add_user remover_user block_user unblock_user renew_user backup_bot restore_bot; do
        cat > "/tmp/wrap_${s}.c" << EOF
#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    if (setgid(0) != 0 || setuid(0) != 0) {
        return 126;
    }
    clearenv();
    setenv("TERM", "xterm", 1);
    setenv("HOME", "/root", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);

    char **new_args = malloc(((size_t)argc + 3) * sizeof(char*));
    if (!new_args) {
        return 127;
    }
    new_args[0] = "/bin/bash";
    new_args[1] = "-p";
    new_args[2] = "/usr/local/bin/${s}.sh";
    for (int i = 1; i < argc; i++) {
        new_args[i + 2] = argv[i];
    }
    new_args[argc + 2] = NULL;

    execv("/bin/bash", new_args);
    return 127;
}
EOF
        gcc -O2 -Wall -o "/usr/local/bin/wrap_${s}" "/tmp/wrap_${s}.c"
        chown root:botxray "/usr/local/bin/wrap_${s}"
        chmod 4750 "/usr/local/bin/wrap_${s}"
        rm -f "/tmp/wrap_${s}.c"
    done
    echo -e "${VERDE}Wrappers criados com sucesso.${RESET}"

    # --- DOWNLOAD DO botxray.py ---
    echo ""
    echo "Baixando bot..."
    BOT_PY="/opt/XrayTools/botxray.py"
    tmp_bot=$(mktemp /tmp/botxray_XXXXXX.py)

    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 60 --connect-timeout 10 \
            -o "$tmp_bot" "${REPO_BASE}/modulosxray/botxray.py" 2>>"$LOG_FILE"; then
        echo -e "${VERMELHO}Erro ao baixar botxray.py${RESET}"
        rm -f "$tmp_bot"; sleep 2; return 1
    fi
    [ -s "$tmp_bot" ] || { echo -e "${VERMELHO}botxray.py vazio.${RESET}"; rm -f "$tmp_bot"; sleep 2; return 1; }

    mv -f "$tmp_bot" "$BOT_PY"
    chmod 0640 "$BOT_PY"
    chown root:botxray "$BOT_PY"

    # --- ENVIRONMENTFILE ---
    ENV_FILE="/opt/XrayTools/.bot_env"
    printf 'BOT_TOKEN=%s\nADMIN_ID=%s\n' "$bot_token" "$admin_id" > "$ENV_FILE"
    chmod 0640 "$ENV_FILE"
    chown root:botxray "$ENV_FILE"
    echo -e "${VERDE}Credenciais salvas em ${ENV_FILE}${RESET}"

    # --- VENV COM VERSÕES FIXADAS (RECRIA SE INCOMPLETO) ---
    if ! /opt/XrayTools/venv/bin/python -m pip --version >/dev/null 2>&1; then
        rm -rf /opt/XrayTools/venv
        python3 -m venv /opt/XrayTools/venv
    fi
    echo "Instalando dependencias Python..."
    /opt/XrayTools/venv/bin/python -m pip install --quiet --no-cache-dir \
        "python-telegram-bot==20.7" \
        "requests==2.31.0" >>"$LOG_FILE" 2>&1

    # --- backup_bot.sh ---
    cat > /usr/local/bin/backup_bot.sh << 'BKPEOF'
#!/bin/bash
set -Eeuo pipefail
umask 077
OUT_DIR="/root/backups"
mkdir -p "$OUT_DIR"
ts="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${OUT_DIR}/backup_turbonet_bot_${ts}.tar.gz"
[ -d /opt/XrayTools       ] || { echo "ERR: /opt/XrayTools ausente"; exit 2; }
[ -d /usr/local/etc/xray ] || { echo "ERR: /usr/local/etc/xray ausente"; exit 2; }
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/opt/XrayTools"
for f in users.db limits.db usage.db session.db active_domain connection_info.txt; do
    [ -f "/opt/XrayTools/$f" ] && cp -f "/opt/XrayTools/$f" "$tmpdir/opt/XrayTools/$f"
done
[ -d /opt/XrayTools/users ] && \
    cp -r /opt/XrayTools/users "$tmpdir/opt/XrayTools/" 2>/dev/null || true
mkdir -p "$tmpdir/usr/local/etc"
cp -a /usr/local/etc/xray "$tmpdir/usr/local/etc/" 2>/dev/null || true
mkdir -p "$tmpdir/opt"
[ -d /opt/TurbonetCoreSSL ] && cp -a /opt/TurbonetCoreSSL "$tmpdir/opt/" 2>/dev/null || true
tar -czf "$OUT_FILE" -C "$tmpdir" opt usr >/dev/null 2>&1 || { echo "ERR: falha tar"; exit 3; }
chmod 0600 "$OUT_FILE"
sha256sum "$OUT_FILE" > "${OUT_FILE}.sha256"
chmod 0600 "${OUT_FILE}.sha256"
echo "$OUT_FILE"
BKPEOF
    chmod 0755 /usr/local/bin/backup_bot.sh
    chown root:root /usr/local/bin/backup_bot.sh

    # --- restore_bot.sh ---
    cat > /usr/local/bin/restore_bot.sh << 'RSTEOF'
#!/bin/bash
set -Eeuo pipefail
FILE="${1:-}"
[ -n "$FILE" ] || { echo "ERR: informe o .tar.gz"; exit 2; }
[ -f "$FILE" ] || { echo "ERR: arquivo nao existe"; exit 2; }
tar -tzf "$FILE" >/dev/null 2>&1 || { echo "ERR: tar corrompido"; exit 4; }
SHA_FILE="${FILE}.sha256"
if [ -f "$SHA_FILE" ]; then
    expected=$(awk '{print $1}' "$SHA_FILE")
    actual=$(sha256sum "$FILE" | awk '{print $1}')
    [ "$expected" = "$actual" ] || { echo "ERR: SHA256 nao confere"; exit 5; }
fi

while IFS= read -r entry; do
    entry="${entry#./}"; [ -n "$entry" ] || continue
    [[ "$entry" != /* ]]     || { echo "ERR: path absoluto"; exit 9; }
    [[ "$entry" != *".."* ]] || { echo "ERR: traversal"; exit 9; }
    case "$entry" in
        opt/XrayTools/users.db|\
        opt/XrayTools/limits.db|\
        opt/XrayTools/usage.db|\
        opt/XrayTools/session.db|\
        opt/XrayTools/active_domain|\
        opt/XrayTools/connection_info.txt|\
        opt/XrayTools/users|\
        opt/XrayTools/users/*|\
        usr/local/etc/xray|\
        usr/local/etc/xray/*|\
        opt/TurbonetCoreSSL|\
        opt/TurbonetCoreSSL/*) ;;
        *) echo "ERR: path nao permitido: $entry"; exit 9 ;;
    esac
done < <(tar -tzf "$FILE" 2>/dev/null)

SNAP=$(mktemp /tmp/restore_snap_XXXXXX.tar.gz)
SNAP_PATHS=("opt/XrayTools" "usr/local/etc/xray")
[ -d /opt/TurbonetCoreSSL ] && SNAP_PATHS+=("opt/TurbonetCoreSSL")
tar -czf "$SNAP" -C / "${SNAP_PATHS[@]}" >/dev/null 2>&1 && chmod 0600 "$SNAP" || SNAP=""

systemctl stop xray >/dev/null 2>&1 || true

if ! tar -xzf "$FILE" -C / --no-overwrite-dir --no-same-permissions 2>/dev/null; then
    echo "ERR: falha ao extrair"
    [ -n "${SNAP:-}" ] && tar -xzf "$SNAP" -C / >/dev/null 2>&1 || true
    systemctl start xray >/dev/null 2>&1 || true
    exit 3
fi

svc_user=$(systemctl show -p User --value xray 2>/dev/null || true)
svc_user="${svc_user:-nobody}"
id "$svc_user" &>/dev/null || svc_user="root"
xray_grp=$(id -gn "$svc_user")

if id -u botxray &>/dev/null; then
    usermod -aG "$xray_grp" botxray 2>/dev/null || true
    chmod 2770 /usr/local/etc/xray 2>/dev/null || true
    chown -R "root:${xray_grp}" /usr/local/etc/xray 2>/dev/null || true
    chmod 0660 /usr/local/etc/xray/*.json 2>/dev/null || true

    chown root:botxray /opt/XrayTools 2>/dev/null || true
    chmod 2770 /opt/XrayTools 2>/dev/null || true

    for db in users.db limits.db usage.db session.db; do
        [ -f "/opt/XrayTools/$db" ] && {
            chown botxray:botxray "/opt/XrayTools/$db" 2>/dev/null || true
            chmod 0660 "/opt/XrayTools/$db" 2>/dev/null || true
        }
    done
else
    chmod 750 /usr/local/etc/xray 2>/dev/null || true
    chown "root:${xray_grp}" /usr/local/etc/xray 2>/dev/null || true
    [ -f /usr/local/etc/xray/config.json ] && {
        chmod 0640 /usr/local/etc/xray/config.json 2>/dev/null || true
        chown "root:${xray_grp}" /usr/local/etc/xray/config.json 2>/dev/null || true
    }
    [ -f /usr/local/etc/xray/preset.json ] && {
        chmod 0640 /usr/local/etc/xray/preset.json 2>/dev/null || true
        chown "root:${xray_grp}" /usr/local/etc/xray/preset.json 2>/dev/null || true
    }

    chown root:root /opt/XrayTools 2>/dev/null || true
    chmod 0750 /opt/XrayTools 2>/dev/null || true

    for db in users.db limits.db usage.db session.db; do
        [ -f "/opt/XrayTools/$db" ] && {
            chown root:root "/opt/XrayTools/$db" 2>/dev/null || true
            chmod 0600 "/opt/XrayTools/$db" 2>/dev/null || true
        }
    done
fi

for info in active_domain connection_info.txt; do
    [ -f "/opt/XrayTools/$info" ] && {
        chown root:botxray "/opt/XrayTools/$info" 2>/dev/null || true
        chmod 0640 "/opt/XrayTools/$info" 2>/dev/null || true
    }
done

[ -d /opt/XrayTools/users ] && {
    chown botxray:botxray /opt/XrayTools/users 2>/dev/null || true
    chmod 0750 /opt/XrayTools/users 2>/dev/null || true
    find /opt/XrayTools/users -maxdepth 1 -name "*.txt" \
        -exec chmod 640 {} \; -exec chown root:botxray {} \; 2>/dev/null || true
}

[ -d /opt/TurbonetCoreSSL ] && {
    chmod 750 /opt/TurbonetCoreSSL 2>/dev/null || true
    chown "root:${xray_grp}" /opt/TurbonetCoreSSL 2>/dev/null || true
    chmod 640 /opt/TurbonetCoreSSL/fullchain.pem 2>/dev/null || true
    chown "root:${xray_grp}" /opt/TurbonetCoreSSL/fullchain.pem 2>/dev/null || true
    chmod 640 /opt/TurbonetCoreSSL/privkey.pem 2>/dev/null || true
    chown "root:${xray_grp}" /opt/TurbonetCoreSSL/privkey.pem 2>/dev/null || true
}

if [ -s /opt/XrayTools/users.db ]; then
    while IFS='|' read -r nick uuid expiry pass limit _rest || [ -n "${nick:-}" ]; do
        nick="${nick//$'\r'/}"
        pass="${pass//$'\r'/}"
        [ -n "${nick:-}" ] && [ -n "${pass:-}" ] || continue
        [ "$nick" = "root" ] && continue
        [[ "$nick" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || continue
        id "$nick" &>/dev/null || useradd -M -s /bin/false "$nick" 2>/dev/null || true
        echo "${nick}:${pass}" | chpasswd 2>/dev/null || true
    done < /opt/XrayTools/users.db
fi

systemctl restart xray >/dev/null 2>&1 || true

_wait=5
while [ "$_wait" -gt 0 ]; do
    systemctl is-active --quiet xray 2>/dev/null && break
    sleep 1; _wait=$(( _wait - 1 ))
done

if systemctl is-active --quiet xray 2>/dev/null; then
    [ -n "${SNAP:-}" ] && rm -f "$SNAP"
    if command -v systemd-run &>/dev/null; then
        systemd-run --no-block --unit="botxray-restart-$(date +%s)" \
            /bin/sh -c 'sleep 2 && systemctl restart botxray' >/dev/null 2>&1 || true
    else
        (sleep 2; systemctl restart botxray) >/dev/null 2>&1 </dev/null &
    fi
    echo "OK"
else
    echo "AVISO: Xray nao ficou ativo. Snapshot: ${SNAP:-N/A}"
    exit 6
fi
RSTEOF
    chmod 0755 /usr/local/bin/restore_bot.sh
    chown root:root /usr/local/bin/restore_bot.sh

    # --- PERMISSÕES DO DIRETÓRIO ---
    XRAY_GRP="$(_detect_xray_group)"
    _apply_bot_runtime_perms

    # --- SYSTEMD SERVICE ---
    cat > /etc/systemd/system/botxray.service << SVCEOF
[Unit]
Description=TURBONET XRAY Telegram Bot
After=network.target

[Service]
Type=simple
User=botxray
Group=botxray
SupplementaryGroups=${XRAY_GRP}
WorkingDirectory=/opt/XrayTools
EnvironmentFile=/opt/XrayTools/.bot_env
ExecStart=/opt/XrayTools/venv/bin/python /opt/XrayTools/botxray.py
Restart=always
RestartSec=10
PrivateTmp=true
ProtectSystem=true
ReadWritePaths=/opt/XrayTools /tmp /root/backups /usr/local/etc/xray /etc

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable  botxray >/dev/null 2>&1 || true
    systemctl restart botxray >/dev/null 2>&1 || true

    echo ""
    if _wait_service_active botxray; then
        echo -e "${VERDE}BOT ATIVADO COM SUCESSO!${RESET}"
    else
        echo -e "${AMARELO}Bot pode nao estar ativo. Verifique os logs.${RESET}"
    fi

    echo ""
    read -rp "Pressione ENTER para voltar ao Gerenciador..."
}

# ==========================================
# FUNÇÕES DE GERENCIAMENTO
# ==========================================
func_start_bot() {
    echo -e "\nIniciando o Bot..."
    _apply_bot_runtime_perms
    systemctl enable botxray >/dev/null 2>&1 || true
    systemctl start  botxray >/dev/null 2>&1 || true
    if _wait_service_active botxray; then
        echo -e "${VERDE}✅ Bot iniciado e rodando!${RESET}"
    else
        echo -e "${VERMELHO}❌ Falha ao iniciar o Bot. Verifique os logs.${RESET}"
    fi
    sleep 2
}

func_stop_bot() {
    echo -e "\nParando o Bot..."
    systemctl stop    botxray >/dev/null 2>&1 || true
    systemctl disable botxray >/dev/null 2>&1 || true
    sleep 1
    echo -e "${AMARELO}⛔ Bot desligado e desativado da inicialização.${RESET}"
    sleep 2
}

func_view_logs() {
    clear
    echo -e "${AZUL}==================================================${RESET}"
    echo -e "${AMARELO}   LOGS DO BOT (AO VIVO) - Pressione CTRL+C    ${RESET}"
    echo -e "${AZUL}==================================================${RESET}"
    journalctl -u botxray -f || true
}

# ==========================================
# MENU PRINCIPAL DO GERENCIADOR
# ==========================================
while true; do
    clear
    echo -e "${AZUL}==================================================${RESET}"
    echo -e "${AMARELO}      GERENCIADOR DO BOT TELEGRAM V1.3.5      ${RESET}"
    echo -e "${AZUL}==================================================${RESET}"

    status_msg="${VERMELHO}NÃO INSTALADO${RESET}"
    if [ -f /etc/systemd/system/botxray.service ]; then
        if systemctl is-active --quiet botxray 2>/dev/null; then
            status_msg="${VERDE}ATIVO E RODANDO${RESET}"
        else
            status_msg="${VERMELHO}PARADO / DESATIVADO${RESET}"
        fi
    fi

    echo -e " STATUS DO BOT: ${status_msg}"
    echo -e "${AZUL}==================================================${RESET}"
    echo -e " ${VERDE}[1]${RESET} INSTALAR OU ATUALIZAR BOT"
    echo -e " ${VERDE}[2]${RESET} LIGAR BOT"
    echo -e " ${VERDE}[3]${RESET} DESLIGAR BOT"
    echo -e " ${VERDE}[4]${RESET} VER LOGS EM TEMPO REAL"
    echo -e " ${VERMELHO}[0]${RESET} VOLTAR AO MENU PRINCIPAL"
    echo -e "${AZUL}==================================================${RESET}"

    read -r -p "Escolha uma opção: " opt || true
    case "${opt:-}" in
        1) func_install_bot ;;
        2) func_start_bot ;;
        3) func_stop_bot ;;
        4) func_view_logs ;;
        0) exit 0 ;;
        *) echo -e "${VERMELHO}Opção inválida!${RESET}"; sleep 1 ;;
    esac
done
