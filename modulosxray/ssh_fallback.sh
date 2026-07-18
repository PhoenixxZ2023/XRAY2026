#!/bin/bash
# ssh_fallback.sh - TURBONET XRAY V1.0
# SSH completo integrado ao Xray XHTTP:
#   - Dropbear na porta 22 (loopback) — acesso via Xray fallback porta 443
#   - Proxy porta 8080: TCP Direto (SSH over HTTP)
#   - Proxy porta 80: WebSocket SSH (ws+ssh) - Ideal para CDN
#   - Proxy porta 1080: SOCKS5
#   - Um cadastro = acesso XHTTP/VLESS + SSH simultaneamente
# Correções Aplicadas:
#   - Prevenção contra SOCKS5 Open Proxy (autenticação PAM obrigatória)
#   - Detecção dinâmica de interface de rede para o Dante (evita quebras fora de eth0)
#   - WebSocket movido para porta 80 nativa / Proxy TCP movido para 8080

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
DROPBEAR_PORT=22
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
    chmod 0640 "$CONFIG_PATH"
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

# --- STATUS ---
_dropbear_status() {
    systemctl is-active --quiet turbonet-dropbear 2>/dev/null && \
        echo -e "${TXT_GREEN}ATIVO (porta 22 loopback)${RESET}" || \
        echo -e "${TXT_RED}INATIVO${RESET}"
}

_xray_fallback_status() {
    [ ! -s "$CONFIG_PATH" ] && { echo -e "${TXT_RED}config não encontrado${RESET}"; return; }
    local fb
    fb=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") |
         .settings.fallbacks[]? | select(.dest==22) | .dest' \
         "$CONFIG_PATH" 2>/dev/null || echo "")
    [ -n "$fb" ] && echo -e "${TXT_GREEN}CONFIGURADO (443→22)${RESET}" || \
                    echo -e "${TXT_RED}NÃO CONFIGURADO${RESET}"
}

_proxy80_status() {
    systemctl is-active --quiet turbonet-wssh 2>/dev/null && \
        echo -e "${TXT_GREEN}ATIVO (WS porta 80)${RESET}" || \
        echo -e "${TXT_RED}INATIVO${RESET}"
}

# --- INSTALAR DROPBEAR NA PORTA 22 ---
_install_dropbear() {
    echo -e "${TXT_YELLOW}Instalando Dropbear SSH na porta 22...${RESET}"
    : > "$LOG_FILE"
    ensure_pkg dropbear dropbear

    # Parar e desabilitar serviço padrão do pacote (usa init LSB que conflita)
    systemctl stop    dropbear 2>/dev/null || true
    systemctl disable dropbear 2>/dev/null || true
    service   dropbear stop    2>/dev/null || true
    update-rc.d dropbear disable 2>/dev/null || true
    sleep 1

    # Gerar chaves do host
    mkdir -p /etc/dropbear
    [ -f /etc/dropbear/dropbear_rsa_host_key ] || \
        dropbearkey -t rsa   -f /etc/dropbear/dropbear_rsa_host_key   >>"$LOG_FILE" 2>&1 || true
    [ -f /etc/dropbear/dropbear_ecdsa_host_key ] || \
        dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key >>"$LOG_FILE" 2>&1 || true

    # Criar serviço systemd próprio na porta 22 (loopback)
    cat > /etc/systemd/system/turbonet-dropbear.service << 'SVCEOF'
[Unit]
Description=TURBONET XRAY Dropbear SSH porta 22 (loopback)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/dropbear -F -E -p 127.0.0.1:22 -w -j -k
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable  turbonet-dropbear >/dev/null 2>&1
    systemctl restart turbonet-dropbear >/dev/null 2>&1
    sleep 2

    if systemctl is-active --quiet turbonet-dropbear 2>/dev/null; then
        echo -e "${TXT_GREEN}✅ Dropbear ativo em 127.0.0.1:22${RESET}"
        return 0
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar Dropbear.${RESET}"
        journalctl -u turbonet-dropbear -n 15 --no-pager 2>/dev/null || true
        return 1
    fi
}

