#!/bin/bash
# uninstall.sh - Desinstalação Total e Irreversível
# Adaptação da func_page_uninstall para Módulo Independente.

# --- CORES ---
TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;41;37m' # Fundo Vermelho
RESET='\033[0m'

# --- INÍCIO ---
clear
echo -e "${TITLE_BAR}   DESINSTALAÇÃO E LIMPEZA TOTAL   ${RESET}"
echo ""
echo -e "${TXT_RED}ATENÇÃO:${RESET} Ação irreversível."
echo "Isso apagará o Xray, o Bot, o Banco de Dados e todos os scripts."
echo ""
read -rp "Continuar? [s/n]: " confirm

if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    echo "Cancelado."
    exit 0
fi

# 1. Tenta identificar o domínio para apagar o certificado depois
domain_rem=""
if [ -f "/usr/local/etc/xray/preset.json" ]; then
    domain_rem=$(grep -oP '"domain": "\K[^"]+' /usr/local/etc/xray/preset.json 2>/dev/null || true)
fi
if [ -z "$domain_rem" ] && [ -f "/opt/XrayTools/active_domain" ]; then
    domain_rem=$(cat "/opt/XrayTools/active_domain" 2>/dev/null || true)
fi

echo ""
echo -e "${TXT_YELLOW}>>> Parando serviços...${RESET}"
# O "|| true" impede que o script pare se o serviço não existir
systemctl stop xray >/dev/null 2>&1 || true
systemctl disable xray >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true
systemctl disable botxray >/dev/null 2>&1 || true

echo -e "${TXT_YELLOW}>>> Removendo serviços do sistema...${RESET}"
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/botxray.service
systemctl daemon-reload >/dev/null 2>&1 || true

echo -e "${TXT_YELLOW}>>> Removendo arquivos do Xray e Configs...${RESET}"
rm -f /usr/local/bin/xray
rm -rf /usr/local/share/xray
rm -rf /usr/local/etc/xray
rm -rf /var/log/xray
rm -rf /opt/XrayTools       # Apaga o Banco de Dados
rm -rf /root/backups
rm -rf /opt/DragonCoreSSL   # Apaga chaves SSL locais

echo -e "${TXT_YELLOW}>>> Removendo scripts e módulos...${RESET}"
# Remove atalhos globais
rm -f /usr/bin/xray-menu
rm -f /usr/local/bin/xray-menu

# Remove Menu Principal e Instalador
rm -f /usr/local/bin/menuxray.sh
rm -f /usr/local/bin/installxray.sh

# Remove TODOS os módulos (Nomes novos e antigos para garantir)
rm -f /usr/local/bin/add_user.sh
rm -f /usr/local/bin/remover_user.sh
rm -f /usr/local/bin/lista_users.sh
rm -f /usr/local/bin/core_manager.sh
rm -f /usr/local/bin/remover_expirados.sh
rm -f /usr/local/bin/backup.sh
rm -f /usr/local/bin/limiterxray.sh
rm -f /usr/local/bin/botxray.sh
rm -f /usr/local/bin/onlinexray.sh
rm -f /usr/local/bin/certxray.sh
rm -f /usr/local/bin/block_user.sh
rm -f /usr/local/bin/unblock_user.sh
rm -f /usr/local/bin/uninstall.sh

# Limpeza de Certificado no Certbot (se existir domínio salvo)
if command -v certbot >/dev/null 2>&1; then
    if [ -n "$domain_rem" ]; then
        echo -e "${TXT_YELLOW}>>> Removendo certificado SSL ($domain_rem)...${RESET}"
        certbot delete --cert-name "$domain_rem" --non-interactive >/dev/null 2>&1 || true
    fi
fi

echo -e "${TXT_YELLOW}>>> Limpando Cron (Tarefas agendadas)...${RESET}"
# Remove apenas as linhas do limiterxray e renew_cert
(crontab -l 2>/dev/null | grep -v "limiterxray" | grep -v "renew_cert") | crontab -

echo ""
echo -e "${TXT_GREEN}Desinstalação concluída com sucesso.${RESET}"
exit 0
