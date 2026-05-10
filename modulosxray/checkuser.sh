#!/bin/bash
# checkuser.sh - TURBONET XRAY V1.1
# CheckUser API para Xray - compativel com Conecta4G, DTunnel e outros apps
#
# Formato do users.db:
#   nick|uuid|expiry|password|conn_limit
#   joao|abc-123|2026-06-01|senha123|2
#
# Endpoint:
#   GET /checkuserxray?user=NICK&pass=SENHA
#
# Resposta:
#   {"username":"joao","count_connections":1,"expiration_date":"01/06/2026","expiration_days":30,"limit_connections":2}
#
# Opcoes de limite de conexoes:
#   0 = ilimitado (padrao)
#   1 = apenas 1 conexao
#   2 = ate 2 conexoes, etc.
#
set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

# ================================================================
# CONFIGURACOES
# ================================================================
USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
CHECKUSER_PORT="${CHECKUSER_PORT:-6000}"
PID_FILE="/tmp/checkuser_xray.pid"
PORT_FILE="/tmp/checkuser_xray.port"
LOG_FILE="/tmp/checkuser_xray.log"

XRAY_API_PORT="1080"
XRAY_BIN="/usr/local/bin/xray"
TIMEOUT_API=5

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

# ================================================================
# DETECCAO DE PORTA API
# ================================================================
detect_api_port() {
    if [ -f "$CONFIG_PATH" ] && command -v jq &>/dev/null; then
        local detected
        detected=$(jq -r '.inbounds[]? | select(.tag=="api") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1)
        if [ -n "$detected" ] && [[ "$detected" =~ ^[0-9]+$ ]]; then
            XRAY_API_PORT="$detected"
            return 0
        fi
    fi
    XRAY_API_PORT="1080"
    return 0
}

# ================================================================
# VERIFICACOES INICIAIS
# ================================================================
check_dependencies() {
    local missing=()
    
    if ! command -v python3 &>/dev/null; then
        missing+=("python3")
    fi
    
    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${TXT_RED}Dependencias faltando: ${missing[*]}${RESET}"
        return 1
    fi
    
    return 0
}

# ================================================================
# FUNCOES DE STATUS
# ================================================================
is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid; pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    return 1
}

get_status() {
    if is_running; then
        local pid port
        pid=$(cat "$PID_FILE" 2>/dev/null)
        port=$(cat "$PORT_FILE" 2>/dev/null || echo "6000")
        echo -e "${TXT_GREEN}ATIVO${RESET} (PID: $pid, Porta: $port)"
    else
        echo -e "${TXT_RED}INATIVO${RESET}"
    fi
}

