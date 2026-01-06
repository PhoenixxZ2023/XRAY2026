#!/bin/bash
# installxray.sh - Instalador Premium V7.3 (Visual + Automação)
# Repositório: https://gitea.com/KAKAROTO/Xray2026

# --- CORES ---
VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

# --- FUNÇÃO DE BARRA DE PROGRESSO ---
fun_bar() {
    local pid=$1
    local text=$2
    local delay=0.1
    local i=0
    local percent=0
    
    tput civis # Esconde cursor
    
    while kill -0 $pid 2>/dev/null; do
        if [ $percent -lt 95 ]; then percent=$((percent + 1)); fi
        local filled=$((percent / 5))
        local unfilled=$((20 - filled))
        printf "\r${AZUL}[${text}]${RESET} ["
        printf "%0.s#" $(seq 1 $filled)
        printf "%0.s." $(seq 1 $unfilled)
        printf "] ${AMARELO}%d%%${RESET} " "$percent"
        sleep $delay
    done

    printf "\r${AZUL}[${text}]${RESET} ["
    printf "%0.s#" {1..20}
    printf "] ${VERDE}100%%${RESET} - ${VERDE}OK!${RESET}    \n"
    tput cnorm # Volta cursor
}

# --- INÍCIO ---
clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}🚀 DRAGONCORE XRAY MANAGER - INSTALADOR V7.3${RESET}"
echo -e "${AZUL}==================================================${RESET}"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${VERMELHO}❌ Execute como root!${RESET}"
    exit 1
fi

# 1. Atualizando repositórios
(apt-get update -y) > /dev/null 2>&1 &
fun_bar $! "Atualizando Sistema"

# 2. Instalando Dependências do Sistema + Python
# Adicionado python3 e python3-pip na lista
PACKAGES="curl jq bc cron git uuid-runtime python3 python3-pip"
(apt-get install -y $PACKAGES) > /dev/null 2>&1 &
fun_bar $! "Instalando Dependências e Python"

# 3. Instalando Bibliotecas do Bot (Pip)
(
    # Remove trava de pacotes externos (Debian 12/Ubuntu 23+)
    rm -f /usr/lib/python3.*/EXTERNALLY-MANAGED
    
    # Instala a biblioteca do Telegram
    pip3 install python-telegram-bot
) > /dev/null 2>&1 &
fun_bar $! "Configurando Bibliotecas do Bot"

# 4. Baixando e Instalando Scripts
(
    # Remove versões antigas em pastas variadas para evitar conflito
    rm -f /bin/menuxray.sh /usr/local/bin/menuxray.sh
    rm -f /bin/limiterxray.sh /usr/local/bin/limiterxray.sh
    rm -f /bin/xray-menu /usr/bin/xray-menu

    # Menu Principal (Instala em /usr/local/bin)
    curl -s -L -o /usr/local/bin/menuxray.sh "https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/menuxray.sh"
    chmod +x /usr/local/bin/menuxray.sh

    # Limitador (Módulo)
    curl -s -L -o /usr/local/bin/limiterxray.sh "https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/limiterxray.sh"
    chmod +x /usr/local/bin/limiterxray.sh

    # Atalho Global 'xray-menu'
    ln -s /usr/local/bin/menuxray.sh /usr/bin/xray-menu
    chmod +x /usr/bin/xray-menu
) > /dev/null 2>&1 &
fun_bar $! "Baixando Scripts (V7.3)"

# 5. Configurando Automação (Robô Cron - 2 MINUTOS)
(
    # Remove cron antigo (inclusive se estiver apontando para /bin)
    crontab -l 2>/dev/null | grep -v "limiterxray.sh" | crontab -
    
    # Adiciona novo cron apontando para o caminho correto
    (crontab -l 2>/dev/null; echo "*/2 * * * * bash /usr/local/bin/limiterxray.sh --cron") | crontab -
) > /dev/null 2>&1 &
fun_bar $! "Ativando Robô (2 min)"

echo -e "${AZUL}==================================================${RESET}"
echo -e "${VERDE}🎉 INSTALAÇÃO CONCLUÍDA COM SUCESSO!${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo -e "O Robô de bloqueio já está ativo em segundo plano."
echo -e "As dependências do Bot Telegram já foram instaladas."
echo -e "Para acessar o sistema, digite: ${VERDE}xray-menu${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""
sleep 2

# Executa o menu automaticamente
xray-menu
