#!/bin/bash
USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

clear
echo -e "\033[1;32m🔓 DESBLOQUEAR USUÁRIO (REATIVAR)\033[0m"
echo ""

# Lista apenas usuários bloqueados
echo "--- Usuários Suspensos ---"
grep "|BLOCKED-" "$USER_DB" | awk -F'|' '{print $1}'
echo "--------------------------"
echo ""

read -rp "Digite o usuário para desbloquear: " user_unblock

if [ -z "$user_unblock" ]; then exit; fi

# Verifica se está bloqueado
if ! grep -q "^$user_unblock|BLOCKED-" "$USER_DB"; then
    echo -e "\033[1;31m❌ Usuário não encontrado na lista de bloqueios!\033[0m"
    sleep 2
    exit
fi

echo "Reativando..."

# 1. Recupera o UUID Original (removendo o prefixo BLOCKED-)
# O formato no DB é: user|BLOCKED-uuid-real|data
full_line=$(grep "^$user_unblock|" "$USER_DB")
blocked_uuid=$(echo "$full_line" | cut -d'|' -f2)
real_uuid=${blocked_uuid#"BLOCKED-"} # Remove o prefixo

# 2. Adiciona de volta ao config.json
# Usa jq para adicionar o objeto do cliente
jq --arg u "$user_unblock" --arg id "$real_uuid" '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) += [{"id": $id, "email": $u, "level": 0}]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

# 3. Corrige o users.db (Remove BLOCKED-)
sed -i "s/|BLOCKED-/|/g" "$USER_DB"

# 4. Reinicia Xray
systemctl restart xray

echo -e "\033[1;32m✅ Usuário $user_unblock reativado!\033[0m"
sleep 3
