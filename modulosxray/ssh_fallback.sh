#!/bin/bash
# ssh_fallback.sh - TURBONET XRAY V1.0
# SSH como fallback na porta 443 via Dropbear + Xray fallbacks.
#
# Fluxo:
#   Cliente SSH  → porta 443 → Xray detecta SSH → redireciona para Dropbear:2222
#   Cliente XHTTP → porta 443 → Xray processa normalmente (VLESS/XHTTP)
#
# Ambos rodam na porta 443 simultaneamente.
# O Xray detecta automaticamente o tipo de conexão.
#
# Configuração no app cliente (modo SSH):
#   Host: IP da VPS
#   Port: 443
#   User: nome do usuário criado no TURBONET XRAY
#   Pass: senha do usuário (mesma do CheckUser)
#   UDPGW: 127.0.0.1:7300

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
DROPBEAR_PORT=2222   # porta interna — não exposta diretamente
DROPBEAR_PUB_PORT=443  # porta pública (via Xray fallback)
LOG_FILE="/tmp/ssh_fallback.log"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

[ "${EUID:-$(id -u)}" -ne 0 ] && { echo -e "${TXT_RED}❌ Execute como root!${RESET}"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    else echo -e "${TXT_RED}❌ Gerenciador não detectado.${RESET}"; exit 1; fi
}

ensure_pkg() {
    local bin="$1" pkg="$2"
    command -v "$bin" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && {
                apt-get update -y >>"$LOG_FILE" 2>&1 || true
                _APT_UPDATED=1
            }
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
    esac
}

_apply_config_perms() {
    chmod 0660 "$CONFIG_PATH"
    chown root:nogroup "$CONFIG_PATH"
}

_wait_xray_active() {
    local tries=5
    while [ "$tries" -gt 0 ]; do
        systemctl is-active --quiet xray 2>/dev/null && return 0
        sleep 1; tries=$(( tries - 1 ))
    done
    return 1
}

_dropbear_status() {
    if systemctl is-active --quiet dropbear 2>/dev/null; then
        echo -e "${TXT_GREEN}ATIVO${RESET}"
    else
        echo -e "${TXT_RED}INATIVO${RESET}"
    fi
}

_xray_fallback_status() {
    [ ! -s "$CONFIG_PATH" ] && { echo -e "${TXT_RED}config não encontrado${RESET}"; return; }
    local fb
    fb=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") |
         .settings.fallbacks[]? | select(.dest==2222) | .dest' \
         "$CONFIG_PATH" 2>/dev/null || echo "")
    if [ -n "$fb" ]; then
        echo -e "${TXT_GREEN}CONFIGURADO (→ :2222)${RESET}"
    else
        echo -e "${TXT_RED}NÃO CONFIGURADO${RESET}"
    fi
}

# --- INSTALAR E CONFIGURAR DROPBEAR ---
_install_dropbear() {
    echo -e "${TXT_YELLOW}Instalando Dropbear SSH...${RESET}"
    : > "$LOG_FILE"

    ensure_pkg dropbear dropbear

    # Configurar Dropbear apenas em loopback na porta 2222
    # Não exposto diretamente — acesso via Xray fallback
    local dropbear_conf="/etc/default/dropbear"
    if [ -f "$dropbear_conf" ]; then
        # Desabilita porta padrão do dropbear (acesso só via Xray)
        sed -i 's/^NO_START=.*/NO_START=0/'         "$dropbear_conf" || true
        sed -i 's/^DROPBEAR_PORT=.*/DROPBEAR_PORT=/' "$dropbear_conf" || true
        sed -i 's/^DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS="-p 127.0.0.1:2222 -w -s"/' \
            "$dropbear_conf" || true
    fi

    # Para sistemas com systemd direto
    local service_override="/etc/systemd/system/dropbear.service.d"
    mkdir -p "$service_override"
    cat > "${service_override}/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/dropbear -F -E -p 127.0.0.1:2222 -w
EOF
    # -F: foreground
    # -E: log para stderr
    # -p 127.0.0.1:2222: apenas loopback, porta 2222
    # -w: desabilita login como root via SSH (segurança)

    systemctl daemon-reload
    systemctl enable  dropbear >/dev/null 2>&1 || true
    systemctl restart dropbear >/dev/null 2>&1 || true
    sleep 2

    if systemctl is-active --quiet dropbear 2>/dev/null; then
        echo -e "${TXT_GREEN}✅ Dropbear ativo em 127.0.0.1:2222${RESET}"
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar Dropbear.${RESET}"
        journalctl -u dropbear -n 10 --no-pager 2>/dev/null || true
        return 1
    fi
}

