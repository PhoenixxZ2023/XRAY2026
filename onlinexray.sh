cat > /usr/local/bin/onlinexray.sh << 'EOF'
#!/bin/bash
# onlinexray.sh - Monitor de Usuários Online (Modo Espião)

# Cores
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'
CONF="/usr/local/etc/xray/config.json"

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
echo -e "${CYAN}        MONITOR DE USUÁRIOS ONLINE (XRAY)       ${RESET}"
echo -e "${CYAN}================================================${RESET}"
echo -e "${YELLOW}Ativando modo espião... (Aguarde)${RESET}"

# Ativa log INFO temporariamente
sed -i 's/"loglevel": "warning"/"loglevel": "info"/' "$CONF"
systemctl restart xray

echo -e "${GREEN}>>> AGUARDANDO CONEXÕES... (CTRL+C para Sair)${RESET}"
echo ""

# Monitora e filtra
journalctl -u xray -f --no-pager | grep --line-buffered "accepted" | \
while read line ; do
    HORA=$(echo "$line" | awk '{print $3}')
    # Tenta pegar o email (usuário)
    USER=$(echo "$line" | grep -o "email: [^ ]*" | cut -d: -f2)
    
    if [ -n "$USER" ]; then
        echo -e "${CYAN}[$HORA]${RESET} Usuário: ${GREEN}$USER${RESET} ${YELLOW}(Online)${RESET}"
    fi
done
EOF

chmod +x /usr/local/bin/onlinexray.sh