# ================================================================
# SERVIDOR HTTP (Python inline)
# ================================================================
start_server() {
    local port="$1"
    
    if is_running; then
        echo -e "${TXT_RED}Ja existe um servidor CheckUser rodando.${RESET}"
        return 1
    fi
    
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${TXT_RED}Porta ${port} ja esta em uso.${RESET}"
        return 1
    fi
    
    detect_api_port
    
    if [ ! -f "$USER_DB" ]; then
        echo -e "${TXT_RED}Arquivo users.db nao encontrado: $USER_DB${RESET}"
        return 1
    fi
    
    echo -e "${TXT_YELLOW}Iniciando CheckUser na porta ${port}...${RESET}"
    
    python3 - "$port" "$USER_DB" "$CONFIG_PATH" "$XRAY_API_PORT" "$XRAY_BIN" << 'PYEOF' &
import sys, json, os, subprocess, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime

PORT     = int(sys.argv[1])
USER_DB  = sys.argv[2]
CFG      = sys.argv[3]
API_PORT = sys.argv[4]
XRAY_BIN = sys.argv[5]

def load_users():
    users = {}
    if os.path.exists(USER_DB):
        with open(USER_DB) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split('|')
                if len(parts) >= 3:
                    nick = parts[0].lower().strip()
                    users[nick] = {
                        'uuid': parts[1].strip() if len(parts) > 1 else '',
                        'expiry': parts[2].strip() if len(parts) > 2 else '',
                        'password': parts[3].strip() if len(parts) > 3 else '',
                        'conn_limit': int(parts[4]) if len(parts) > 4 and parts[4].strip().isdigit() else 0
                    }
    return users

def get_active_connections(nick):
    try:
        down = 0
        up = 0
        
        down_result = subprocess.run(
            [XRAY_BIN, 'api', 'stats',
             '-server', f'127.0.0.1:{API_PORT}',
             '-name', f'user>>>{nick}>>>traffic>>>downlink'],
            capture_output=True, timeout=5
        )
        
        for line in down_result.stdout.decode().split('\n'):
            parts = line.split()
            for i, p in enumerate(parts):
                if p == 'value' and i + 1 < len(parts):
                    down = int(parts[i + 1])
                    break
        
        up_result = subprocess.run(
            [XRAY_BIN, 'api', 'stats',
             '-server', f'127.0.0.1:{API_PORT}',
             '-name', f'user>>>{nick}>>>traffic>>>uplink'],
            capture_output=True, timeout=5
        )
        
        for line in up_result.stdout.decode().split('\n'):
            parts = line.split()
            for i, p in enumerate(parts):
                if p == 'value' and i + 1 < len(parts):
                    up = int(parts[i + 1])
                    break
        
        return 1 if (down + up) > 0 else 0
    except Exception:
        return 0

def is_expired(expiry):
    try:
        exp = datetime.strptime(expiry, '%Y-%m-%d')
        return exp < datetime.now()
    except Exception:
        return False

def days_left(expiry):
    try:
        exp = datetime.strptime(expiry, '%Y-%m-%d')
        return max(0, (exp - datetime.now()).days)
    except Exception:
        return 0

def format_date(date_str):
    try:
        d = datetime.strptime(date_str, '%Y-%m-%d')
        return d.strftime('%d/%m/%Y')
    except Exception:
        return date_str

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        
        if parsed.path == '/health':
            self.send_json(200, {'status': 'ok'})
            return
        
        if parsed.path == '/status':
            users = load_users()
            self.send_json(200, {
                'status': 'running',
                'users_count': len(users)
            })
            return
        
        if parsed.path == '/checkuserxray':
            params = parse_qs(parsed.query)
            user = params.get('user', [''])[0].lower()
            password = params.get('pass', [''])[0]
            
            if not user or not password:
                self.send_json(400, {'error': 'user and pass required'})
                return
            
            users = load_users()
            
            if user not in users:
                self.send_json(401, {'error': 'user not found'})
                return
            
            user_data = users[user]
            
            if user_data['password'] and user_data['password'] != password:
                self.send_json(401, {'error': 'invalid password'})
                return
            
            if is_expired(user_data['expiry']):
                self.send_json(403, {'error': 'subscription expired'})
                return
            
            count_connections = get_active_connections(user)
            limit = user_data['conn_limit']
            
            if limit > 0 and count_connections >= limit:
                self.send_json(403, {
                    'error': 'connection limit reached',
                    'count_connections': count_connections,
                    'limit_connections': limit
                })
                return
            
            self.send_json(200, {
                'username': user,
                'uuid': user_data['uuid'],
                'count_connections': count_connections,
                'expiration_date': format_date(user_data['expiry']),
                'expiration_days': days_left(user_data['expiry']),
                'limit_connections': limit,
                'valid': True
            })
            return
        
        self.send_json(404, {'error': 'endpoint not found'})

try:
    server = HTTPServer(('0.0.0.0', PORT), Handler)
    print(f'Server started on port {PORT}')
    server.serve_forever()
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF

    local pid=$!
    echo "$pid" > "$PID_FILE"
    echo "$port" > "$PORT_FILE"
    
    sleep 1
    
    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${TXT_GREEN}CheckUser iniciado com sucesso!${RESET}"
        return 0
    else
        echo -e "${TXT_RED}Falha ao iniciar CheckUser.${RESET}"
        rm -f "$PID_FILE" "$PORT_FILE"
        return 1
    fi
}

stop_server() {
    if ! is_running; then
        echo -e "${TXT_YELLOW}CheckUser nao esta rodando.${RESET}"
        return 0
    fi
    
    local pid; pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null
    sleep 1
    
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    
    rm -f "$PID_FILE" "$PORT_FILE"
    echo -e "${TXT_GREEN}CheckUser parado.${RESET}"
}

test_server() {
    local port
    port=$(cat "$PORT_FILE" 2>/dev/null || echo "6000")
    
    echo -e "${TXT_CYAN}Testando CheckUser em http://localhost:${port}...${RESET}"
    
    local health
    health=$(curl -sf "http://localhost:${port}/health" 2>/dev/null)
    
    if [ -n "$health" ]; then
        echo -e "${TXT_GREEN}Health check: OK${RESET}"
        echo "Resposta: $health"
    else
        echo -e "${TXT_RED}Health check: FALHOU${RESET}"
        return 1
    fi
}