# --- CONFIGURAR FALLBACK NO XRAY (443 → 22) ---
_configure_xray_fallback() {
    echo -e "${TXT_YELLOW}Configurando fallback SSH no Xray (443→22)...${RESET}"

    [ -s "$CONFIG_PATH" ] || { echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"; return 1; }
    jq empty "$CONFIG_PATH" 2>/dev/null || { echo -e "${TXT_RED}❌ config.json inválido.${RESET}"; return 1; }

    local proto
    proto=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .protocol // ""' \
            "$CONFIG_PATH" 2>/dev/null || echo "")

    if [ "$proto" != "vless" ]; then
        echo -e "${TXT_RED}❌ Fallback SSH requer protocolo VLESS.${RESET}"
        echo -e " Protocolo atual: ${proto:-não encontrado}"
        echo -e " Configure o Xray com VLESS+XHTTP na opção [04] do menu."
        return 1
    fi

    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    local tmp; tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

    jq '(.inbounds[] | select(.tag=="inbound-turbonet") | .settings.fallbacks) =
        [{"name":"","alpn":"","path":"","dest":22,"xver":0}]' \
        "$CONFIG_PATH" > "$tmp" 2>>"$LOG_FILE"

    if ! jq empty "$tmp" 2>/dev/null; then
        echo -e "${TXT_RED}❌ Falha ao gerar config.${RESET}"
        rm -f "$tmp"; return 1
    fi

    mv -f "$tmp" "$CONFIG_PATH"
    _apply_config_perms

    if ! systemctl restart xray >/dev/null 2>&1 || ! _wait_xray_active; then
        echo -e "${TXT_RED}❌ Xray falhou. Revertendo...${RESET}"
        mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        _apply_config_perms
        systemctl restart xray >/dev/null 2>&1 || true
        return 1
    fi
    echo -e "${TXT_GREEN}✅ Fallback configurado: porta 443 → SSH :22${RESET}"
}

# --- REMOVER FALLBACK DO XRAY ---
_remove_xray_fallback() {
    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    local tmp; tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

    jq '(.inbounds[] | select(.tag=="inbound-turbonet") | .settings.fallbacks) = []' \
        "$CONFIG_PATH" > "$tmp" 2>/dev/null

    if jq empty "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CONFIG_PATH"
        _apply_config_perms
        systemctl restart xray >/dev/null 2>&1 || true
        echo -e "${TXT_GREEN}✅ Fallbacks removidos.${RESET}"
    else
        rm -f "$tmp"
        echo -e "${TXT_RED}❌ Falha ao remover fallbacks.${RESET}"
    fi
}

