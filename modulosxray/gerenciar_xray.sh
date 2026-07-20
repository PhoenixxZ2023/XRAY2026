#!/bin/bash
# gerenciar_xray.sh - Submenu para controle do serviço Xray

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

while true; do
    clear
    echo -e "${TITLE_BAR}   GERENCIAR SERVIÇO XRAY   ${RESET}"
    echo ""
    
    # Exibe o status atual em tempo real
    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e " Status Atual: ${TXT_GREEN}ATIVO / RODANDO${RESET}"
    else
        echo -e " Status Atual: ${TXT_RED}PARADO / DESATIVADO${RESET}"
    fi
    
    echo "-----------------------------------------"
    echo -e " ${TXT_RED}[1] PARAR E DESATIVAR XRAY${RESET}"
    echo -e " ${TXT_GREEN}[2] INICIAR E ATIVAR XRAY${RESET}"
    echo -e " ${TXT_YELLOW}[3] REINICIAR XRAY${RESET}"
    echo -e " ${TXT_CYAN}[0] VOLTAR${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "$opt" in
        1)
            echo -e "\n${TXT_RED}Parando serviço...${RESET}"
            systemctl stop xray
            systemctl disable xray >/dev/null 2>&1
            echo -e "⛔ Xray desativado."
            sleep 2
            ;;
        2)
            echo -e "\n${TXT_GREEN}Iniciando serviço...${RESET}"
            systemctl enable xray >/dev/null 2>&1
            systemctl start xray
            echo -e "✅ Xray ativado."
            sleep 2
            ;;
        3)
            echo -e "\n${TXT_YELLOW}Reiniciando serviço...${RESET}"
            systemctl restart xray
            echo -e "🔄 Xray reiniciado."
            sleep 2
            ;;
        0)
            # Sai do loop e volta para o menu principal
            xray-menu
            ;;
        *)
            echo -e "${TXT_RED}Opção inválida!${RESET}"
            sleep 1
            ;;
    esac
done
