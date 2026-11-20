#!/bin/bash
# uninstall.sh - TURBONET XRAY V1.1
# Correções aplicadas V1.1:
#   - Corrigido `find ... -print -quit` na etapa de backups residuais (-quit sem -print não emitia saída)
#   - Verificação por `ps -o args=` para encerrar apenas o processo pai `menuxray` (sem matar SSH bash)
#   - Removidos todos os módulos novos, wrappers setuid (`wrap_*`), scripts auxiliares e usuário `botxray`
#   - Verificação exata de `/etc/letsencrypt/live/${ACTIVE_DOMAIN}` antes de oferecer remoção do Certbot
#   - Limpeza segura do crontab sem falhar sob `set -o pipefail` quando não restam entradas

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
TXT_CYAN='\033[1;36m'
TITLE_BAR='\033[1;41;37m'
RESET='\033[0m'

# --- VERIFICAÇÃO DE ROOT ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
fi

ask_sn() {
    local prompt="${1:-Confirmar?}"
    local ans=""
    while true; do
        read -rp "$prompt [s/n]: " ans || return 1
        ans="${ans,,}"
        case "$ans" in
            s|sim) return 0 ;;
            n|nao|não) return 1 ;;
            *) echo "Digite s (sim) ou n (não)." ;;
        esac
    done
}

# Lê ACTIVE_DOMAIN antes de apagar /opt/XrayTools
ACTIVE_DOMAIN=""
if [ -f "/opt/XrayTools/active_domain" ]; then
    ACTIVE_DOMAIN=$(tr -d '[:space:][:cntrl:]' < "/opt/XrayTools/active_domain" 2>/dev/null || true)
fi

BACKUP_DIR="/root/backups"

clear
echo -e "${TITLE_BAR}   DESINSTALAÇÃO TOTAL DO TURBONET XRAY   ${RESET}"
echo ""
echo -e "${TXT_YELLOW}Será removido permanentemente:${RESET}"
echo " • Xray Core (binário, configs, serviço)"
echo " • Bot Telegram (serviço, wrappers e usuário de sistema)"
echo " • Usuários e banco de dados (/opt/XrayTools)"
echo " • Certificados SSL (/opt/TurbonetCoreSSL)"
echo " • Todos os scripts e atalhos do TURBONET XRAY (/usr/local/bin)"
echo " • Entradas de cron do TURBONET XRAY"
echo ""
echo -e "${TXT_RED}⚠  Esta operação é IRREVERSÍVEL sem um backup prévio.${RESET}"
echo ""

# --- OFERTA DE BACKUP ANTES DE DESINSTALAR ---
BACKUP_SCRIPT="/usr/local/bin/backup.sh"
if [ -f "$BACKUP_SCRIPT" ]; then
    if ask_sn "Deseja criar um backup antes de desinstalar"; then
        echo -e "${TXT_CYAN}Executando backup...${RESET}"
        bash "$BACKUP_SCRIPT" || echo -e "${TXT_YELLOW}⚠  Backup falhou — continuando mesmo assim.${RESET}"
        echo ""
    fi
fi

# --- CONFIRMAÇÃO ÚNICA ---
if ! ask_sn "Confirmar desinstalação TOTAL"; then
    echo "Cancelado."
    exit 0
fi

echo ""
echo -e "${TXT_YELLOW}>>> Desinstalando...${RESET}"

# --- 1) SERVIÇOS ---
echo -n " Parando serviços... "
for svc in xray botxray turbonet-udpgw udpgw checkuser check_api; do
    systemctl stop    "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
done
echo -e "${TXT_GREEN}OK${RESET}"

# --- 2) UNITS SYSTEMD ---
echo -n " Removendo units systemd... "
rm -f  /etc/systemd/system/xray.service
rm -f  /etc/systemd/system/botxray.service
rm -f  /etc/systemd/system/turbonet-udpgw.service
rm -f  /etc/systemd/system/udpgw.service
rm -f  /etc/systemd/system/checkuser.service
rm -f  /etc/systemd/system/check_api.service
rm -rf /etc/systemd/system/xray.service.d
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed  >/dev/null 2>&1 || true
echo -e "${TXT_GREEN}OK${RESET}"

# --- 3) DADOS, CONFIGS E USUÁRIO DO BOT ---
echo -n " Removendo dados, configs e conta do bot... "
rm -rf /usr/local/etc/xray
rm -rf /opt/XrayTools
rm -rf /opt/TurbonetCoreSSL
rm -rf /var/log/xray
if id -u botxray >/dev/null 2>&1; then
    userdel botxray >/dev/null 2>&1 || true
fi
echo -e "${TXT_GREEN}OK${RESET}"

# --- 4) BINÁRIO XRAY ---
echo -n " Removendo binário xray... "
rm -f /usr/local/bin/xray
rm -f /usr/local/share/xray/geoip.dat   2>/dev/null || true
rm -f /usr/local/share/xray/geosite.dat 2>/dev/null || true
rmdir /usr/local/share/xray             2>/dev/null || true
echo -e "${TXT_GREEN}OK${RESET}"

