#!/bin/bash
# block_user.sh - Módulo de Bloqueio Seguro V7.3
# Método: Scramble (Troca UUID por falso e renomeia para LOCKED_)

# CONFIGURAÇÃO
USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

# CORES
TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

clear
echo -e "${TXT_RED}🔒 BLOQUEAR USUÁRIO (SUSPENDER)${RESET}"
echo "Isso impedirá a conexão, mas manterá o cadastro."
echo ""

# Verifica dependências
if ! command -v jq &> /dev/null; then echo "Erro: jq não instalado."; exit 1; fi
if ! command -v uuidgen &> /dev/null; then apt-get install uuid-runtime -y > /dev/null 2>&1; fi

# --- LISTAR APENAS USUÁRIOS ATIVOS (NÃO BLOQUEADOS) ---
echo "--- Usuários Ativos ---"
if [ -f "$CONFIG_PATH" ]; then
    jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients[].email' "$CONFIG_PATH" | grep -v "LOCKED_" | while read -r line; do
        echo " • $line"
    done
else
    echo "Erro: config.json não encontrado."
    exit 1
fi
echo "-----------------------"
echo ""

read -rp "Digite o usuário para suspender: " user_block

if [ -z "$user_block" ]; then exit; fi

# Verifica se existe no Banco de Dados (Grep com ^ para inicio de linha)
if ! grep -q "^$user_block|" "$USER_DB"; then
    echo -e "${TXT_RED}❌ Usuário não encontrado no banco de dados!${RESET}"
    sleep 2
    exit
fi

# Verifica se JÁ está bloqueado no Config
if grep -q "\"email\": \"LOCKED_$user_block\"" "$CONFIG_PATH"; then
    echo -e "${TXT_YELLOW}⚠️  Este usuário já está bloqueado!${RESET}"
    sleep 2
    exit
fi

echo "Suspendendo acesso..."

# --- LÓGICA DE BLOQUEIO (SCRAMBLE) ---
# 1. Gera UUID falso
FAKE_UUID=$(uuidgen)

# 2. Edita o Config: 
#    - Muda o email para LOCKED_nome
#    - Muda o ID para o UUID Falso
jq --arg nick "$user_block" --arg locked "LOCKED_$user_block" --arg fake "$FAKE_UUID" \
   '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(if .email == $nick then .email = $locked | .id = $fake else . end)' \
   "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

# 3. Reinicia Xray para derrubar conexão
systemctl restart xray

echo -e "${TXT_GREEN}✅ Usuário $user_block suspenso com sucesso!${RESET}"
echo "UUID alterado para falso e prefixo LOCKED_ adicionado."
sleep 3
