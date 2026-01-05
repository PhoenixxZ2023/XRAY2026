#!/bin/bash
# limiterxray.sh - Módulo de Controle de Consumo (DragonCore V7.3)
# Versão: GitHub Edition + UUID Scramble (Bloqueio Real)

# CONFIGURAÇÃO
XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LIMITS_DB="/opt/XrayTools/limits.db"
USER_DB="/opt/XrayTools/users.db" # IMPORTANTE: Para recuperar o UUID original
XRAY_API_PORT="1080" 

# CORES
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_BLUE='\033[1;34m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
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

# --- FUNÇÃO INTELIGENTE (Define, Altera e Desbloqueia) ---
func_set_limit() {
    header_limit
    echo "Definir ou Alterar Limite"
    echo "--------------------------------------"
    read -rp "Digite o Usuário (Nick): " nick
    if [ -z "$nick" ]; then return; fi
    
    # Verifica existência (Normal ou Bloqueado)
    local is_locked=false
    if grep -q "\"email\": \"LOCKED_$nick\"" "$CONFIG_PATH"; then
        is_locked=true
    elif ! grep -q "\"email\": \"$nick\"" "$CONFIG_PATH"; then
        echo -e "${TXT_RED}Usuário não encontrado no sistema!${RESET}"
        read -rp "Enter..."
        return
    fi

    if [ "$is_locked" = true ]; then
        echo -e "${TXT_YELLOW}⚠️ Este usuário está BLOQUEADO.${RESET}"
        echo "Ao definir um novo limite, ele será DESBLOQUEADO automaticamente."
    else
        echo -e "${TXT_BLUE}ℹ️ Usuário Ativo.${RESET} O limite será atualizado."
    fi
    echo ""

    echo "Qual o novo limite de internet?"
    echo "Ex: 10, 50, 100 (Valor em GB)"
    read -rp "Novo Limite (GB): " gb_limit

    if ! [[ "$gb_limit" =~ ^[0-9]+$ ]]; then
        echo "Valor inválido."
        sleep 1; return
    fi

    # 1. Atualiza o Banco de Dados de Limites
    local bytes_limit=$(echo "$gb_limit * 1073741824" | bc)
    sed -i "/^$nick|/d" "$LIMITS_DB"
    echo "$nick|$bytes_limit" >> "$LIMITS_DB"

    # 2. Se estiver bloqueado, desbloqueia agora (Restaurando UUID Original)
    if [ "$is_locked" = true ]; then
        echo "Recuperando UUID original..."
        # Pega o UUID original do arquivo users.db
        local real_uuid=$(grep "^$nick|" "$USER_DB" | cut -d'|' -f2)
        
        if [ -z "$real_uuid" ]; then
            echo -e "${TXT_RED}ERRO: UUID original não encontrado no backup!${RESET}"
            read -rp "Enter..."
            return
        fi

        echo "Aplicando novo limite e desbloqueando..."
        jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg uuid "$real_uuid" \
           '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(if .email == $locked then .email = $nick | .id = $uuid else . end)' \
           "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        
        systemctl restart xray > /dev/null 2>&1
        echo -e "${TXT_GREEN}✅ Sucesso! $nick desbloqueado com $gb_limit GB.${RESET}"
    else
        echo -e "${TXT_GREEN}✅ Limite de $nick atualizado para $gb_limit GB!${RESET}"
    fi

    read -rp "Pressione ENTER para voltar..."
}

