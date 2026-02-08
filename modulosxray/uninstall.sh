#!/bin/bash
# uninstall.sh - Desinstalação Total e Forçada (FIX)
# Remove vestígios e não falha se algo não existir.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO";' ERR

# --- CORES ---
TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;41;37m'
RESET='\033[0m'

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
  fi
}

require_root

clear
echo -e "${TITLE_BAR}   DESINSTALAÇÃO E LIMPEZA TOTAL   ${RESET}"
echo ""
echo -e "${TXT_RED}ATENÇÃO:${RESET} Esta ação apagará TUDO:"
echo " • Xray Core e Bot Telegram"
echo " • Usuários, configs e certificados"
echo " • Scripts e módulos"
echo ""
echo -e "${TXT_YELLOW}Digite CONFIRMAR para continuar:${RESET}"
read -r confirm

if [ "${confirm:-}" != "CONFIRMAR" ]; then
  echo "Operação cancelada."
  exit 0
fi

echo ""
echo -e "${TXT_YELLOW}>>> Iniciando limpeza forçada...${RESET}"

echo "1. Parando serviços..."
systemctl stop xray >/dev/null 2>&1 || true
systemctl disable xray >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true
systemctl disable botxray >/dev/null 2>&1 || true

echo "2. Removendo systemd units e drop-ins..."
rm -f /etc/systemd/system/xray.service || true
rm -rf /etc/systemd/system/xray.service.d || true
rm -f /etc/systemd/system/botxray.service || true
rm -rf /etc/systemd/system/botxray.service.d || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed >/dev/null 2>&1 || true

echo "3. Apagando pastas e dados..."
rm -rf /usr/local/etc/xray || true
rm -rf /etc/xray || true
rm -rf /opt/XrayTools || true
rm -rf /opt/DragonCoreSSL || true
rm -rf /var/log/xray || true

# Instalações comuns do Xray-install
rm -f /usr/local/bin/xray || true
rm -rf /usr/local/share/xray || true

echo "4. Removendo scripts..."
rm -f /usr/bin/xray-menu /usr/local/bin/xray-menu || true
rm -f /usr/local/bin/menuxray.sh /usr/local/bin/installxray.sh || true

rm -f /usr/local/bin/core_manager.sh \
      /usr/local/bin/limiterxray.sh \
      /usr/local/bin/botxray.sh \
      /usr/local/bin/onlinexray.sh \
      /usr/local/bin/certxray.sh \
      /usr/local/bin/backup.sh \
      /usr/local/bin/add_user.sh \
      /usr/local/bin/block_user.sh \
      /usr/local/bin/unblock_user.sh \
      /usr/local/bin/uninstall.sh || true

rm -f /usr/local/bin/remover_user.sh \
      /usr/local/bin/rem_user.sh \
      /usr/local/bin/lista_users.sh \
      /usr/local/bin/list_users.sh \
      /usr/local/bin/remover_expirados.sh \
      /usr/local/bin/purge_users.sh || true

echo "5. Limpando crontab..."
( crontab -l 2>/dev/null \
  | grep -v "limiterxray" \
  | grep -v "renew_cert" \
  | crontab - 2>/dev/null ) || true

echo ""
echo -e "${TXT_GREEN}VPS LIMPA! Todos os arquivos do DragonCore foram removidos.${RESET}"
exit 0