# --- ADICIONAR FALLBACKS NO XRAY ---
_configure_xray_fallback() {
    echo -e "${TXT_YELLOW}Configurando fallback SSH no Xray...${RESET}"

    if [ ! -s "$CONFIG_PATH" ]; then
        echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"; return 1
    fi
    if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
        echo -e "${TXT_RED}❌ config.json inválido.${RESET}"; return 1
    fi

    # Verifica se protocolo é VLESS (fallbacks só funcionam com VLESS)
    local proto
    proto=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") |
            .protocol // ""' "$CONFIG_PATH" 2>/dev/null || echo "")
    if [ "$proto" != "vless" ]; then
        echo -e "${TXT_RED}❌ Fallback SSH requer protocolo VLESS.${RESET}"
        echo -e " Protocolo atual: ${proto}"
        echo -e " Reconfigure o Xray com VLESS+XHTTP (opção 04 do menu)."
        return 1
    fi

    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    local tmp; tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

    # Adiciona fallbacks: SSH (porta 2222) e HTTP genérico
    jq '
        (.inbounds[] | select(.tag=="inbound-turbonet") | .settings.fallbacks) =
        [
            {
                "name": "",
                "alpn": "",
                "path": "",
                "dest": 2222,
                "xver": 0
            }
        ]
    ' "$CONFIG_PATH" > "$tmp" 2>>"$LOG_FILE"

    if ! jq empty "$tmp" 2>/dev/null; then
        echo -e "${TXT_RED}❌ Falha ao gerar config.${RESET}"
        rm -f "$tmp"; return 1
    fi

    mv -f "$tmp" "$CONFIG_PATH"
    _apply_config_perms

    # Restart Xray
    if ! systemctl restart xray >/dev/null 2>&1 || ! _wait_xray_active; then
        echo -e "${TXT_RED}❌ Xray falhou após configuração. Revertendo...${RESET}"
        mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        _apply_config_perms
        systemctl restart xray >/dev/null 2>&1 || true
        return 1
    fi

    echo -e "${TXT_GREEN}✅ Fallback SSH configurado no Xray.${RESET}"
    echo -e " Conexões SSH na porta ${DROPBEAR_PUB_PORT} → Dropbear :2222"
}

# --- REMOVER FALLBACKS DO XRAY ---
_remove_xray_fallback() {
    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    local tmp; tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
    jq '
        (.inbounds[] | select(.tag=="inbound-turbonet") | .settings.fallbacks) = []
    ' "$CONFIG_PATH" > "$tmp" 2>/dev/null
    if jq empty "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CONFIG_PATH"
        _apply_config_perms
        systemctl restart xray >/dev/null 2>&1 || true
        echo -e "${TXT_GREEN}✅ Fallbacks removidos do Xray.${RESET}"
    else
        rm -f "$tmp"
        echo -e "${TXT_RED}❌ Falha ao remover fallbacks.${RESET}"
    fi
}

# --- CRIAR USUÁRIO SSH VINCULADO AO USERS.DB ---
_create_ssh_user() {
    local nick="$1" pass="$2"

    if id "$nick" &>/dev/null; then
        echo -e "${TXT_YELLOW}Usuário '${nick}' já existe no sistema.${RESET}"
        # Atualiza senha
        echo "${nick}:${pass}" | chpasswd
        echo -e "${TXT_GREEN}✅ Senha atualizada.${RESET}"
        return 0
    fi

    # Cria usuário sem home, sem shell de login (só SSH tunnel)
    useradd -M -s /bin/false "$nick" 2>>"$LOG_FILE" || {
        echo -e "${TXT_RED}❌ Falha ao criar usuário ${nick}.${RESET}"; return 1
    }
    echo "${nick}:${pass}" | chpasswd
    echo -e "${TXT_GREEN}✅ Usuário SSH '${nick}' criado.${RESET}"
}