show_config_link() {
    local port
    port=$(cat "$PORT_FILE" 2>/dev/null || echo "6000")

    # Detectar IP ou dominio automaticamente
    local server_addr=""

    # 1) Tenta pegar do preset.json (dominio configurado)
    if [ -f "$PRESET_FILE" ] && command -v jq &>/dev/null; then
        local domain
        domain=$(jq -r '.domain // empty' "$PRESET_FILE" 2>/dev/null)
        if [ -n "$domain" ]; then
            server_addr="$domain"
        fi
    fi

    # 2) Tenta pegar do active_domain
    if [ -z "$server_addr" ] && [ -f "$ACTIVE_DOMAIN_FILE" ]; then
        local active_domain
        active_domain=$(cat "$ACTIVE_DOMAIN_FILE" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$active_domain" ]; then
            server_addr="$active_domain"
        fi
    fi

    # 3) Fallback: IP publico
    if [ -z "$server_addr" ]; then
        server_addr=$(curl -fsSL --max-time 5 "https://icanhazip.com" 2>/dev/null | tr -d '[:space:]' || echo "")
        if [ -z "$server_addr" ]; then
            server_addr="SEU_IP"
        fi
    fi

    echo ""
    echo -e "${TXT_CYAN}========================================${RESET}"
    echo -e "${TXT_YELLOW}LINK DE CONFIGURACAO PARA APPS${RESET}"
    echo -e "${TXT_CYAN}========================================${RESET}"
    echo ""
    echo -e "URL da API: ${TXT_GREEN}http://${server_addr}:${port}/checkuserxray${RESET}"
    echo ""
    echo -e "${TXT_YELLOW}Parametros:${RESET}"
    echo "  user = nome do usuario"
    echo "  pass = senha do usuario"
    echo ""
    echo -e "${TXT_YELLOW}Exemplo:${RESET}"
    echo "  http://${server_addr}:${port}/checkuserxray?user=joao&pass=senha123"
    echo ""
    echo -e "${TXT_CYAN}========================================${RESET}"
}

check_firewall() {
    local port
    port=$(cat "$PORT_FILE" 2>/dev/null || echo "6000")
    
    echo -e "${TXT_CYAN}Verificando firewall...${RESET}"
    
    if command -v ufw &>/dev/null; then
        if ufw status | grep -q "${port}/tcp"; then
            echo -e "${TXT_GREEN}Porta ${port} ja liberada no UFW${RESET}"
        else
            echo -e "${TXT_YELLOW}Porta ${port} pode nao estar liberada no UFW${RESET}"
            echo "Execute: ufw allow ${port}/tcp"
        fi
    fi
    
    if command -v iptables &>/dev/null; then
        if iptables -L -n 2>/dev/null | grep -q "${port}"; then
            echo -e "${TXT_GREEN}Porta ${port} encontrada no iptables${RESET}"
        fi
    fi
}

# ================================================================
# MENU PRINCIPAL
# ================================================================
menu_checkuser() {
    while true; do
        clear
        echo -e "${TITLE_BAR}   CHECKUSER XRAY - TURBONET   ${RESET}"
        echo ""
        echo -e " Status: $(get_status)"
        echo ""
        echo "-----------------------------------------"
        echo -e "${TXT_CYAN}[1]${RESET} Iniciar (porta padrao: 6000)"
        echo -e "${TXT_CYAN}[2]${RESET} Iniciar em porta personalizada"
        echo -e "${TXT_CYAN}[3]${RESET} Parar servidor"
        echo -e "${TXT_CYAN}[4]${RESET} Testar"
        echo -e "${TXT_CYAN}[5]${RESET} Verificar firewall"
        echo -e "${TXT_CYAN}[6]${RESET} Gerar link de configuracao (para apps)"
        echo -e "${TXT_CYAN}[0]${RESET} Voltar"
        echo "-----------------------------------------"
        read -rp "Opcao: " opt
        
        case "$opt" in
            1) start_server 6000 ;;
            2)
                read -rp "Digite a porta: " custom_port
                if [[ "$custom_port" =~ ^[0-9]+$ ]]; then
                    start_server "$custom_port"
                else
                    echo -e "${TXT_RED}Porta invalida${RESET}"
                fi
                ;;
            3) stop_server ;;
            4) test_server ;;
            5) check_firewall ;;
            6) show_config_link ;;
            0) return 0 ;;
            *) echo -e "${TXT_RED}Opcao invalida${RESET}" ;;
        esac
        
        [ "$opt" != "0" ] && read -rp "Enter para continuar..." _
    done
}

# ================================================================
# VERIFICACOES E EXECUCAO
# ================================================================
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}Execute como root!${RESET}"
    exit 1
fi

if ! check_dependencies; then
    echo -e "${TXT_RED}Instale as dependencias e tente novamente.${RESET}"
    exit 1
fi

if [ ! -f "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}Config do Xray nao encontrado: $CONFIG_PATH${RESET}"
fi

if [ ! -f "$XRAY_BIN" ]; then
    echo -e "${TXT_RED}Xray nao encontrado: $XRAY_BIN${RESET}"
fi

menu_checkuser