func_view_usage() {
    func_get_api_port
    header_limit
    printf "%-15s | %-15s | %-10s | %s\n" "USUÁRIO" "CONSUMO" "LIMITE" "STATUS"
    echo "------------------------------------------------------------"

    jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients[].email' "$CONFIG_PATH" | while read -r email_raw; do
        if [ -z "$email_raw" ]; then continue; fi
        
        local is_locked=false
        local nick="$email_raw"
        
        if [[ "$email_raw" == LOCKED_* ]]; then
            is_locked=true
            nick="${email_raw#LOCKED_}"
        fi

        # Se estiver bloqueado, não adianta pedir stats do nome original, pois mudou no config
        local query_name="$email_raw"
        
        local down=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${query_name}>>>traffic>>>downlink" 2>/dev/null | grep "value" | awk '{print $2}')
        local up=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${query_name}>>>traffic>>>uplink" 2>/dev/null | grep "value" | awk '{print $2}')
        [ -z "$down" ] && down=0; [ -z "$up" ] && up=0
        local total=$(echo "$down + $up" | bc)
        local total_h=$(func_bytes_to_human "$total")
        
        local limit_bytes=$(grep "^$nick|" "$LIMITS_DB" | cut -d'|' -f2)
        local limit_h="Ilimitado"
        local status="${TXT_GREEN}OK${RESET}"

        if [ "$is_locked" = true ]; then
            status="${TXT_RED}BLOQUEADO${RESET}"
            total_h="---" # Não mostra consumo enquanto bloqueado
        elif [ -n "$limit_bytes" ]; then
            limit_h=$(func_bytes_to_human "$limit_bytes")
            if [ "$total" -ge "$limit_bytes" ]; then status="${TXT_RED}EXCEDIDO${RESET}"; else
                local pct=$(echo "scale=0; ($total * 100) / $limit_bytes" | bc); status="${TXT_CYAN}${pct}%${RESET}"; fi
        fi
        printf "%-15s | %-15s | %-10s | %b\n" "$nick" "$total_h" "$limit_h" "$status"
    done
    echo "------------------------------------------------------------"
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_remove_limit() {
    header_limit
    echo "Remover Limite (Tornar Ilimitado)"
    echo "---------------------------------"
    read -rp "Digite o Usuário: " nick
    if [ -z "$nick" ]; then return; fi
    sed -i "/^$nick|/d" "$LIMITS_DB"
    
    local reboot_needed=false
    if grep -q "\"email\": \"LOCKED_$nick\"" "$CONFIG_PATH"; then
        # Recupera UUID Original
        local real_uuid=$(grep "^$nick|" "$USER_DB" | cut -d'|' -f2)
        if [ -z "$real_uuid" ]; then echo "Erro fatal: UUID original sumiu."; sleep 2; return; fi

        jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg uuid "$real_uuid" \
           '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(if .email == $locked then .email = $nick | .id = $uuid else . end)' \
           "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        reboot_needed=true
    fi

    if [ "$reboot_needed" = true ]; then
        systemctl restart xray > /dev/null 2>&1
        echo -e "${TXT_GREEN}✅ Desbloqueado e Ilimitado!${RESET}"
    else
        echo -e "${TXT_GREEN}✅ Limite removido.${RESET}"
    fi
    sleep 2
}

func_check_and_block() {
    local SILENT="$1"
    func_get_api_port
    if [ "$SILENT" != "--cron" ]; then header_limit; echo "Verificando excedentes..."; echo "-----------------------"; fi
    
    local blocked_count=0
    while IFS='|' read -r nick limit_bytes; do
        if grep -q "\"email\": \"LOCKED_$nick\"" "$CONFIG_PATH"; then continue; fi
        if ! grep -q "\"email\": \"$nick\"" "$CONFIG_PATH"; then continue; fi

        local down=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>downlink" 2>/dev/null | grep "value" | awk '{print $2}')
        local up=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>uplink" 2>/dev/null | grep "value" | awk '{print $2}')
        [ -z "$down" ] && down=0; [ -z "$up" ] && up=0
        local total=$(echo "$down + $up" | bc)
        
        if [ "$total" -ge "$limit_bytes" ]; then
            if [ "$SILENT" != "--cron" ]; then echo -e "${TXT_RED}❌ $nick excedeu! Bloqueando...${RESET}"; fi
            
            # --- BLOQUEIO REAL (Muda Email + Muda UUID) ---
            # Gera um UUID falso para quebrar a conexão
            local fake_uuid=$(uuidgen)
            
            jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg fake "$fake_uuid" \
               '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(if .email == $nick then .email = $locked | .id = $fake else . end)' \
               "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ((blocked_count++))
        else
             if [ "$SILENT" != "--cron" ]; then echo "✅ $nick dentro do limite."; fi
        fi
    done < "$LIMITS_DB"
    
    if [ $blocked_count -gt 0 ]; then
        systemctl restart xray > /dev/null 2>&1
        if [ "$SILENT" != "--cron" ]; then echo ""; echo -e "${TXT_RED}🚫 $blocked_count usuários bloqueados.${RESET}"; fi
    elif [ "$SILENT" != "--cron" ]; then
        echo ""; echo -e "${TXT_GREEN}Tudo certo.${RESET}"
    fi
    
    if [ "$SILENT" != "--cron" ]; then echo ""; read -rp "Pressione ENTER para voltar..."; fi
}

# --- INIT ---
if [ "$1" == "--cron" ]; then func_check_and_block "--cron"; exit 0; fi

# --- MENU ---
while true; do
    header_limit
    echo -e "${TXT_CYAN}[1]. DEFINIR/ALTERAR LIMITE${RESET}"
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
        0) exit 0 ;; *) echo "Inválido";;
    esac
done
