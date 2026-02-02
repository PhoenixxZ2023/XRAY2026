#!/bin/bash
# rem_user.sh - Remoção de Usuário (Modular)
set -euo pipefail

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
TXT_GREEN='\033[1;32m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

clear
echo -e "${TITLE_BAR}   REMOVER USUÁRIO   ${RESET}"
read -rp "Nome ou UUID: " identifier

if [ -z "$identifier" ]; then exit 0; fi
if [ ! -f "$CONFIG_PATH" ]; then echo "Erro config."; exit 1; fi

# Remove do JSON
jq --arg id "$identifier" \
    '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |= map(select(.id != $id and .email != $id))' \
    "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

# Remove do DB (Sem usar regex inseguro no sed, usando awk para filtrar)
if [ -f "$USER_DB" ]; then
    awk -F'|' -v id="$identifier" '($1!=id && $2!=id){print $0}' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
fi

systemctl reload xray >/dev/null 2>&1 || systemctl restart xray >/dev/null 2>&1
echo -e "${TXT_GREEN}Removido com sucesso.${RESET}"
sleep 1
