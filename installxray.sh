#!/bin/bash
# installxray.sh - Instalador Premium V7.5 (Modular Launcher)
# Correções: Sintaxe do 'local_head' resolvida e URLs ajustadas.
set -Eeuo pipefail

# --- TRAP DE SAÍDA ---
LOCK_FILE="/tmp/xray-install.lock"
LOG_FILE="/tmp/xray-install.log"
trap '_cleanup' EXIT

_cleanup() {
    tput cnorm 2>/dev/null || true
    rm -f "$LOCK_FILE"
}

# --- CORES ---
VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

# --- CONFIGURAÇÃO ---
REPO_OWNER="PhoenixxZ2023"
REPO_NAME="XrayX-TLS"

_validate_ref() {
    local ref="$1"
    if [[ ! "$ref" =~ ^[a-zA-Z0-9._/-]{1,128}$ ]]; then
        echo -e "${VERMELHO}❌ REPO_REF inválido: '${ref}'. Use branch, tag ou commit hash válido.${RESET}"
        exit 1
    fi
}

REPO_REF="${REPO_REF:-main}"
_validate_ref "$REPO_REF"

REPO_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}"

# SE O MENU ESTIVER NA RAIZ DO GITHUB, DEIXE ASSIM. 
# SE ESTIVER DENTRO DA PASTA, MUDE PARA: "${REPO_BASE}/modulosxray/menuxray.sh"
MENU_URL="${REPO_BASE}/menuxray.sh"
SHA256_URL="${REPO_BASE}/menuxray.sh.sha256"

MENU_PATH="/usr/local/bin/menuxray.sh"
MENU_BACKUP="/usr/local/bin/menuxray.sh.bak"
SHORTCUT="/usr/bin/xray-menu"

# --- DETECÇÃO DE DISTRO ---
_detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"
    else
        echo -e "${VERMELHO}❌ Gerenciador de pacotes não suportado.${RESET}"
        exit 1
    fi
}

_install_packages() {
    local packages=("$@")
    case "$PKG_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >>"$LOG_FILE" 2>&1
            apt-get install -y "${packages[@]}" >>"$LOG_FILE" 2>&1
            ;;
        dnf|yum)
            "$PKG_MANAGER" install -y "${packages[@]}" >>"$LOG_FILE" 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm "${packages[@]}" >>"$LOG_FILE" 2>&1
            ;;
    esac
}

_get_packages() {
    case "$PKG_MANAGER" in
        apt)    echo "curl jq cron tar" ;;
        dnf|yum) echo "curl jq cronie tar" ;;
        pacman) echo "curl jq cronie tar" ;;
    esac
}

# --- BARRA DE PROGRESSO ---
fun_bar() {
    local pid="$1"
    local text="$2"
    local delay=0.1
    local percent=0
    tput civis || true
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$percent" -lt 95 ]; then percent=$((percent + 1)); fi
        local filled=$((percent / 5))
        local unfilled=$((20 - filled))
        printf "\r${AZUL}[${text}]${RESET} ["
        printf "%0.s#" $(seq 1 "$filled")
        printf "%0.s." $(seq 1 "$unfilled")
        printf "] ${AMARELO}%d%%${RESET} " "$percent"
        sleep "$delay"
    done
    local exit_code=0
    wait "$pid" 2>/dev/null || exit_code=$?
    tput cnorm || true
    if [ "$exit_code" -eq 0 ]; then
        printf "\r${AZUL}[${text}]${RESET} ["
        printf "%0.s#" $(seq 1 20)
        printf "] ${VERDE}100%% - OK!${RESET}    \n"
    else
        printf "\r${VERMELHO}[${text}]${RESET} ["
        printf "%0.s!" $(seq 1 20)
        printf "] ${VERMELHO}FALHOU! (código ${exit_code})${RESET}    \n"
        echo -e "${AMARELO}⚠  Detalhes em: ${LOG_FILE}${RESET}"
        return "$exit_code"
    fi
}

# --- VERIFICAÇÃO DE INTEGRIDADE ---
_verify_sha256() {
    local file="$1"
    local sha256_url="$2"
    local expected_sha256

    expected_sha256=$(curl -fLsS --retry 3 --retry-delay 1 "$sha256_url" 2>>"$LOG_FILE" | awk '{print $1}')

    if [ -z "$expected_sha256" ]; then
        echo -e "${AMARELO}⚠  Arquivo de hash não encontrado — verificação ignorada.${RESET}"
        return 0
    fi

    local actual_sha256
    actual_sha256=$(sha256sum "$file" | awk '{print $1}')

    if [ "$expected_sha256" != "$actual_sha256" ]; then
        echo -e "${VERMELHO}❌ Falha na verificação de integridade!${RESET}"
        rm -f "$file"
        return 1
    fi
}

# --- LOCK ---
if [ -e "$LOCK_FILE" ]; then
    echo -e "${VERMELHO}❌ Outra instalação está em andamento (${LOCK_FILE} existe).${RESET}"
    exit 1
