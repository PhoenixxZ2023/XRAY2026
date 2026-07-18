#!/bin/bash
# udpgw.sh - TURBONET XRAY V1.0
# Instala e gerencia o badvpn-udpgw — resolve tráfego UDP (DNS, YouTube,
# WhatsApp, chamadas) dentro do túnel Xray/VLESS.
#
# Sem UDPGW: cliente conecta mas não abre apps (UDP bloqueado no túnel)
# Com UDPGW: todo tráfego UDP é encaminhado corretamente pelo túnel
#
# Configuração no app cliente:
#   Ativar UDPGW e apontar para: 127.0.0.1:7300
#
# Correções Aplicadas:
#   - Limpeza garantida do diretório de compilação no cenário de sucesso
#   - Segurança no path absoluto do SystemD

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

UDPGW_PORT=7300
UDPGW_MAX_CLIENTS=1000
UDPGW_LOG="/tmp/turbonet_udpgw.log"
UDPGW_PID_FILE="/tmp/turbonet_udpgw.pid"
UDPGW_SERVICE="/etc/systemd/system/turbonet-udpgw.service"
UDPGW_BIN="/usr/local/bin/badvpn-udpgw"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

[ "${EUID:-$(id -u)}" -ne 0 ] && { echo -e "${TXT_RED}❌ Execute como root!${RESET}"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    else echo -e "${TXT_RED}❌ Gerenciador não detectado.${RESET}"; exit 1; fi
}

ensure_pkg() {
    local bin="$1" pkg="$2"
    command -v "$bin" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >>"$UDPGW_LOG" 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >>"$UDPGW_LOG" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$UDPGW_LOG" 2>&1 ;;
    esac
}

_is_running() {
    systemctl is-active --quiet turbonet-udpgw 2>/dev/null || \
    { [ -f "$UDPGW_PID_FILE" ] && kill -0 "$(cat "$UDPGW_PID_FILE")" 2>/dev/null; }
}

_get_status() {
    if systemctl is-active --quiet turbonet-udpgw 2>/dev/null; then
        echo -e "${TXT_GREEN}ATIVO (systemd)${RESET}"
    elif [ -f "$UDPGW_PID_FILE" ] && kill -0 "$(cat "$UDPGW_PID_FILE")" 2>/dev/null; then
        echo -e "${TXT_YELLOW}ATIVO (manual)${RESET}"
    else
        echo -e "${TXT_RED}INATIVO${RESET}"
    fi
}

_install_udpgw() {
    echo -e "${TXT_YELLOW}Instalando badvpn-udpgw...${RESET}"
    : > "$UDPGW_LOG"

    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >>"$UDPGW_LOG" 2>&1 || true; _APT_UPDATED=1; }
            # Tenta instalar pacote pronto primeiro
            if apt-get install -y badvpn >>"$UDPGW_LOG" 2>&1; then
                echo -e "${TXT_GREEN}✅ badvpn instalado via apt.${RESET}"
                return 0
            fi
            # Fallback: compilar do fonte
            echo -e "${TXT_YELLOW}Pacote não disponível — compilando do fonte...${RESET}"
            apt-get install -y cmake make gcc libssl-dev >>"$UDPGW_LOG" 2>&1
            ;;
        dnf|yum)
            "$_PKG_MANAGER" install -y cmake make gcc openssl-devel >>"$UDPGW_LOG" 2>&1
            ;;
    esac

    # Compilar badvpn-udpgw do GitHub
    local tmp_dir; tmp_dir=$(mktemp -d)
    cd "$tmp_dir"

    echo -e "${TXT_YELLOW}Baixando código fonte...${RESET}"
    if ! curl -fsSL --retry 3 --max-time 60 \
        "https://github.com/ambrop72/badvpn/archive/refs/heads/master.tar.gz" \
        -o badvpn.tar.gz >>"$UDPGW_LOG" 2>&1; then
        echo -e "${TXT_RED}❌ Falha ao baixar badvpn.${RESET}"
        cd /; rm -rf "$tmp_dir"; return 1
    fi

    tar -xzf badvpn.tar.gz >>"$UDPGW_LOG" 2>&1
    cd badvpn-master

    mkdir build && cd build
    if ! cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
         >>"$UDPGW_LOG" 2>&1; then
        echo -e "${TXT_RED}❌ Falha no cmake.${RESET}"
        cd /; rm -rf "$tmp_dir"; return 1
    fi

    if ! make -j"$(nproc)" >>"$UDPGW_LOG" 2>&1; then
        echo -e "${TXT_RED}❌ Falha na compilação.${RESET}"
        cd /; rm -rf "$tmp_dir"; return 1
    fi

    install -m 755 udpgw/badvpn-udpgw "$UDPGW_BIN"
    cd /; rm -rf "$tmp_dir" # Limpeza garantida após o sucesso
    echo -e "${TXT_GREEN}✅ badvpn-udpgw compilado e instalado.${RESET}"
}

