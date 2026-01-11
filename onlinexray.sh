#!/bin/bash
# onlinexray.sh - Monitor Inteligente (Com Anti-Spam)

# Cores
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'
CONF="/usr/local/etc/xray/config.json"

# Dicionário para controlar o tempo da última aparição de cada usuário
declare -A LAST_SEEN

# Configuração: Quantos segundos esperar antes de mostrar o mesmo usuário de novo?
COOLDOWN=15

# Função para restaurar o log ao sair
restaurar_log() {
    echo ""
    echo -e "${YELLOW}>>> Restaurando configurações...${RESET}"
    sed -i 's/"loglevel": "info"/"loglevel": "warning"/' "$CONF"
    systemctl restart xray
    echo -e "${GREEN}>>> Encerrado.${RESET}"
    exit 0
}

trap restaurar_log SIGINT

clear
echo -e "${CYAN}================================================${RESET}"
echo -e "${CYAN}         MONITOR DE USUÁRIOS ONLINE (XRAY)      ${RESET}"
echo -e "${CYAN}================================================${RESET}"
echo -e "${YELLOW}Ativando modo espião com filtro anti-spam...${RESET}"

# Ativa log INFO temporariamente
sed -i 's/"loglevel": "warning"/"loglevel": "info"/' "$CONF"
systemctl restart xray

echo -e "${GREEN}>>> AGUARDANDO CONEXÕES... (CTRL+C para Sair)${RESET}"
echo ""

# Monitora o log em tempo real
journalctl -u xray -f --no-pager | grep --line-buffered "accepted" | \
while read line ; do
    # Extrai o nome do usuário
    USER=$(echo "$line" | grep -o "email: [^ ]*" | cut -d: -f2)

    # Se encontrou um usuário
    if [ -n "$USER" ]; then
        # Pega o tempo atual (em segundos desde o início do script)
        NOW=$SECONDS
        
        # Verifica quando foi a última vez que vimos esse usuário
        LAST=${LAST_SEEN[$USER]}
        
        # Se nunca vimos (vazio) OU se já passou o tempo de Cooldown
        if [ -z "$LAST" ] || [ $((NOW - LAST)) -ge $COOLDOWN ]; then
            
            # Extrai a hora apenas para exibição
            HORA=$(echo "$line" | awk '{print $3}')
            
            # Mostra na tela (LIMPO)
            echo -e "${CYAN}[$HORA]${RESET} Usuário: ${GREEN}$USER${RESET} ${YELLOW}(Online)${RESET}"
            
            # Atualiza a última vez que ele foi visto
            LAST_SEEN[$USER]=$NOW
        fi
    fi
done
