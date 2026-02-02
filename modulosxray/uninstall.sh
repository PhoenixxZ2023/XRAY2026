#!/bin/bash
# uninstall.sh
TXT_RED='\033[1;31m'
RESET='\033[0m'

clear
echo -e "${TXT_RED}DESINSTALAÇÃO TOTAL${RESET}"
read -rp "Tem certeza? [s/n]: " confirm
if [[ "$confirm" != "s" ]]; then exit 0; fi

systemctl stop xray botxray || true
systemctl disable xray botxray || true
rm -f /etc/systemd/system/xray.service /etc/systemd/system/botxray.service
systemctl daemon-reload

rm -rf /usr/local/bin/xray /usr/local/share/xray /usr/local/etc/xray /var/log/xray
rm -rf /opt/XrayTools /opt/DragonCoreSSL

# Remove atalhos locais
rm -f /usr/local/bin/xray-menu
rm -f /usr/local/bin/limiterxray.sh /usr/local/bin/onlinexray.sh /usr/local/bin/botxray.sh

# Remove Cron
crontab -l 2>/dev/null | grep -v "limiterxray.sh" | crontab -

echo "Desinstalação concluída."