_create_service() {
    local port="${1:-$UDPGW_PORT}"
    local max="${2:-$UDPGW_MAX_CLIENTS}"

    cat > "$UDPGW_SERVICE" << EOF
[Unit]
Description=TURBONET XRAY - UDPGW Service
After=network.target xray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${port} --max-clients ${max} --max-connections-for-client 10
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable turbonet-udpgw >/dev/null 2>&1
    systemctl restart turbonet-udpgw >/dev/null 2>&1
    sleep 2

    if systemctl is-active --quiet turbonet-udpgw 2>/dev/null; then
        echo -e "${TXT_GREEN}✅ UDPGW iniciado na porta ${port}!${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}Configure no app cliente:${RESET}"
        echo -e "  UDPGW:  ${TXT_YELLOW}127.0.0.1:${port}${RESET}"
        echo -e "  Ativar: ${TXT_YELLOW}Enable UDPGW = true${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}Apps compatíveis:${RESET}"
        echo "  • HTTP Injector"
        echo "  • HTTP Custom"
        echo "  • NapsternetV"
        echo "  • V2RayNG (modo UDPGW)"
        echo "  • OpenVPN (via udpgw)"
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar UDPGW.${RESET}"
        journalctl -u turbonet-udpgw -n 10 --no-pager 2>/dev/null || true
    fi
}

_remove_service() {
    systemctl stop    turbonet-udpgw >/dev/null 2>&1 || true
    systemctl disable turbonet-udpgw >/dev/null 2>&1 || true
    rm -f "$UDPGW_SERVICE"
    systemctl daemon-reload
    echo -e "${TXT_GREEN}✅ UDPGW removido.${RESET}"
}

# --- MENU ---
while true; do
    clear
    echo -e "${TITLE_BAR}   UDPGW — TURBONET XRAY   ${RESET}"
    echo ""
    echo -e " Status: $(_get_status)"
    echo -e " Porta:  ${TXT_CYAN}${UDPGW_PORT}${RESET} (listen: 127.0.0.1)"
    echo ""
    echo -e " ${TXT_YELLOW}O que é UDPGW:${RESET}"
    echo "  Resolve tráfego UDP (YouTube, WhatsApp, DNS) dentro"
    echo "  do túnel Xray. Sem UDPGW o cliente conecta mas não"
    echo "  abre aplicativos."
    echo ""
    echo -e "${TXT_CYAN}[1] Instalar e ativar UDPGW${RESET}"
    echo -e "${TXT_CYAN}[2] Iniciar / Reiniciar${RESET}"
    echo -e "${TXT_RED}[3] Parar UDPGW${RESET}"
    echo -e "${TXT_RED}[4] Remover UDPGW${RESET}"
    echo -e "${TXT_CYAN}[5] Ver logs${RESET}"
    echo -e "${TXT_CYAN}[6] Alterar porta ou max clientes${RESET}"
    echo -e "${TXT_CYAN}[0] Voltar${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "${opt:-0}" in
        1)
            # Instalar
            if ! command -v badvpn-udpgw &>/dev/null && [ ! -f "$UDPGW_BIN" ]; then
                _install_udpgw || { read -rp "Enter..."; continue; }
            else
                echo -e "${TXT_GREEN}badvpn-udpgw já instalado.${RESET}"
            fi
            _create_service "$UDPGW_PORT" "$UDPGW_MAX_CLIENTS"
            read -rp "Enter..."
            ;;
        2)
            systemctl restart turbonet-udpgw >/dev/null 2>&1 || true
            sleep 1
            systemctl is-active --quiet turbonet-udpgw && \
                echo -e "${TXT_GREEN}✅ UDPGW reiniciado.${RESET}" || \
                echo -e "${TXT_RED}❌ Falha.${RESET}"
            read -rp "Enter..."
            ;;
        3)
            systemctl stop turbonet-udpgw >/dev/null 2>&1 || true
            echo -e "${TXT_GREEN}✅ UDPGW parado.${RESET}"
            read -rp "Enter..."
            ;;
        4)
            read -rp "Confirmar remoção do UDPGW? [s/N]: " conf
            [[ "${conf:-n}" =~ ^[Ss]$ ]] && _remove_service || echo "Cancelado."
            read -rp "Enter..."
            ;;
        5)
            echo -e "${TXT_CYAN}=== Journal UDPGW ===${RESET}"
            journalctl -u turbonet-udpgw -n 30 --no-pager 2>/dev/null || echo "Sem logs."
            read -rp "Enter..."
            ;;
        6)
            read -rp "Nova porta [${UDPGW_PORT}]: " new_port
            [ -z "${new_port:-}" ] && new_port="$UDPGW_PORT"
            read -rp "Max clientes [${UDPGW_MAX_CLIENTS}]: " new_max
            [ -z "${new_max:-}" ] && new_max="$UDPGW_MAX_CLIENTS"
            UDPGW_PORT="$new_port"
            UDPGW_MAX_CLIENTS="$new_max"
            _create_service "$UDPGW_PORT" "$UDPGW_MAX_CLIENTS"
            read -rp "Enter..."
            ;;
        0) exit 0 ;;
        *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