fi
touch "$LOCK_FILE"

# --- INICIALIZAÇÃO ---
clear
: > "$LOG_FILE"

echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}🚀 DRAGONCORE MODULAR - LAUNCHER V7.5${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo -e "  Ref:  ${VERDE}${REPO_REF}${RESET}"
echo -e "  Log:  ${VERDE}${LOG_FILE}${RESET}"
echo -e "${AZUL}==================================================${RESET}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${VERMELHO}❌ Execute como root!${RESET}"
    exit 1
fi

_detect_pkg_manager
echo -e "  Sistema: ${VERDE}${PKG_MANAGER}${RESET}"
echo ""

# --- 1) ATUALIZAÇÃO + DEPENDÊNCIAS ---
(
    _install_packages $(_get_packages)
) >>"$LOG_FILE" 2>&1 &
PID_PKG=$!
fun_bar "$PID_PKG" "Atualizando e Instalando Dependências" || exit 1

# --- 2) BACKUP DA INSTALAÇÃO ANTERIOR ---
(
    if [ -f "$MENU_PATH" ]; then
        cp -f "$MENU_PATH" "$MENU_BACKUP" 2>>"$LOG_FILE" || true
    fi
) &
fun_bar $! "Fazendo Backup da Versão Anterior" || true

# --- 3) LIMPEZA ANTIGA ---
(
    rm -f /bin/menuxray.sh /usr/local/bin/menuxray.sh
    rm -f /bin/limiterxray.sh /usr/local/bin/limiterxray.sh
    rm -f /bin/botxray.sh /usr/local/bin/botxray.sh
    rm -f /bin/xray-menu /usr/bin/xray-menu
    rm -f /usr/local/bin/add_user.sh /usr/local/bin/rem_user.sh
) >>"$LOG_FILE" 2>&1 &
fun_bar $! "Limpando Instalações Antigas" || true

# --- 4) DOWNLOAD DO MENU ---
(
    curl -fLsS \
        --retry 3 \
        --retry-delay 2 \
        --retry-all-errors \
        --max-time 60 \
        --connect-timeout 10 \
        -o "$MENU_PATH" \
        "$MENU_URL" >>"$LOG_FILE" 2>&1

    if [ ! -s "$MENU_PATH" ]; then
        echo "Arquivo baixado está vazio ou a URL (404) falhou." >>"$LOG_FILE"
        exit 1
    fi

    # CORREÇÃO AQUI: Syntax error removido.
    check_head=$(head -c 10 "$MENU_PATH")
    if [[ "$check_head" != "#!/bin/bash"* ]] && [[ "$check_head" != "#!/usr/bin/env"* ]]; then
        echo "Arquivo baixado não parece um shell script válido" >>"$LOG_FILE"
        exit 1
    fi
) >>"$LOG_FILE" 2>&1 &
PID_DOWNLOAD=$!
fun_bar "$PID_DOWNLOAD" "Baixando Menu Maestro" || {
    echo -e "${VERMELHO}❌ Erro Crítico: Não foi possível baixar o menuxray.sh${RESET}"
    echo -e "   URL: ${MENU_URL}"
    echo -e "   DICA: Verifique se o arquivo menuxray.sh realmente está neste link."
    if [ -f "$MENU_BACKUP" ]; then
        cp -f "$MENU_BACKUP" "$MENU_PATH"
        echo -e "${AMARELO}⚠  Versão anterior restaurada.${RESET}"
    fi
    exit 1
}

# --- 5) VERIFICAÇÃO DE INTEGRIDADE (SHA256) ---
echo -ne "${AZUL}[Verificando Integridade]${RESET} ... "
_verify_sha256 "$MENU_PATH" "$SHA256_URL" || {
    echo -e "${VERMELHO}❌ Arquivo comprometido ou corrompido.${RESET}"
    if [ -f "$MENU_BACKUP" ]; then cp -f "$MENU_BACKUP" "$MENU_PATH"; fi
    exit 1
}
echo -e "${VERDE}OK${RESET}"

# --- 6) PERMISSÕES E SYMLINK ---
chmod 0755 "$MENU_PATH"
chown root:root "$MENU_PATH"
ln -sf "$MENU_PATH" "$SHORTCUT"

echo ""
echo -e "${AZUL}==================================================${RESET}"
echo -e "${VERDE}🎉 SISTEMA MODULAR PRONTO! (V7.5)${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo -e "  Acesso:  ${VERDE}xray-menu${RESET}"
if [ -f "$MENU_BACKUP" ]; then
    echo -e "  Backup:  ${VERDE}${MENU_BACKUP}${RESET}"
fi
echo -e "${AZUL}==================================================${RESET}"
echo ""
sleep 1

if [ ! -x "$SHORTCUT" ]; then
    echo -e "${VERMELHO}❌ Symlink ${SHORTCUT} não executável.${RESET}"
    exit 1
fi

exec "$SHORTCUT"