# --- 5) SCRIPTS, WRAPPERS E ATALHOS ---
echo -n " Removendo scripts e wrappers TURBONET XRAY... "
rm -f /tmp/xray-install.lock /tmp/limiterxray.lock /tmp/menuxray.lock
rm -f /usr/bin/xray-menu
rm -f /usr/local/bin/xray-menu

scripts_to_remove=(
    menuxray.sh menuxray.sh.bak installxray.sh
    core_manager.sh limiterxray.sh botxray.sh onlinexray.sh
    certxray.sh backup.sh uninstall.sh gerenciar_xray.sh
    add_user.sh remover_user.sh rem_user.sh renew_user.sh
    block_user.sh unblock_user.sh lista_users.sh list_users.sh
    remover_expirados.sh purge_users.sh
    bbr.sh check_api.sh vercel_relay.sh checkuser.sh
    udpgw.sh ssh_fallback.sh
    backup_bot.sh restore_bot.sh ssh_sync.sh
)
for scr in "${scripts_to_remove[@]}"; do
    rm -f "/usr/local/bin/${scr}"
done

wrappers_to_remove=(
    wrap_add_user wrap_remover_user wrap_block_user wrap_unblock_user
    wrap_renew_user wrap_backup_bot wrap_restore_bot wrap_ssh_sync
)
for wrp in "${wrappers_to_remove[@]}"; do
    rm -f "/usr/local/bin/${wrp}"
done
echo -e "${TXT_GREEN}OK${RESET}"

# --- 6) CRON (apenas entradas TURBONET XRAY) ---
echo -n " Limpando cron... "
current_cron=$(crontab -l 2>/dev/null || true)
if [ -n "$current_cron" ]; then
    filtered_cron=$(printf '%s\n' "$current_cron" | grep -Ev 'limiterxray|renew_cert|turbonet' || true)
    if [ -n "$filtered_cron" ]; then
        printf '%s\n' "$filtered_cron" | crontab - 2>/dev/null || true
    else
        crontab -r 2>/dev/null || true
    fi
fi
echo -e "${TXT_GREEN}OK${RESET}"

# --- 7) DADOS CERTBOT / LET'S ENCRYPT (opcional) ---
LE_LIVE="/etc/letsencrypt/live"
if [ -n "${ACTIVE_DOMAIN:-}" ] && [ -d "${LE_LIVE}/${ACTIVE_DOMAIN}" ]; then
    echo ""
    echo -e "${TXT_YELLOW}Dados do Let's Encrypt encontrados para:${RESET} ${TXT_CYAN}${ACTIVE_DOMAIN}${RESET}"
    if ask_sn "Remover dados do certbot para este domínio"; then
        certbot delete --cert-name "$ACTIVE_DOMAIN" --non-interactive >/dev/null 2>&1 || \
            rm -rf "${LE_LIVE}/${ACTIVE_DOMAIN}" 2>/dev/null || true
        echo -e " ${TXT_GREEN}Dados certbot removidos.${RESET}"
    fi
elif [ -d "$LE_LIVE" ] && find "$LE_LIVE" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
    echo ""
    echo -e "${TXT_YELLOW}⚠  Dados do Let's Encrypt encontrados em ${LE_LIVE}.${RESET}"
    echo -e "${TXT_YELLOW}   Remova manualmente com: certbot delete --cert-name <dominio>${RESET}"
fi

# --- 8) BACKUPS RESIDUAIS ---
if [ -d "$BACKUP_DIR" ] && \
   find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" -print -quit 2>/dev/null | grep -q .; then
    echo ""
    echo -e "${TXT_YELLOW}Backups encontrados em ${BACKUP_DIR}:${RESET}"
    while IFS= read -r -d '' bfile; do
        local_size=$(du -sh "$bfile" 2>/dev/null | cut -f1)
        printf "  %6s  %s\n" "$local_size" "$(basename "$bfile")"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" -print0 | sort -z)
    echo ""
    if ask_sn "Remover backups também"; then
        rm -rf "$BACKUP_DIR"
        echo -e " ${TXT_GREEN}Backups removidos.${RESET}"
    else
        echo -e " ${TXT_CYAN}Backups mantidos em ${BACKUP_DIR}.${RESET}"
    fi
fi

echo ""
echo -e "${TXT_GREEN}✅ Desinstalação concluída.${RESET}"
echo -e "${TXT_YELLOW}   O sistema está limpo. Reinicie a VPS se necessário.${RESET}"
sleep 2

# Encerra o processo pai apenas se for explicitamente o menuxray.sh
PPID_MENU="${PPID:-0}"
if [ "$PPID_MENU" -gt 1 ]; then
    parent_args=$(ps -o args= -p "$PPID_MENU" 2>/dev/null || true)
    if [[ "${parent_args:-}" == *"menuxray"* ]]; then
        kill "$PPID_MENU" 2>/dev/null || true
    fi
fi

exit 0
