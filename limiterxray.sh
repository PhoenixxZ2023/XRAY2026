#!/bin/bash
# limiterxray.sh - Módulo de Controle de Consumo (DragonCore)
# Versão: GitHub Edition + AutoBlock (Baseado na sua preferência)

# CONFIGURAÇÃO
XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LIMITS_DB="/opt/XrayTools/limits.db" # Banco de dados de limites
XRAY_API_PORT="1080" 

# CORES
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_BLUE='\033[1;34m'
TXT_CYAN='\033[1;36m'
RESET='\033[0m'

mkdir -p "/opt/XrayTools"
touch "$LIMITS_DB"

# --- FUNÇÕES ---

header_limit() {
    clear
    echo -e "${TITLE_BAR}   CONTROLE DE CONSUMO (GB)   ${RESET}"
    echo ""
}

func_get_api_port() {
    if [ -f "$CONFIG_PATH" ]; then
        local p=$(jq -r '.inbounds[] | select(.tag == "api").port // empty' "$CONFIG_PATH")
        if [ -n "$p" ]; then XRAY_API_PORT="$p"; fi
    fi
}

func_bytes_to_human() {
    local b=${1:-0}
    if [ $b -gt 1073741824 ]; then
        echo "$(echo "scale=2; $b/1073741824" | bc) GB"
    elif [ $b -gt 1048576 ]; then
        echo "$(echo "scale=2; $b/1048576" | bc) MB"
    else
        echo "$(echo "scale=2; $b/1024" | bc) KB"
    fi
}

func_set_limit() {
    header_limit
    echo "Definir Limite de Consumo para Usuário"
    echo "--------------------------------------"
    read -rp "Digite o Usuário (Nick): " nick
    if [ -z "$nick" ]; then return; fi
    
    if ! grep -q "\"email\": \"$nick\"" "$CONFIG_PATH"; then
        echo -e "${TXT_RED}Usuário não encontrado no sistema!${RESET}"
        read -rp "Enter..."
        return
    fi

    echo ""
    echo "Quanto de internet ele pode usar?"
    echo "Ex: 10, 50, 100 (Valor em GB)"
    read -rp "Limite (GB): " gb_limit

    if ! [[ "$gb_limit" =~ ^[0-9]+$ ]]; then
        echo "Valor inválido."
        sleep 1; return
    fi

    local bytes_limit=$(echo "$gb_limit * 1073741824" | bc)

    # Salva no DB: nick|bytes_limit
    sed -i "/^$nick|/d" "$LIMITS_DB"
    echo "$nick|$bytes_limit" >> "$LIMITS_DB"

    echo -e "${TXT_GREEN}✅ Limite de $gb_limit GB definido para $nick!${RESET}"
    read -rp "Pressione ENTER para voltar..."
}

func_view_usage() {
    func_get_api_port
    header_limit
    echo -e "USUÁRIO        | CONSUMO (Atual) | LIMITE    | STATUS"
    echo "--------------------------------------------------------"

    jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients[].email' "$CONFIG_PATH" | while read -r nick; do
        if [ -z "$nick" ]; then continue; fi
        
        local down=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>downlink" 2>/dev/null | grep "value" | awk '{print $2}')
        local up=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>uplink" 2>/dev/null | grep "value" | awk '{print $2}')
        
        [ -z "$down" ] && down=0
        [ -z "$up" ] && up=0
        
        local total=$(echo "$down + $up" | bc)
        local total_h=$(func_bytes_to_human "$total")
        
        local limit_bytes=$(grep "^$nick|" "$LIMITS_DB" | cut -d'|' -f2)
        local limit_h="Ilimitado"
        local status="${TXT_GREEN}OK${RESET}"

        if [ -n "$limit_bytes" ]; then
            limit_h=$(func_bytes_to_human "$limit_bytes")
            if [ "$total" -ge "$limit_bytes" ]; then
                status="${TXT_RED}BLOQUEADO${RESET}"
            else
                local pct=$(echo "scale=0; ($total * 100) / $limit_bytes" | bc)
                status="${TXT_CYAN}${pct}%${RESET}"
            fi
        fi

        printf "%-14s | %-15s | %-9s | %b\n" "$nick" "$total_h" "$limit_h" "$status"
    done
    echo ""
    echo "Nota: O consumo reseta se a VPS reiniciar."
    read -rp "Pressione ENTER para voltar..."
}