# --- SINCRONIZAR USERS.DB COM USUÁRIOS SSH ---
_sync_ssh_users() {
    echo -e "${TXT_YELLOW}Sincronizando usuários do DB com SSH...${RESET}"
    local count=0

    if [ ! -s "$USER_DB" ]; then
        echo -e "${TXT_YELLOW}DB vazio — nenhum usuário para sincronizar.${RESET}"
        return
    fi

    while IFS='|' read -r nick uuid expiry pass limit _rest; do
        [ -n "${nick:-}" ] || continue
        [ -n "${pass:-}" ] || continue  # pula usuários sem senha

        # Verifica expiração
        local exp_ts today_ts
        exp_ts=$(date -d "${expiry:-2000-01-01}" +%s 2>/dev/null || echo 0)
        today_ts=$(date +%s)

        if [ "$exp_ts" -lt "$today_ts" ]; then
            # Usuário expirado — remove do sistema se existir
            if id "$nick" &>/dev/null; then
                userdel "$nick" 2>/dev/null || true
                echo -e " ${TXT_RED}Removido (expirado):${RESET} ${nick}"
            fi
            continue
        fi

        # Verifica se bloqueado
        local locked=false
        if jq -e --arg lock "LOCKED_${nick}" '
            any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?;
                .email == $lock)' "$CONFIG_PATH" >/dev/null 2>&1; then
            locked=true
        fi

        if [ "$locked" = "true" ]; then
            # Bloqueia acesso SSH (senha inválida)
            if id "$nick" &>/dev/null; then
                passwd -l "$nick" >/dev/null 2>&1 || true
                echo -e " ${TXT_YELLOW}Bloqueado SSH:${RESET} ${nick}"
            fi
            continue
        fi

        _create_ssh_user "$nick" "$pass"
        count=$(( count + 1 ))
    done < "$USER_DB"

    echo -e "${TXT_GREEN}✅ Sincronização concluída: ${count} usuário(s).${RESET}"
}

# --- REMOVER USUÁRIO SSH ---
_remove_ssh_user() {
    local nick="$1"
    if id "$nick" &>/dev/null; then
        userdel "$nick" 2>/dev/null || true
        echo -e "${TXT_GREEN}✅ Usuário SSH '${nick}' removido.${RESET}"
    else
        echo -e "${TXT_YELLOW}Usuário '${nick}' não existe no sistema.${RESET}"
    fi
}