# --- PROXY PORTA 80 E EXTRAS ---
_setup_proxy80() {
    echo -e "${TXT_YELLOW}Configurando proxies SSH (TCP, WebSocket e SOCKS5)...${RESET}"
    echo ""
    echo -e "${TXT_CYAN}Tipos de proxy disponíveis:${RESET}"
    echo " [1] TCP direto (SSH over HTTP) — Porta 8080"
    echo " [2] SOCKS5 (via dante) — Porta 1080"
    echo " [3] WebSocket SSH (ws+ssh) — Porta 80 (Recomendado para CDN)"
    echo " [4] Todos os modos (recomendado)"
    read -rp "Opção [1-4, Enter=4]: " proxy_opt
    proxy_opt="${proxy_opt:-4}"

    # Verificar porta 80 e 8080
    if ss -tlnp 2>/dev/null | grep -qE ":(80|8080) "; then
        echo -e "${TXT_YELLOW}⚠  Portas de proxy em uso. Liberando...${RESET}"
        systemctl stop nginx  2>/dev/null || true
        systemctl stop apache2 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true
        fuser -k 8080/tcp 2>/dev/null || true
        sleep 1
    fi

    ensure_pkg socat socat

    # --- MODO 1: TCP direto porta 8080 → SSH 22 ---
    if [ "$proxy_opt" = "1" ] || [ "$proxy_opt" = "4" ]; then
        cat > /etc/systemd/system/turbonet-proxy80.service << 'P80EOF'
[Unit]
Description=TURBONET XRAY SSH Proxy TCP porta 8080
After=network.target turbonet-dropbear.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:8080,fork,reuseaddr TCP:127.0.0.1:22
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
P80EOF
        systemctl daemon-reload
        systemctl enable  turbonet-proxy80 >/dev/null 2>&1
        systemctl restart turbonet-proxy80 >/dev/null 2>&1
    fi

    # --- MODO 2: SOCKS5 via dante ---
    if [ "$proxy_opt" = "2" ] || [ "$proxy_opt" = "4" ]; then
        ensure_pkg sockd dante-server 2>/dev/null || ensure_pkg sockd danted 2>/dev/null || true
        if command -v sockd &>/dev/null || command -v danted &>/dev/null; then
            local dante_bin
            dante_bin=$(command -v sockd 2>/dev/null || command -v danted 2>/dev/null)
            
            # Detectar interface principal dinamicamente
            local EXT_IF
            EXT_IF=$(ip route get 8.8.8.8 | awk -- '{printf $5}')

            cat > /etc/danted.conf << DANTEEOF
logoutput: /tmp/dante.log
internal: 0.0.0.0 port = 1080
external: ${EXT_IF}
clientmethod: none
socksmethod: username
user.privileged: root
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    socksmethod: username
    log: error
}
DANTEEOF

            cat > /etc/systemd/system/turbonet-socks5.service << SOCKS5EOF
[Unit]
Description=TURBONET XRAY SOCKS5 Proxy porta 1080
After=network.target

[Service]
Type=simple
ExecStart=${dante_bin} -f /etc/danted.conf -N 1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SOCKS5EOF
            systemctl daemon-reload
            systemctl enable  turbonet-socks5 >/dev/null 2>&1
            systemctl restart turbonet-socks5 >/dev/null 2>&1
            echo -e "${TXT_GREEN}✅ SOCKS5 ativo na porta 1080 (Protegido com Senha)${RESET}"
        else
            echo -e "${TXT_YELLOW}⚠  dante não disponível — pulando SOCKS5.${RESET}"
        fi
    fi

    # --- MODO 3: WebSocket SSH (porta 80) ---
    if [ "$proxy_opt" = "3" ] || [ "$proxy_opt" = "4" ]; then
        cat > /usr/local/bin/turbonet-wssh.py << 'WSEOF'
#!/usr/bin/env python3
# TURBONET XRAY - WebSocket SSH Bridge
# Escuta na porta 80, faz bridge para SSH 127.0.0.1:22
import asyncio, socket, sys
WS_PORT  = 80
SSH_HOST = '127.0.0.1'
SSH_PORT = 22

HANDSHAKE = (
    b'HTTP/1.1 101 Switching Protocols\r\n'
    b'Upgrade: websocket\r\n'
    b'Connection: Upgrade\r\n'
    b'Sec-WebSocket-Accept: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n')

async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(4096)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except:
        pass
    finally:
        writer.close()

async def handle(r, w):
    try:
        head = b''
        while b'\r\n\r\n' not in head:
            head += await r.read(1024)
        w.write(HANDSHAKE)
        await w.drain()
        sr, sw = await asyncio.open_connection(SSH_HOST, SSH_PORT)
        await asyncio.gather(pipe(r, sw), pipe(sr, w))
    except:
        pass
    finally:
        w.close()

async def main():
    srv = await asyncio.start_server(handle, '0.0.0.0', WS_PORT)
    async with srv:
        await srv.serve_forever()

asyncio.run(main())
WSEOF
        chmod 755 /usr/local/bin/turbonet-wssh.py

        cat > /etc/systemd/system/turbonet-wssh.service << 'WSSVCEOF'
