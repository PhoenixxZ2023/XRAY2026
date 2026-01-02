#!/bin/bash
# installxray.sh - Instalador Premium v6.9 (Visual + Automação)
# Repositório: https://github.com/PhoenixxZ2023/XrayX-TLS

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
echo -e "${AMARELO}🚀 DRAGONCORE XRAY MANAGER - INSTALADOR v6.9${RESET}"
echo -e "${AZUL}==================================================${RESET}"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${VERMELHO}❌ Execute como root!${RESET}"
    exit 1
fi

# 1. Atualizando repositórios
(apt-get update -y) > /dev/null 2>&1 &
fun_bar $! "Atualizando Sistema"

# 2. Instalando Dependências
PACKAGES="curl jq bc cron git"
(apt-get install -y $PACKAGES) > /dev/null 2>&1 &
fun_bar $! "Instalando Dependências"

# 3. Baixando e Instalando Scripts
(
    # Menu Principal
    rm -f /bin/menuxray.sh
    curl -s -L -o /bin/menuxray.sh "https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/menuxray.sh"
    chmod +x /bin/menuxray.sh

    # Limitador (Módulo)
    rm -f /bin/limiterxray.sh
    curl -s -L -o /bin/limiterxray.sh "https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/limiterxray.sh"
    chmod +x /bin/limiterxray.sh

    # Atalho 'xray-menu' (O comando que você pediu)
    rm -f /bin/xray-menu
    cat <<EOF > /bin/xray-menu
#!/bin/bash
bash /bin/menuxray.sh
EOF
    chmod +x /bin/xray-menu
) > /dev/null 2>&1 &
fun_bar $! "Baixando Scripts"

# 4. Configurando Automação (Robô Cron)
(
    crontab -l 2>/dev/null | grep -v "limiterxray.sh" | crontab -
    (crontab -l 2>/dev/null; echo "*/5 * * * * bash /bin/limiterxray.sh --cron") | crontab -
) > /dev/null 2>&1 &
fun_bar $! "Ativando Robô de Limites"

echo -e "${AZUL}==================================================${RESET}"
echo -e "${VERDE}🎉 INSTALAÇÃO CONCLUÍDA COM SUCESSO!${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo -e "O Robô de bloqueio já está ativo em segundo plano."
echo -e "Para acessar o sistema, digite: ${VERDE}xray-menu${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""
sleep 2

# Executa o menu automaticamente
bash /bin/xray-menu
