#!/bin/bash
# purge_users.sh
USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'

today=$(date +%F)
count=0
found=false

if [ ! -s "$USER_DB" ]; then echo "DB vazio."; exit 0; fi

while IFS='|' read -r nick uuid expiry; do
    if [[ "$expiry" < "$today" ]]; then
        echo -e "Vencido: ${TXT_RED}$nick${RESET}"
        found=true
        ((count++))
    fi
done < "$USER_DB"

if [ "$found" = false ]; then echo "Nenhum vencido."; exit 0; fi

read -rp "Remover $count usuários? [s/n]: " confirm
if [[ "$confirm" != "s" ]]; then exit 0; fi

> "${USER_DB}.tmp"
while IFS='|' read -r nick uuid expiry; do
    if [[ "$expiry" < "$today" ]]; then
        jq --arg id "$uuid" \
           '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |= map(select(.id != $id))' \
           "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    else
        echo "${nick}|${uuid}|${expiry}" >> "${USER_DB}.tmp"
    fi
done < "$USER_DB"
mv "${USER_DB}.tmp" "$USER_DB"

systemctl restart xray
echo -e "${TXT_GREEN}Limpeza concluída.${RESET}"
sleep 2