[Unit]
Description=TURBONET XRAY WebSocket SSH Bridge porta 80
After=network.target turbonet-dropbear.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/turbonet-wssh.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
WSSVCEOF
        systemctl daemon-reload
        systemctl enable  turbonet-wssh >/dev/null 2>&1
        systemctl restart turbonet-wssh >/dev/null 2>&1
        sleep 1
        systemctl is-active --quiet turbonet-wssh 2>/dev/null && \
            echo -e "${TXT_GREEN}✅ WebSocket SSH ativo na porta 80${RESET}" || \
            echo -e "${TXT_YELLOW}⚠  WebSocket SSH falhou.${RESET}"
    fi

    # --- PORTA 80 REMOTE (proxy reverso SSH sobre HTTP) ---
    if [ "$proxy_opt" = "4" ]; then
        echo -e "${TXT_YELLOW}Adicionando rota /ssh no Xray...${RESET}"
        if [ -s "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null; then
            local tmp; tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
            jq '(.inbounds[] | select(.tag=="inbound-turbonet") | .settings.fallbacks) =
                [
                    {"name":"","alpn":"","path":"/ssh","dest":22,"xver":0},
                    {"name":"","alpn":"","path":"","dest":22,"xver":0}
                ]' "$CONFIG_PATH" > "$tmp" 2>/dev/null

            if jq empty "$tmp" 2>/dev/null; then
                cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
                mv -f "$tmp" "$CONFIG_PATH"
                _apply_config_perms
                systemctl restart xray >/dev/null 2>&1 || true
                echo -e "${TXT_GREEN}✅ Rota /ssh adicionada no Xray.${RESET}"
            else
                rm -f "$tmp"
            fi
        fi
    fi
    sleep 1

    local pub_ip
    pub_ip=$(curl -4fsSL --max-time 5 https://icanhazip.com 2>/dev/null || echo "SEU_IP")
    echo ""
    echo -e "${TXT_GREEN}================================================${RESET}"
    echo -e "${TXT_GREEN}✅ PROXY SSH COMPLETO CONFIGURADO${RESET}"
    echo -e "${TXT_GREEN}================================================${RESET}"
    echo ""
    echo -e " ${TXT_CYAN}Conexões disponíveis:${RESET}"
    echo -e "  SSH direto 443:     ${TXT_YELLOW}${pub_ip}:443${RESET} (via Xray fallback)"
    echo -e "  SSH proxy TCP 8080: ${TXT_YELLOW}${pub_ip}:8080${RESET}"
    echo -e "  SSH WebSocket 80:   ${TXT_YELLOW}ws://${pub_ip}:80${RESET} (Ideal Azion CDN)"
    echo -e "  SOCKS5:             ${TXT_YELLOW}${pub_ip}:1080${RESET}"
    echo ""
    echo -e " ${TXT_CYAN}Configuração no app (HTTP Injector/HTTP Custom):${RESET}"
    echo -e "  Modo SSH + Host: ${TXT_YELLOW}${pub_ip}${RESET}"
    echo -e "  Porta: ${TXT_YELLOW}443${RESET} ou ${TXT_YELLOW}80${RESET}"
    echo -e "  Usuário/Senha: ${TXT_YELLOW}mesmo do painel TURBONET XRAY${RESET}"
    echo -e "  UDPGW: ${TXT_YELLOW}127.0.0.1:7300${RESET}"
    echo ""
    echo -e " ${TXT_CYAN}Com Azion CDN:${RESET}"
    echo -e "  Host CDN: ${TXT_YELLOW}turbonet.azion.app${RESET} → VPS:80 ou VPS:443"
    echo -e "${TXT_GREEN}================================================${RESET}"
}

_remove_proxy80() {
    for svc in turbonet-proxy80 turbonet-socks5 turbonet-wssh; do
        systemctl stop    "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${svc}.service"
    done
    rm -f /usr/local/bin/turbonet-wssh.py
    systemctl daemon-reload
    echo -e "${TXT_GREEN}✅ Proxies removidos.${RESET}"
}

# --- SINCRONIZAR USERS.DB → SSH ---
_sync_ssh_users() {
    echo -e "${TXT_YELLOW}Sincronizando usuários DB → SSH...${RESET}"
    local count=0
    [ -s "$USER_DB" ] || { echo -e "${TXT_YELLOW}DB vazio.${RESET}"; return; }

    while IFS='|' read -r nick uuid expiry pass limit _rest; do
        [ -n "${nick:-}" ] && [ -n "${pass:-}" ] || continue

        local exp_ts today_ts
        exp_ts=$(date -d "${expiry:-2000-01-01}" +%s 2>/dev/null || echo 0)
        today_ts=$(date +%s)

        if [ "$exp_ts" -lt "$today_ts" ]; then
            id "$nick" &>/dev/null && userdel "$nick" 2>/dev/null || true
            continue
        fi

        local locked=false
        jq -e --arg lock "LOCKED_${nick}" '
            any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?;
                .email == $lock)' "$CONFIG_PATH" >/dev/null 2>&1 && locked=true

        if [ "$locked" = "true" ]; then
            id "$nick" &>/dev/null && passwd -l "$nick" >/dev/null 2>&1 || true
            continue
        fi

        id "$nick" &>/dev/null || useradd -M -s /bin/false "$nick" 2>/dev/null || true
        echo "${nick}:${pass}" | chpasswd 2>/dev/null || true
        count=$(( count + 1 ))
    done < "$USER_DB"

    echo -e "${TXT_GREEN}✅ Sincronização concluída: ${count} usuário(s).${RESET}"
}