# --- EXIBIR INFO DE CONEXÃO SSH ---
_show_connection_info() {
    local pub_ip
    pub_ip=$(curl -4fsSL --max-time 5 https://icanhazip.com 2>/dev/null || echo "SEU_IP")

    local preset_domain=""
    [ -f "/usr/local/etc/xray/preset.json" ] && \
        preset_domain=$(jq -r '.domain // ""' /usr/local/etc/xray/preset.json 2>/dev/null || echo "")

    clear
    echo -e "${TITLE_BAR}   CONEXÃO SSH XHTTP — INFO   ${RESET}"
    echo ""
    echo -e "${TXT_CYAN}Configuração para apps VPN (HTTP Injector, HTTP Custom):${RESET}"
    echo "---------------------------------------------------------"
    echo -e " ${TXT_YELLOW}Modo:${RESET}        SSH"
    echo -e " ${TXT_YELLOW}Host/IP:${RESET}     ${pub_ip}"
    echo -e " ${TXT_YELLOW}Porta SSH:${RESET}   ${DROPBEAR_PUB_PORT} (via Xray fallback)"
    echo -e " ${TXT_YELLOW}Usuário:${RESET}     nome criado no painel"
    echo -e " ${TXT_YELLOW}Senha:${RESET}       senha definida ao criar usuário"
    echo -e " ${TXT_YELLOW}UDPGW:${RESET}       127.0.0.1:7300"
    echo ""
    echo -e "${TXT_CYAN}Configuração alternativa via domínio CDN:${RESET}"
    echo "---------------------------------------------------------"
    [ -n "$preset_domain" ] && \
        echo -e " ${TXT_YELLOW}Host CDN:${RESET}    ${preset_domain}" || \
        echo -e " ${TXT_YELLOW}Host CDN:${RESET}    configure na opção [15] CDN Vercel"
    echo ""
    echo -e "${TXT_CYAN}Como funciona o SSH XHTTP:${RESET}"
    echo " 1. O app conecta na porta 443 via SSH"
    echo " 2. O Xray detecta que é SSH (não VLESS) pelo handshake"
    echo " 3. Redireciona automaticamente para o Dropbear :2222"
    echo " 4. O Dropbear autentica usuário+senha"
    echo " 5. UDPGW resolve DNS e tráfego UDP dentro do túnel"
    echo ""
    echo -e "${TXT_YELLOW}⚠  Usuários devem ser sincronizados com opção [4]${RESET}"
    echo "---------------------------------------------------------"
    read -rp "Enter para voltar..."
}

# --- MENU ---
while true; do
    clear
    echo -e "${TITLE_BAR}   SSH FALLBACK — TURBONET XRAY   ${RESET}"
    echo ""
    echo -e " Dropbear SSH:    $(_dropbear_status)"
    echo -e " Xray Fallback:   $(_xray_fallback_status)"
    echo ""
    echo -e "${TXT_CYAN}[1] Instalar e configurar SSH fallback completo${RESET}"
    echo -e "${TXT_CYAN}[2] Instalar apenas Dropbear${RESET}"
    echo -e "${TXT_CYAN}[3] Configurar fallback no Xray${RESET}"
    echo -e "${TXT_CYAN}[4] Sincronizar usuários DB → SSH${RESET}"
    echo -e "${TXT_CYAN}[5] Criar usuário SSH manualmente${RESET}"
    echo -e "${TXT_CYAN}[6] Remover usuário SSH${RESET}"
    echo -e "${TXT_CYAN}[7] Ver info de conexão SSH${RESET}"
    echo -e "${TXT_CYAN}[8] Ver logs Dropbear${RESET}"
    echo -e "${TXT_RED}[9] Remover SSH fallback (limpar tudo)${RESET}"
    echo -e "${TXT_CYAN}[0] Voltar${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "${opt:-0}" in
        1)
            # Instalação completa
            _install_dropbear && \
            _configure_xray_fallback && \
            _sync_ssh_users
            echo ""
            echo -e "${TXT_GREEN}==================================${RESET}"
            echo -e "${TXT_GREEN}✅ SSH FALLBACK CONFIGURADO!${RESET}"
            echo -e "${TXT_GREEN}==================================${RESET}"
            echo -e " Porta 443 agora aceita:"
            echo -e "  • ${TXT_CYAN}XHTTP/VLESS${RESET} (conexão Xray normal)"
            echo -e "  • ${TXT_YELLOW}SSH${RESET} (fallback via Dropbear)"
            read -rp "Enter..."
            ;;
        2) _install_dropbear;          read -rp "Enter..." ;;
        3) _configure_xray_fallback;   read -rp "Enter..." ;;
        4) _sync_ssh_users;            read -rp "Enter..." ;;
        5)
            read -rp "Nome do usuário SSH: " ssh_nick
            read -rp "Senha: " ssh_pass
            ssh_nick=$(echo "${ssh_nick:-}" | tr -d '[:space:]')
            ssh_pass=$(echo "${ssh_pass:-}" | tr -d '[:space:]')
            [ -n "$ssh_nick" ] && [ -n "$ssh_pass" ] && \
                _create_ssh_user "$ssh_nick" "$ssh_pass" || \
                echo -e "${TXT_RED}Nome ou senha inválidos.${RESET}"
            read -rp "Enter..."
            ;;
        6)
            read -rp "Nome do usuário para remover: " ssh_nick
            ssh_nick=$(echo "${ssh_nick:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            [ -n "$ssh_nick" ] && _remove_ssh_user "$ssh_nick" || \
                echo -e "${TXT_RED}Nome inválido.${RESET}"
            read -rp "Enter..."
            ;;
        7) _show_connection_info ;;
        8)
            journalctl -u dropbear -n 30 --no-pager 2>/dev/null || \
                cat /var/log/dropbear.log 2>/dev/null || echo "Sem logs."
            read -rp "Enter..."
            ;;
        9)
            read -rp "Remover SSH fallback e Dropbear? [s/N]: " conf
            [[ "${conf:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; continue; }
            _remove_xray_fallback
            systemctl stop    dropbear >/dev/null 2>&1 || true
            systemctl disable dropbear >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/dropbear.service.d/override.conf
            systemctl daemon-reload
            echo -e "${TXT_GREEN}✅ SSH fallback removido.${RESET}"
            read -rp "Enter..."
            ;;
        0) exit 0 ;;
        *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
