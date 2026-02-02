#!/bin/bash
# xraymenu.sh - DragonCore V7.4
# Maestro: Gerencia download e execução dos módulos.
# NOMES PERSONALIZADOS: remover_user, lista_users, remover_expirados.

set -euo pipefail

# --- CONFIGURAÇÃO ---
REPO_OWNER="PhoenixxZ2023"
REPO_NAME="XrayX-TLS"
PINNED_REF="main" 

REPO_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${PINNED_REF}"
MODULES_URL="${REPO_BASE}/modulosxray"
LOCAL_BIN="/usr/local/bin"

# DIRETÓRIOS LOCAIS
XRAY_DIR="/opt/XrayTools"
USER_DB="${XRAY_DIR}/users.db"

# CORES
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

# --- FUNÇÃO DE AUTO-CORREÇÃO (CRIA DB SE FALTAR) ---
init_system() {
    if [ ! -d "$XRAY_DIR" ]; then mkdir -p "$XRAY_DIR"; fi
    if [ ! -f "$USER_DB" ]; then touch "$USER_DB"; fi
}

# --- FUNÇÃO DE EXECUÇÃO ---
run_module() {
    local script_name="$1"
    local local_path="$LOCAL_BIN/$script_name"
    local description="$2"
    
    # Se não existe ou está vazio, baixa
    if [ ! -s "$local_path" ]; then
        echo -e "${TXT_YELLOW}Baixando módulo: $description...${RESET}"
        if ! curl -fsSL -o "$local_path" "$MODULES_URL/$script_name"; then
             echo -e "${TXT_RED}Erro ao baixar $script_name! Verifique GitHub.${RESET}"
             sleep 2
             return
        fi
        chmod +x "$local_path"
    fi
    
    bash "$local_path"
}

# --- MENU ---
menu_display() {
    clear
    echo -e "${TITLE_BAR}        DRAGONCORE XRAY MANAGER        ${RESET}"
    echo ""
    
    local status="${TXT_RED}OFF${RESET}"
    if systemctl is-active --quiet xray; then status="${TXT_GREEN}ON${RESET}"; fi
    
    local users=$(wc -l < "$USER_DB" 2>/dev/null || echo 0)
    
    echo -e " STATUS: $status  |  USUÁRIOS: ${TXT_CYAN}$users${RESET}"
    echo "-----------------------------------------"
    
    echo -e "${TXT_CYAN}[01] CRIAR USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[02] REMOVER USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[03] LISTAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[04] INSTALAR/CONFIGURAR XRAY${RESET}"
    echo -e "${TXT_CYAN}[05] LIMPAR EXPIRADOS${RESET}"
    echo -e "${TXT_CYAN}[06] DESINSTALAR TUDO${RESET}"
    echo -e "${TXT_CYAN}[07] LIMITADOR CONSUMO (GB)${RESET}"
    echo -e "${TXT_CYAN}[08] BOT TELEGRAM${RESET}"
    echo -e "${TXT_CYAN}[09] BACKUP / RESTORE${RESET}"      
    echo -e "${TXT_CYAN}[10] BLOQUEAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[11] DESBLOQUEAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[12] MONITOR ONLINE${RESET}"
    echo -e "${TXT_CYAN}[00] SAIR${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " choice
    
    case "$choice" in
        1|01) run_module "add_user.sh" "Criar Usuário" ;;
        2|02) run_module "remover_user.sh" "Remover Usuário" ;;    # SEU NOME PERSONALIZADO
        3|03) run_module "lista_users.sh" "Listar Usuários" ;;     # SEU NOME PERSONALIZADO
        4|04) run_module "core_manager.sh" "Gerenciador Xray" ;;
        5|05) run_module "remover_expirados.sh" "Limpeza" ;;       # SEU NOME PERSONALIZADO
        6|06) run_module "uninstall.sh" "Desinstalador" ;;
        7|07) run_module "limiterxray.sh" "Limitador" ;;
        8|08) run_module "botxray.sh" "Instalador Bot" ;;
        9|09) run_module "backup.sh" "Backup System" ;;
        10)   run_module "block_user.sh" "Bloqueio" ;;
        11)   run_module "unblock_user.sh" "Desbloqueio" ;;
        12)   run_module "onlinexray.sh" "Monitor" ;;
        0|00) exit 0 ;;
        *) echo "Opção inválida"; sleep 1 ;;
    esac
}

# --- ENTRY POINT ---
if ! command -v curl >/dev/null; then apt-get update && apt-get install -y curl; fi
init_system
while true; do menu_display; done