_show_info() {
    local pub_ip
    pub_ip=$(curl -4fsSL --max-time 5 https://icanhazip.com 2>/dev/null || echo "SEU_IP")
    local preset_domain=""
    [ -f "/usr/local/etc/xray/preset.json" ] && \
        preset_domain=$(jq -r '.domain // ""' /usr/local/etc/xray/preset.json 2>/dev/null || echo "")

    clear
    echo -e "${TITLE_BAR}   INFO DE CONEXÃO SSH XHTTP   ${RESET}"
    echo ""
    echo -e "${TXT_CYAN}━━━━ MODO XHTTP/VLESS (Xray) ━━━━━━━━━━━━━━━${RESET}"
    echo -e " Host: ${TXT_YELLOW}${pub_ip}${RESET} ou ${TXT_YELLOW}${preset_domain:-domínio CDN}${RESET}"
    echo -e " Porta: ${TXT_YELLOW}443${RESET} | Protocolo: XHTTP | UUID do usuário"
    echo ""
    echo -e "${TXT_CYAN}━━━━ MODO SSH (mesma porta 443 via fallback) ━${RESET}"
    echo -e " Host: ${TXT_YELLOW}${pub_ip}${RESET}"
    echo -e " Porta: ${TXT_YELLOW}443${RESET} | Usuário+Senha do painel"
    echo -e " UDPGW: ${TXT_YELLOW}127.0.0.1:7300${RESET}"
    echo ""
    echo -e "${TXT_CYAN}━━━━ MODO SSH PORTA 8080 (proxy TCP) ━━━━━━━━${RESET}"
    echo -e " Host: ${TXT_YELLOW}${pub_ip}${RESET} | Porta: ${TXT_YELLOW}8080${RESET}"
    echo ""
    echo -e "${TXT_CYAN}━━━━ WEBSOCKET SSH (porta 80) ━━━━━━━━━━━━━${RESET}"
    echo -e " URL: ${TXT_YELLOW}ws://${pub_ip}:80${RESET}"
    echo ""
    echo -e "${TXT_CYAN}━━━━ SOCKS5 (porta 1080) ━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e " Host: ${TXT_YELLOW}${pub_ip}:1080${RESET} (Exige Usuário/Senha do painel)"
    echo ""
    echo -e "${TXT_CYAN}━━━━ COM AZION CDN ━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e " Configure Azion: porta 80/443 → ${pub_ip}"
    echo -e " Host CDN: ${TXT_YELLOW}${preset_domain:-configure em [15] CDN Vercel}${RESET}"
    echo ""
    read -rp "Enter para voltar..."
}

# --- MENU ---
while true; do
    clear
    echo -e "${TITLE_BAR}   SSH FALLBACK + PROXY — TURBONET XRAY   ${RESET}"
    echo ""
    echo -e " Dropbear SSH:   $(_dropbear_status)"
    echo -e " Xray Fallback:  $(_xray_fallback_status)"
    echo -e " Proxy porta 80: $(_proxy80_status)"
    echo ""
    echo -e "${TXT_GREEN}[1] Instalação completa (recomendado)${RESET}"
    echo "    → Dropbear :22 + Xray fallback + Proxy 80 + WS + SOCKS5"
    echo ""
    echo -e "${TXT_CYAN}[2] Instalar apenas Dropbear (porta 22)${RESET}"
    echo -e "${TXT_CYAN}[3] Configurar fallback no Xray (443→22)${RESET}"
    echo -e "${TXT_CYAN}[4] Ativar proxies (Porta 80, 8080, 1080)${RESET}"
    echo -e "${TXT_CYAN}[5] Sincronizar usuários DB → SSH${RESET}"
    echo -e "${TXT_CYAN}[6] Criar usuário SSH manualmente${RESET}"
    echo -e "${TXT_CYAN}[7] Ver info de conexão${RESET}"
    echo -e "${TXT_CYAN}[8] Ver logs Dropbear${RESET}"
    echo -e "${TXT_RED}[9] Remover proxies (80/8080/1080)${RESET}"
    echo -e "${TXT_RED}[10] Remover tudo (Dropbear + fallback + proxies)${RESET}"
    echo -e "${TXT_CYAN}[0] Voltar${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "${opt:-0}" in
        1)
            _install_dropbear && \
            _configure_xray_fallback && \
            _setup_proxy80 && \
            _sync_ssh_users
            read -rp "Enter..."
            ;;
        2) _install_dropbear;          read -rp "Enter..." ;;
        3) _configure_xray_fallback;   read -rp "Enter..." ;;
        4) _setup_proxy80;             read -rp "Enter..." ;;
        5) _sync_ssh_users;            read -rp "Enter..." ;;
        6)
            read -rp "Nome: " sn; read -rp "Senha: " sp
            sn=$(echo "${sn:-}" | tr -d '[:space:]')
            sp=$(echo "${sp:-}" | tr -d '[:space:]')
            if [ -n "$sn" ] && [ -n "$sp" ]; then
                id "$sn" &>/dev/null || useradd -M -s /bin/false "$sn" 2>/dev/null || true
                echo "${sn}:${sp}" | chpasswd
                echo -e "${TXT_GREEN}✅ Usuário SSH '${sn}' criado/atualizado.${RESET}"
            else
                echo -e "${TXT_RED}Nome ou senha inválidos.${RESET}"
            fi
            read -rp "Enter..."
            ;;
        7) _show_info ;;
        8)
            journalctl -u turbonet-dropbear -n 30 --no-pager 2>/dev/null || \
                echo "Sem logs."
            read -rp "Enter..."
            ;;
        9)
            _remove_proxy80
            read -rp "Enter..."
            ;;
        10)
            read -rp "Remover tudo? [s/N]: " conf
            [[ "${conf:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; continue; }
            _remove_xray_fallback
            _remove_proxy80
            systemctl stop    turbonet-dropbear >/dev/null 2>&1 || true
            systemctl disable turbonet-dropbear >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/turbonet-dropbear.service
            systemctl daemon-reload
            echo -e "${TXT_GREEN}✅ Tudo removido.${RESET}"
            read -rp "Enter..."
            ;;
        0) exit 0 ;;
        *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
