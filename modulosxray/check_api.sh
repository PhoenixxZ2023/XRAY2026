#!/bin/bash
# check_api.sh - TURBONET XRAY V1.0
# API pública /check — consulta status de usuário ou UUID via HTTP.
# Permite que clientes, revendedores ou aplicativos VPN verifiquem
# se um usuário está ativo sem precisar de acesso SSH ao servidor.
#
# Uso no menu: opção [14] API /CHECK
# Endpoints:
#   GET /check?user=NOME     → status por nome
#   GET /check?uuid=UUID     → status por UUID
#   GET /check/status        → status geral do servidor
#   GET /health              → healthcheck simples
#
# Resposta JSON:
#   {"name":"joao","uuid":"xxx","expiry":"2026-06-01","status":"active","days_left":30}

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
API_PID_FILE="/tmp/turbonet_check_api.pid"
API_PORT_FILE="/tmp/turbonet_check_api.port"
API_LOG="/tmp/turbonet_check_api.log"
DEFAULT_PORT=9090

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"; exit 1
fi

# --- HELPERS ---
_is_expired() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 0
    today_ts=$(date +%s)
    [ "$exp_ts" -lt "$today_ts" ]
}

_days_left() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo -1; return; }
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || { echo -1; return; }
    today_ts=$(date +%s)
    echo $(( (exp_ts - today_ts) / 86400 ))
}

_is_locked() {
    local nick="$1"
    [ ! -s "$CONFIG_PATH" ] && echo false && return
    if jq -e --arg lock "LOCKED_${nick}" '
        any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?; .email == $lock)
    ' "$CONFIG_PATH" >/dev/null 2>&1; then
        echo true
    else
        echo false
    fi
}

_json_user() {
    local nick="$1" uuid="$2" expiry="$3"
    local locked days status

    locked=$(_is_locked "$nick")
    days=$(_days_left "$expiry")

    if [ "$locked" = "true" ]; then
        status="suspended"
    elif _is_expired "$expiry"; then
        status="expired"
    else
        status="active"
    fi

    printf '{"name":"%s","uuid":"%s","expiry":"%s","status":"%s","days_left":%s,"locked":%s}\n' \
        "$nick" "$uuid" "$expiry" "$status" "$days" "$locked"
}