func_remove_limit() {
    header_limit
    echo "Remover Limite (Tornar Ilimitado)"
    echo "---------------------------------"
    read -rp "Digite o Usuário: " nick
    if [ -n "$nick" ]; then
        sed -i "/^$nick|/d" "$LIMITS_DB"
        echo -e "${TXT_GREEN}✅ Limite removido. Usuário livre.${RESET}"
    fi
    sleep 2
}

func_check_and_block() {
    # Recebe flag do cron
    local SILENT="$1"

    func_get_api_port
    
    # Só limpa a tela e mostra cabeçalho se NÃO for cron
    if [ "$SILENT" != "--cron" ]; then
        header_limit
        echo "Verificando excedentes e aplicando bloqueios..."
        echo "-----------------------------------------------"
    fi
    
    local blocked_count=0

    while IFS='|' read -r nick limit_bytes; do
        # Verifica se o usuário ainda existe no config antes de checar stats
        if ! grep -q "\"email\": \"$nick\"" "$CONFIG_PATH"; then continue; fi

        local down=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>downlink" 2>/dev/null | grep "value" | awk '{print $2}')
        local up=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>uplink" 2>/dev/null | grep "value" | awk '{print $2}')
        [ -z "$down" ] && down=0
        [ -z "$up" ] && up=0
        local total=$(echo "$down + $up" | bc)
        
        if [ "$total" -ge "$limit_bytes" ]; then
            # Só mostra mensagem visual se NÃO for cron
            if [ "$SILENT" != "--cron" ]; then
                echo -e "${TXT_RED}❌ $nick excedeu o limite! Bloqueando...${RESET}"
            fi
            
            # --- BLOQUEIO REAL ---
            jq --arg id "$nick" '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(select(.email != $id))' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ((blocked_count++))
        else
             if [ "$SILENT" != "--cron" ]; then
                echo "✅ $nick dentro do limite."
             fi
        fi
    done < "$LIMITS_DB"
    
    if [ $blocked_count -gt 0 ]; then
        systemctl restart xray > /dev/null 2>&1
        if [ "$SILENT" != "--cron" ]; then
            echo ""
            echo -e "${TXT_RED}🚫 $blocked_count usuários foram bloqueados.${RESET}"
        fi
    else
        if [ "$SILENT" != "--cron" ]; then
            echo ""
            echo -e "${TXT_GREEN}Tudo certo. Ninguém excedeu o limite.${RESET}"
        fi
    fi
    
    # IMPORTANTE: Só pede ENTER se for humano. Robô não aperta enter.
    if [ "$SILENT" != "--cron" ]; then
        echo ""
        read -rp "Pressione ENTER para voltar..."
    fi
}

# --- LÓGICA DE INICIALIZAÇÃO (AUTO-EXECUÇÃO) ---
# Se o script for chamado com "--cron", roda o check e sai sem mostrar menu
if [ "$1" == "--cron" ]; then
    func_check_and_block "--cron"
    exit 0
fi

# --- MENU LIMITER ---
while true; do
    header_limit
    echo -e "${TXT_CYAN}[1]. DEFINIR LIMITE (GB)${RESET}"
    echo -e "${TXT_CYAN}[2]. VER CONSUMO DOS CLIENTES${RESET}"
    echo -e "${TXT_CYAN}[3]. REMOVER LIMITE (ILIMITADO)${RESET}"
    echo -e "${TXT_RED}[4]. VERIFICAR E BLOQUEAR EXCEDENTES${RESET}"
    echo -e "${TXT_CYAN}[0]. VOLTAR AO MENU PRINCIPAL${RESET}"
    echo "--------------------------------------"
    read -rp "Opção: " choice
    
    case "$choice" in
        1) func_set_limit ;;
        2) func_view_usage ;;
        3) func_remove_limit ;;
        4) func_check_and_block ;;
        0) exit 0 ;;
        *) echo "Opção inválida." ;;
    esac
done
