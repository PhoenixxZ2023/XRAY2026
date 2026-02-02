#!/bin/bash
# botxray.sh - Módulo de Instalação do Bot Telegram (DragonCore V7.3)
# Este script substitui a antiga função func_install_bot do menu.

# --- CONFIGURAÇÃO ---
# Base do repositório para baixar o botxray.py
REPO_BASE="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main"

# --- CORES ---
VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}      🤖 CONFIGURAÇÃO DO BOT TELEGRAM 🤖      ${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""

# 1. Pré-Verificação de Dependências (Para garantir que rode sozinho)
echo "Verificando ambiente..."
if ! command -v python3 &> /dev/null; then
    echo -e "${AMARELO}Instalando Python3...${RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y > /dev/null 2>&1
    apt-get install python3 python3-pip -y > /dev/null 2>&1
fi

# Garante a biblioteca do Telegram (Break system packages para Debian 12+)
pip3 install python-telegram-bot --break-system-packages > /dev/null 2>&1

echo -e "${VERDE}Dependências verificadas.${RESET}"
echo ""

read -rp "Deseja continuar? [s/n]: " continue_opt
if [[ "$continue_opt" != "s" ]]; then echo "Cancelado."; exit 0; fi

# --- PASSO 1: DADOS TÉCNICOS ---
echo ""
echo -e "${AMARELO}1. Digite o Token do BotFather:${RESET}"
read -rp "Token: " bot_token

echo ""
echo -e "${AMARELO}2. Digite o SEU ID Numérico (Admin):${RESET}"
echo "Exemplo: 123456789"
read -rp "ID Admin: " admin_id

if [ -z "$bot_token" ] || [ -z "$admin_id" ]; then
    echo -e "${VERMELHO}❌ Dados incompletos!${RESET}"; sleep 2; exit 1
fi

# --- VALIDAÇÃO API ---
echo ""
echo "Consultando dados..."

# Verifica se jq está instalado (caso rode isolado)
if ! command -v jq &> /dev/null; then apt-get install jq -y > /dev/null 2>&1; fi

api_response=$(curl -s "https://api.telegram.org/bot$bot_token/getChat?chat_id=$admin_id")
is_ok=$(echo "$api_response" | jq -r '.ok')

if [ "$is_ok" != "true" ]; then
    echo -e "${VERMELHO}❌ ERRO: O Token ou ID informados são inválidos.${RESET}"
    echo "Detalhe: $(echo "$api_response" | jq -r '.description')"
    read -rp "Enter para voltar..."
    exit 1
fi

real_username=$(echo "$api_response" | jq -r '.result.username')

if [ "$real_username" == "null" ]; then
    echo -e "${AMARELO}⚠️  ERRO: O ID $admin_id não tem Username (@) definido no Telegram.${RESET}"
    echo "Configure um username no seu perfil e tente novamente."
    read -rp "Enter para voltar..."
    exit 1
fi

# --- PASSO 2: LOOP DE VALIDAÇÃO ---
while true; do
    echo ""
    echo "-------------------------------------------------------"
    echo -e "${AMARELO}3. Confirmação de Segurança:${RESET}"
    echo "Para validar que o ID $admin_id é realmente seu,"
    echo "digite o seu Username do Telegram (sem @)."
    echo "-------------------------------------------------------"
    read -rp "Username: " input_user

    if [ "$input_user" == "0" ]; then exit 0; fi

    input_user=$(echo "$input_user" | sed 's/@//g' | sed 's/ //g')

    if [[ "${real_username,,}" == "${input_user,,}" ]]; then
        echo ""
        echo -e "${VERDE}✅ IDENTIDADE CONFIRMADA!${RESET}"
        sleep 1
        break
    else
        echo ""
        echo -e "${VERMELHO}❌ INCORRETO!${RESET}"
        echo "O usuário digitado não corresponde ao dono do ID informado."
    fi
done

# --- INSTALAÇÃO FINAL ---
echo ""
echo "Baixando e configurando bot..."
mkdir -p /opt/XrayTools
rm -f /opt/XrayTools/botxray.py

curl -s -L -o /opt/XrayTools/botxray.py "$REPO_BASE/botxray.py"

if [ ! -s "/opt/XrayTools/botxray.py" ]; then
    echo -e "${VERMELHO}Erro no download!${RESET}"; sleep 3; exit 1
fi

# CORREÇÃO CRÍTICA: Usando pipe | como delimitador para não quebrar com token
sed -i "s|SEU_TOKEN_AQUI|$bot_token|g" /opt/XrayTools/botxray.py
sed -i "s|123456789|$admin_id|g" /opt/XrayTools/botxray.py

cat <<EOF > /etc/systemd/system/botxray.service
[Unit]
Description=DragonCore Telegram Bot
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/XrayTools
ExecStart=/usr/bin/python3 /opt/XrayTools/botxray.py
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable botxray
systemctl restart botxray

echo ""
echo -e "${VERDE}🤖 BOT ATIVADO COM SUCESSO!${RESET}"
echo "Vá no Telegram e digite /menu ou /start."
echo ""
read -rp "Pressione ENTER para voltar..."