_server_info() {
    local xray_status proto port domain

    xray_status="inactive"
    systemctl is-active --quiet xray 2>/dev/null && xray_status="active"

    proto=""; port=""; domain=""
    if [ -f "$PRESET_FILE" ] && jq empty "$PRESET_FILE" 2>/dev/null; then
        proto=$(jq -r  '.network // ""' "$PRESET_FILE" 2>/dev/null || echo "")
        port=$(jq -r   '.port    // ""' "$PRESET_FILE" 2>/dev/null || echo "")
        domain=$(jq -r '.domain  // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    fi

    local total active expired suspended
    total=0; active=0; expired=0; suspended=0
    if [ -s "$USER_DB" ]; then
        while IFS='|' read -r nick uuid expiry _; do
            [ -n "${nick:-}" ] || continue
            total=$(( total + 1 ))
            if [ "$(_is_locked "$nick")" = "true" ]; then
                suspended=$(( suspended + 1 ))
            elif _is_expired "${expiry:-}"; then
                expired=$(( expired + 1 ))
            else
                active=$(( active + 1 ))
            fi
        done < "$USER_DB"
    fi

    printf '{"xray":"%s","protocol":"%s","port":"%s","domain":"%s","users":{"total":%d,"active":%d,"expired":%d,"suspended":%d}}\n' \
        "$xray_status" "$proto" "$port" "$domain" \
        "$total" "$active" "$expired" "$suspended"
}

# --- SERVIDOR HTTP (Python embutido) ---
# Usa Python3 para servir as respostas JSON — sem dependência de nginx/apache
_start_api_server() {
    local port="${1:-$DEFAULT_PORT}"

    # Verifica se porta está livre
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${TXT_RED}❌ Porta ${port} já está em uso.${RESET}"
        return 1
    fi

    echo -e "${TXT_YELLOW}Iniciando API na porta ${port}...${RESET}"

    # Gera o servidor Python
    python3 - "$port" "$USER_DB" "$CONFIG_PATH" "$PRESET_FILE" << 'PYSERVER' &
import sys, json, os, subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime

PORT     = int(sys.argv[1])
USER_DB  = sys.argv[2]
CFG      = sys.argv[3]
PRESET   = sys.argv[4]

def load_db():
    users = {}
    if os.path.exists(USER_DB):
        with open(USER_DB) as f:
            for line in f:
                parts = line.strip().split('|')
                if len(parts) >= 3:
                    users[parts[0]] = {'uuid': parts[1], 'expiry': parts[2]}
    return users

def is_locked(nick, cfg_data):
    for inb in cfg_data.get('inbounds', []):
        if inb.get('tag') == 'inbound-turbonet':
            for c in inb.get('settings', {}).get('clients', []):
                if c.get('email') == f'LOCKED_{nick}':
                    return True
    return False

def days_left(expiry):
    try:
        exp = datetime.strptime(expiry, '%Y-%m-%d')
        return (exp - datetime.now()).days
    except:
        return -1

def user_status(nick, uuid, expiry, locked):
    if locked:          return 'suspended'
    if days_left(expiry) < 0: return 'expired'
    return 'active'

def load_cfg():
    try:
        with open(CFG) as f: return json.load(f)
    except: return {}

def load_preset():
    try:
        with open(PRESET) as f: return json.load(f)
    except: return {}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass  # silencia log padrão

    def _send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        qs     = parse_qs(parsed.query)
        path   = parsed.path.rstrip('/')

        # Health check
        if path == '/health':
            self._send_json(200, {'status': 'ok', 'service': 'TURBONET XRAY Check API V1.0'})
            return

        # Status geral do servidor
        if path in ('/check/status', '/status'):
            cfg     = load_cfg()
            preset  = load_preset()
            xray_ok = subprocess.run(['systemctl','is-active','xray'],
                                     capture_output=True).returncode == 0
            users   = load_db()
            cfg_data= cfg
            total   = len(users)
            active  = sum(1 for n,u in users.items()
                          if not is_locked(n,cfg_data) and days_left(u['expiry']) >= 0)
            expired = sum(1 for u in users.values() if days_left(u['expiry']) < 0)
            suspended = total - active - expired
            self._send_json(200, {
                'xray':      'active' if xray_ok else 'inactive',
                'protocol':  preset.get('network',''),
                'port':      preset.get('port',''),
                'domain':    preset.get('domain',''),
                'users': {
                    'total':     total,
                    'active':    active,
                    'expired':   expired,
                    'suspended': suspended
                }
            })
            return

        # Consulta por usuário ou UUID
        if path == '/check':
            cfg_data = load_cfg()
            users    = load_db()

            # Por nome
            if 'user' in qs:
                nick = qs['user'][0].lower().strip()
                if nick not in users:
                    self._send_json(404, {'error': 'user not found', 'name': nick})
                    return
                u   = users[nick]
                locked = is_locked(nick, cfg_data)
                dl  = days_left(u['expiry'])
                self._send_json(200, {
                    'name':      nick,
                    'uuid':      u['uuid'],
                    'expiry':    u['expiry'],
                    'status':    user_status(nick, u['uuid'], u['expiry'], locked),
                    'days_left': dl,
                    'locked':    locked
                })
                return

            # Por UUID
            if 'uuid' in qs:
                target_uuid = qs['uuid'][0].lower().strip()
                for nick, u in users.items():
                    if u['uuid'].lower() == target_uuid:
                        locked = is_locked(nick, cfg_data)
                        dl     = days_left(u['expiry'])
                        self._send_json(200, {
                            'name':      nick,
                            'uuid':      u['uuid'],
                            'expiry':    u['expiry'],
                            'status':    user_status(nick, u['uuid'], u['expiry'], locked),
                            'days_left': dl,
                            'locked':    locked
                        })
                        return
                self._send_json(404, {'error': 'uuid not found'})
                return

            self._send_json(400, {'error': 'use ?user=NAME or ?uuid=UUID'})
            return

        self._send_json(404, {'error': 'not found', 'endpoints': [
            '/check?user=NAME',
            '/check?uuid=UUID',
            '/check/status',
            '/health'
        ]})

HTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
PYSERVER

    local server_pid=$!
    sleep 1

    if kill -0 "$server_pid" 2>/dev/null; then
        echo "$server_pid" > "$API_PID_FILE"
        echo "$port"       > "$API_PORT_FILE"
        echo -e "${TXT_GREEN}✅ API iniciada! PID: ${server_pid}${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}Endpoints disponíveis:${RESET}"
        local pub_ip
        pub_ip=$(curl -4fsSL --max-time 5 https://icanhazip.com 2>/dev/null || echo "SEU_IP")
        echo -e "  ${TXT_YELLOW}GET${RESET} http://${pub_ip}:${port}/check?user=NOME"
        echo -e "  ${TXT_YELLOW}GET${RESET} http://${pub_ip}:${port}/check?uuid=UUID"
        echo -e "  ${TXT_YELLOW}GET${RESET} http://${pub_ip}:${port}/check/status"
        echo -e "  ${TXT_YELLOW}GET${RESET} http://${pub_ip}:${port}/health"
        echo ""
        echo -e " ${TXT_YELLOW}Exemplo de resposta:${RESET}"
        echo -e '  {"name":"joao","uuid":"xxxx","expiry":"2026-06-01","status":"active","days_left":30}'
        echo ""
        echo -e " ${TXT_RED}⚠  Certifique-se de que a porta ${port} está aberta no firewall.${RESET}"
        echo -e " Para parar: volte a este menu e selecione [2] Parar API"
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar a API.${RESET}"
        rm -f "$API_PID_FILE" "$API_PORT_FILE"
        return 1
    fi
}

_stop_api_server() {
    if [ ! -f "$API_PID_FILE" ]; then
        echo -e "${TXT_YELLOW}API não está rodando.${RESET}"
        return 0
    fi
    local pid; pid=$(cat "$API_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        sleep 1
        echo -e "${TXT_GREEN}✅ API parada (PID ${pid}).${RESET}"
    else
        echo -e "${TXT_YELLOW}Processo já não existe.${RESET}"
    fi
    rm -f "$API_PID_FILE" "$API_PORT_FILE"
}

_api_status() {
    if [ ! -f "$API_PID_FILE" ]; then
        echo -e " ${TXT_RED}INATIVA${RESET}"
        return
    fi
    local pid; pid=$(cat "$API_PID_FILE")
    local port=""; [ -f "$API_PORT_FILE" ] && port=$(cat "$API_PORT_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo -e " ${TXT_GREEN}ATIVA${RESET} — PID ${pid}, porta ${port}"
    else
        echo -e " ${TXT_RED}PROCESSO MORTO${RESET} (PID ${pid} não existe)"
        rm -f "$API_PID_FILE" "$API_PORT_FILE"
    fi
}

_test_api() {
    if [ ! -f "$API_PORT_FILE" ]; then
        echo -e "${TXT_RED}API não está rodando.${RESET}"; return
    fi
    local port; port=$(cat "$API_PORT_FILE")
    echo -e "${TXT_CYAN}Testando API na porta ${port}...${RESET}"
    echo ""

    echo -e "${TXT_YELLOW}[GET /health]${RESET}"
    curl -s "http://127.0.0.1:${port}/health" | python3 -m json.tool 2>/dev/null || \
        curl -s "http://127.0.0.1:${port}/health"
    echo ""

    echo -e "${TXT_YELLOW}[GET /check/status]${RESET}"
    curl -s "http://127.0.0.1:${port}/check/status" | python3 -m json.tool 2>/dev/null || \
        curl -s "http://127.0.0.1:${port}/check/status"
    echo ""

    if [ -s "$USER_DB" ]; then
        local first_user; first_user=$(head -1 "$USER_DB" | cut -d'|' -f1)
        echo -e "${TXT_YELLOW}[GET /check?user=${first_user}]${RESET}"
        curl -s "http://127.0.0.1:${port}/check?user=${first_user}" | python3 -m json.tool 2>/dev/null || \
            curl -s "http://127.0.0.1:${port}/check?user=${first_user}"
        echo ""
    fi
}

# --- MENU ---
while true; do
    clear
    echo -e "${TITLE_BAR}   API /CHECK — TURBONET XRAY   ${RESET}"
    echo ""
    echo -e " Status:$(_api_status)"
    echo ""
    echo -e "${TXT_CYAN}[1] Iniciar API (porta padrão: ${DEFAULT_PORT})${RESET}"
    echo -e "${TXT_CYAN}[2] Iniciar API em porta personalizada${RESET}"
    echo -e "${TXT_RED}[3] Parar API${RESET}"
    echo -e "${TXT_CYAN}[4] Testar API (curl local)${RESET}"
    echo -e "${TXT_CYAN}[5] Ver logs${RESET}"
    echo -e "${TXT_CYAN}[0] Voltar${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "${opt:-0}" in
        1) _start_api_server "$DEFAULT_PORT"; read -rp "Enter..." ;;
        2)
            read -rp "Porta (1024-65535): " custom_port
            if [[ "$custom_port" =~ ^[0-9]+$ ]] && \
               [ "$custom_port" -ge 1024 ] && [ "$custom_port" -le 65535 ]; then
                _start_api_server "$custom_port"
            else
                echo -e "${TXT_RED}Porta inválida.${RESET}"
            fi
            read -rp "Enter..."
            ;;
        3) _stop_api_server; read -rp "Enter..." ;;
        4) _test_api; read -rp "Enter..." ;;
        5)
            if [ -f "$API_LOG" ]; then
                tail -30 "$API_LOG"
            else
                echo "Sem logs disponíveis."
            fi
            read -rp "Enter..."
            ;;
        0) exit 0 ;;
        *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
