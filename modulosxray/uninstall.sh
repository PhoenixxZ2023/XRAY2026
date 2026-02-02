#!/bin/bash
# uninstall.sh - Desinstalação Total e Forçada
# Garante a limpeza mesmo se a instalação anterior falhou.

# Cores
TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

clear
echo -e "${TXT_RED}=========================================${RESET}"
echo -e "${TXT_RED}      DESINSTALAÇÃO TOTAL DRAGONCORE     ${RESET}"
echo -e "${TXT_RED}=========================================${RESET}"
echo ""
echo "Isso removerá:"
echo " • Serviço Xray e Bot (se existirem)"
echo " • Todos os Scripts e Módulos"
echo " • Banco de Dados de Usuários"
echo " • Certificados e Configurações"
echo ""
read -rp "Tem certeza absoluta? [s/n]: " confirm
if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    echo "Cancelado."
    exit 0
fi

echo ""
echo -e "${TXT_YELLOW}>>> Parando serviços...${RESET}"
# O "|| true" garante que o script NÃO PARE se o serviço não existir
systemctl stop xray >/dev/null 2>&1 || true
systemctl disable xray >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true
systemctl disable botxray >/dev/null 2>&1 || true

echo -e "${TXT_YELLOW}>>> Removendo da inicialização...${RESET}"
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/botxray.service
systemctl daemon-reload >/dev/null 2>&1 || true

echo -e "${TXT_YELLOW}>>> Removendo binários e pastas de dados...${RESET}"
rm -rf /usr/local/etc/xray
rm -rf /opt/XrayTools
rm -rf /opt/DragonCoreSSL
rm -rf /var/log/xray
rm -f /usr/local/bin/xray

echo -e "${TXT_YELLOW}>>> Removendo scripts do menu e módulos...${RESET}"
# Remove atalhos globais
rm -f /usr/bin/xray-menu
rm -f /usr/local/bin/xray-menu

# Remove o menu principal e instalador
rm -f /usr/local/bin/menuxray.sh
rm -f /usr/local/bin/installxray.sh

# Remove TODOS os módulos possíveis (nomes novos e antigos)
rm -f /usr/local/bin/core_manager.sh
rm -f /usr/local/bin/limiterxray.sh
rm -f /usr/local/bin/botxray.sh
rm -f /usr/local/bin/onlinexray.sh
rm -f /usr/local/bin/certxray.sh
rm -f /usr/local/bin/backup.sh
rm -f /usr/local/bin/add_user.sh
rm -f /usr/local/bin/block_user.sh
rm -f /usr/local/bin/unblock_user.sh
# Nomes antigos/variáveis para garantir limpeza
rm -f /usr/local/bin/rem_user.sh
rm -f /usr/local/bin/remover_user.sh
rm -f /usr/local/bin/list_users.sh
rm -f /usr/local/bin/lista_users.sh
rm -f /usr/local/bin/purge_users.sh
rm -f /usr/local/bin/remover_expirados.sh

# Remove o próprio desinstalador por último
rm -f /usr/local/bin/uninstall.sh

echo -e "${TXT_YELLOW}>>> Limpando tarefas agendadas (Cron)...${RESET}"
# Remove apenas linhas relacionadas ao script, preserva outros crons do sistema
(crontab -l 2>/dev/null | grep -v "limiterxray" | grep -v "renew_cert") | crontab -

echo ""
echo -e "${TXT_GREEN}✅ SUCESSO! O sistema foi completamente limpo.${RESET}"
