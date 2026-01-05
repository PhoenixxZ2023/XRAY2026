#!/bin/bash
USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

clear
echo -e "\033[1;31m🔒 BLOQUEAR USUÁRIO (SUSPENDER)\033[0m"
echo ""

# Lista apenas usuários ativos (que não têm 'BLOCKED')
echo "--- Usuários Ativos ---"
grep -v "BLOCKED" "$USER_DB" | awk -F'|' '{print $1}'
echo "-----------------------"
echo ""

read -rp "Digite o usuário para suspender: " user_block

if [ -z "$user_block" ]; then exit; fi

# Verifica se existe
if ! grep -q "^$user_block|" "$USER_DB"; then
    echo -e "\033[1;31m❌ Usuário não encontrado ou já bloqueado!\033[0m"
    sleep 2
    exit
fi

echo "Suspendendo..."

# 1. Remove do config.json (para derrubar conexão)
# Usa jq para filtrar removendo o cliente com esse email
jq --arg u "$user_block" '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) -= [foreach .[] as $c (0; $c; select($c.email==$u))]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

# 2. Marca no users.db (Adiciona prefixo BLOCKED-)
sed -i "s/^$user_block|/$user_block|BLOCKED-/g" "$USER_DB"

# 3. Reinicia Xray
systemctl restart xray

echo -e "\033[1;32m✅ Usuário $user_block suspenso com sucesso!\033[0m"
echo "Ele não poderá conectar até ser desbloqueado."
sleep 3
