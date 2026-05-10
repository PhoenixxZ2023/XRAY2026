#!/bin/bash
# checkuser.sh - TURBONET XRAY V1.0
# CheckUser API para Xray — compatível com Conecta4G, DTunnel e outros apps
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
# Opções de limite de conexões:
#   0 = ilimitado (padrão)
#   1 = apenas 1 conexão
#   2 = até 2 conexões, etc.
#
set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

# ================================================================
# CONFIGURAÇÕES
# ================================================================
USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
CHECKUSER_PORT="${CHECKUSER_PORT:-6000}"
PID_FILE="/tmp/checkuser_xray.pid"
PORT_FILE="/tmp/checkuser_xray.port"
LOG_FILE="/tmp/checkuser_xray.log"

# Configuração de limite de conexões
XRAY_API_PORT=""
XRAY_BIN="/usr/local/bin/xray"
TIMEOUT_API=5

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

# ================================================================
# DETECÇÃO DE PORTA API
# ================================================================
detect_api_port() {
    if [ -f "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null; then
        XRAY_API_PORT=$(jq -r '.inbounds[]? | select(.tag=="api") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1)
    fi
    [ -z "$XRAY_API_PORT" ] && XRAY_API_PORT="1080"
}

# ================================================================
# FUNÇÕES DE CONSULTA
# ================================================================

# Busca usuário no DB
get_user_from_db() {
    local nick="$1"
    grep "^${nick}|" "$USER_DB" 2>/dev/null | head -1
}

# Obtém conexões ativas via API do Xray
get_active_connections() {
    local nick="$1"
    detect_api_port

    if [ ! -f "$CONFIG_PATH" ] || ! jq empty "$CONFIG_PATH" 2>/dev/null; then
        echo "0"
        return
    fi

    local down up
    down=$(timeout "$TIMEOUT_API" "$XRAY_BIN" api stats \
        -server="127.0.0.1:$XRAY_API_PORT" \
        -name "user>>>${nick}>>>traffic>>>downlink" 2>/dev/null \
        | awk '/value/ {print $2; exit}' || echo "0")

    up=$(timeout "$TIMEOUT_API" "$XRAY_BIN" api stats \
        -server="127.0.0.1:$XRAY_API_PORT" \
        -name "user>>>${nick}>>>traffic>>>uplink" 2>/dev/null \
        | awk '/value/ {print $2; exit}' || echo "0")

    # Se houver tráfego recente (últimos 60s), considera conectado
    local total=$(( down + up ))
    if [ "$total" -gt 0 ]; then
        echo "1"  # Conexão ativa
    else
        echo "0"
    fi
}

# Valida usuário e senha (retorna 0 se válido)
validate_credentials() {
    local nick="$1" pass="$2"
    local line

    line=$(get_user_from_db "$nick")
    [ -z "$line" ] && return 1

    local stored_pass
    stored_pass=$(echo "$line" | cut -d'|' -f4)

    # Timing-safe comparison
    if [ "${#pass}" -eq "${#stored_pass}" ]; then
        if [ "$pass" = "$stored_pass" ]; then
            return 0
        fi
    fi
    return 1
}

# Verifica se usuário está vencido
is_expired() {
    local expiry="$1"
    local exp_ts now_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 0
    now_ts=$(date +%s)
    [ "$exp_ts" -lt "$now_ts" ]
}

# Calcula dias restantes
days_left() {
    local expiry="$1"
    local exp_ts now_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || { echo "0"; return; }
    now_ts=$(date +%s)
    echo $(( (exp_ts - now_ts) / 86400 ))
}

# Formata data para DD/MM/YYYY
format_date() {
    local date="$1"
    local year month day
    year=$(echo "$date" | cut -d'-' -f1)
    month=$(echo "$date" | cut -d'-' -f2)
    day=$(echo "$date" | cut -d'-' -f3)
    printf "%02d/%02d/%04d" "$day" "$month" "$year"
}

# Gera JSON de resposta
generate_json_response() {
    local nick="$1" conn_count="$2" expiry="$3" days="$4" limit="$5"

    local exp_fmt
    exp_fmt=$(format_date "$expiry")

    # Se vencido, days_left retorna negativo
    if [ "$days" -lt 0 ]; then
        days=0
    fi

    # Se limite for 0, significa ilimitado
    # count_connections mostra conexões atuais

    cat << EOF
{"username":"${nick}","count_connections":${conn_count},"expiration_date":"${exp_fmt}","expiration_days":${days},"limit_connections":${limit}}
EOF
}

# Gera JSON de erro
generate_error() {
    local msg="$1"
    echo "{\"error\":\"${msg}\"}"
}

# ================================================================
# SERVIDOR HTTP (Python)
# ================================================================
start_server() {
    local port="$1"

    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${TXT_RED}❌ Porta ${port} já está em uso.${RESET}"
        return 1
    fi

    detect_api_port
    echo -e "${TXT_YELLOW}Iniciando CheckUser na porta ${port}...${RESET}"

    python3 - "$port" "$USER_DB" "$CONFIG_PATH" "$XRAY_API_PORT" "$XRAY_BIN" << 'PYSERVER' &
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
                parts = line.strip().split('|')
                if len(parts) >= 5:
                    users[parts[0].lower()] = {
                        'uuid': parts[1],
                        'expiry': parts[2],
                        'password': parts[3],
                        'conn_limit': int(parts[4]) if parts[4].isdigit() else 0
                    }
    return users

def get_active_connections(nick):
    try:
        down_result = subprocess.run(
            [XRAY_BIN, 'api', 'stats',
             '-server', f'127.0.0.1:{API_PORT}',
             '-name', f'user>>>{nick}>>>traffic>>>downlink'],
            capture_output=True, timeout=5
        )
        down = 0
        for line in down_result.stdout.decode().split('\n'):
            if 'value' in line:
                parts = line.split()
                for i, p in enumerate(parts):
                    if p == 'value' and i + 1 < len(parts):
                        down = int(parts[i + 1])
                        break
                break

        up_result = subprocess.run(
            [XRAY_BIN, 'api', 'stats',
             '-server', f'127.0.0.1:{API_PORT}',
             '-name', f'user>>>{nick}>>>traffic>>>uplink'],
            capture_output=True, timeout=5
        )
        up = 0
        for line in up_result.stdout.decode().split('\n'):
            if 'value' in line:
                parts = line.split()
                for i, p in enumerate(parts):
                    if p == 'value' and i + 1 < len(parts):
                        up = int(parts[i + 1])
                        break
                break

        return 1 if (down + up) > 0 else 0
    except:
        return 0

def is_expired(expiry):
    try:
        exp = datetime.strptime(expiry, '%Y-%m-%d')
        return exp < datetime.now()
    except:
        return False

def days_left(expiry):
    try:
        exp = datetime.strptime(expiry, '%Y-%m-%d')
        return max(0, (exp - datetime.now()).days)
    except:
        return 0

def format_date(date_str):
    try:
        d = datetime.strptime(date_str, '%Y-%m-%d')
        return d.strftime('%d/%m/%Y')
    except:
        return date_str

def validate_password(provided, stored):
    return len(provided) == len(stored) and provided == stored

def check_conn_limit(nick, limit, current_conns):
    if limit == 0:
        return True  # Ilimitado
    return current_conns < limit

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
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
        qs = parse_qs(parsed.query)
        path = parsed.path.rstrip('/')

        # Endpoint principal: /checkuserxray
        if path in ('/checkuserxray', '/checkuser', '/check'):
            if 'user' not in qs or 'pass' not in qs:
                self.send_json(400, {'error': 'user and pass required'})
                return

            nick = qs['user'][0].lower().strip()
            password = qs['pass'][0]

            users = load_users()

            if nick not in users:
                self.send_json(404, {'error': 'user_not_found'})
                return

            user = users[nick]

            # Valida senha
            if not validate_password(password, user['password']):
                self.send_json(401, {'error': 'invalid_password'})
                return

            # Verifica se vencido
            if is_expired(user['expiry']):
                self.send_json(403, {
                    'username': nick,
                    'count_connections': 0,
                    'expiration_date': format_date(user['expiry']),
                    'expiration_days': 0,
                    'limit_connections': user['conn_limit'],
                    'error': 'subscription_expired'
                })
                return

            # Conta conexões ativas
            active = get_active_connections(nick)

            # Verifica limite de conexões
            if not check_conn_limit(nick, user['conn_limit'], active):
                self.send_json(403, {
                    'username': nick,
                    'count_connections': active,
                    'expiration_date': format_date(user['expiry']),
                    'expiration_days': days_left(user['expiry']),
                    'limit_connections': user['conn_limit'],
                    'error': 'connection_limit_reached'
                })
                return

            # Sucesso!
            self.send_json(200, {
                'username': nick,
                'count_connections': active,
                'expiration_date': format_date(user['expiry']),
                'expiration_days': days_left(user['expiry']),
                'limit_connections': user['conn_limit']
            })
            return

        # Health check
        if path == '/health':
            self.send_json(200, {
                'status': 'ok',
                'service': 'TURBONET CheckUser Xray V1.0'
            })
            return

        # Status geral
        if path in ('/status', '/info'):
            users = load_users()
            active_users = sum(1 for u in users.values() if not is_expired(u['expiry']))
            self.send_json(200, {
                'total_users': len(users),
                'active_users': active_users,
                'port': PORT
            })
            return

        self.send_json(404, {
            'error': 'not_found',
            'endpoints': [
                '/checkuserxray?user=NAME&pass=PASS',
                '/health',
                '/status'
            ]
        })

HTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
PYSERVER

    local server_pid=$!
    sleep 2

    if kill -0 "$server_pid" 2>/dev/null; then
        echo "$server_pid" > "$PID_FILE"
        echo "$port" > "$PORT_FILE"
        echo -e "${TXT_GREEN}✅ CheckUser iniciado! PID: ${server_pid}${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}Endpoints:${RESET}"
        local pub_ip
        pub_ip=$(curl -4fsSL --max-time 5 https://icanhazip.com 2>/dev/null || echo "SEU_IP")
        echo -e "   ${TXT_YELLOW}GET${RESET} http://${pub_ip}:${port}/checkuserxray?user=NOME&pass=SENHA"
        echo -e "   ${TXT_YELLOW}GET${RESET} http://${pub_ip}:${port}/health"
        echo ""
        echo -e " ${TXT_YELLOW}No app VPN (Conecta4G/DTunnel):${RESET}"
        echo -e "   URL: http://${pub_ip}:${port}/checkuserxray"
        echo -e "   User: seu_usuario"
        echo -e "   Pass: sua_senha"
        echo ""
        echo -e " ${TXT_RED}⚠ Abra a porta ${port} no firewall!${RESET}"
        echo -e "   ufw allow ${port}/tcp"
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar.${RESET}"
        rm -f "$PID_FILE" "$PORT_FILE"
        return 1
    fi
}

# Para servidor
stop_server() {
    if [ ! -f "$PID_FILE" ]; then
        echo -e "${TXT_YELLOW}Servidor não está rodando.${RESET}"
        return 0
    fi

    local pid; pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        sleep 1
        echo -e "${TXT_GREEN}✅ Servidor parado.${RESET}"
    fi
    rm -f "$PID_FILE" "$PORT_FILE"
}

# Status
check_status() {
    if [ ! -f "$PID_FILE" ]; then
        echo -e " ${TXT_RED}INATIVO${RESET}"
        return
    fi

    local pid; pid=$(cat "$PID_FILE")
    local port=""; [ -f "$PORT_FILE" ] && port=$(cat "$PORT_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        echo -e " ${TXT_GREEN}ATIVO${RESET} — PID ${pid}, porta ${port}"
    else
        echo -e " ${TXT_RED}PROCESSO MORTO${RESET}"
        rm -f "$PID_FILE" "$PORT_FILE"
    fi
}

# Testar
test_server() {
    if [ ! -f "$PORT_FILE" ]; then
        echo -e "${TXT_RED}Servidor não está rodando.${RESET}"
        return
    fi

    local port; port=$(cat "$PORT_FILE")

    echo -e "${TXT_CYAN}Testando CheckUser na porta ${port}...${RESET}"
    echo ""

    echo -e "${TXT_YELLOW}[GET /health]${RESET}"
    curl -s "http://127.0.0.1:${port}/health" | python3 -m json.tool 2>/dev/null || echo "Erro"
    echo ""

    echo -e "${TXT_YELLOW}[GET /status]${RESET}"
    curl -s "http://127.0.0.1:${port}/status" | python3 -m json.tool 2>/dev/null || echo "Erro"
    echo ""

    # Testa com primeiro usuário do DB
    if [ -s "$USER_DB" ]; then
        local first_line; first_line=$(head -1 "$USER_DB")
        local test_user test_pass
        test_user=$(echo "$first_line" | cut -d'|' -f1)
        test_pass=$(echo "$first_line" | cut -d'|' -f4)

        echo -e "${TXT_YELLOW}[GET /checkuserxray?user=${test_user}&pass=***]${RESET}"
        curl -s "http://127.0.0.1:${port}/checkuserxray?user=${test_user}&pass=${test_pass}" | python3 -m json.tool 2>/dev/null || echo "Erro"
        echo ""
    fi
}

# ================================================================
# MENU
# ================================================================
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
fi

while true; do
    clear
    echo -e "${TITLE_BAR} CHECKUSER XRAY — TURBONET ${RESET}"
    echo ""
    echo -e " Status:$(check_status)"
    echo ""
    echo -e "${TXT_GREEN}[1] Iniciar (porta padrão: ${CHECKUSER_PORT})${RESET}"
    echo -e "${TXT_GREEN}[2] Iniciar em porta personalizada${RESET}"
    echo -e "${TXT_RED}[3] Parar servidor${RESET}"
    echo -e "${TXT_CYAN}[4] Testar${RESET}"
    echo -e "${TXT_CYAN}[5] Verificar firewall${RESET}"
    echo -e "${TXT_YELLOW}[6] Gerar link de configuração (para apps)${RESET}"
    echo -e "${TXT_CYAN}[0] Voltar${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "$opt" in
        1) start_server "$CHECKUSER_PORT"; read -rp "Enter..." ;;
        2)
            read -rp "Porta (1024-65535): " custom_port
            if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1024 ] && [ "$custom_port" -le 65535 ]; then
                start_server "$custom_port"
            else
                echo -e "${TXT_RED}Porta inválida.${RESET}"
            fi
            read -rp "Enter..."
        ;;
        3) stop_server; read -rp "Enter..." ;;
        4) test_server; read -rp "Enter..." ;;
        5)
            echo ""
            echo -e "${TXT_CYAN}Verificando firewall...${RESET}"
            if command -v ufw &>/dev/null; then
                echo "Regras ativas:"
                ufw status numbered 2>/dev/null | head -10
            fi
            echo ""
            echo -e "${TXT_YELLOW}Para abrir porta ${CHECKUSER_PORT}:${RESET}"
            echo "  ufw allow ${CHECKUSER_PORT}/tcp"
            read -rp "Enter..."
        ;;
        6)
            echo ""
            if [ -f "$PORT_FILE" ]; then
                local port; port=$(cat "$PORT_FILE")
                local pub_ip; pub_ip=$(curl -4fsSL --max-time 5 https://icanhazip.com 2>/dev/null || echo "SEU_IP")
                echo -e "${TXT_CYAN}Link para configurar no app:${RESET}"
                echo ""
                echo -e "   ${TXT_YELLOW}http://${pub_ip}:${port}/checkuserxray${RESET}"
                echo ""
                echo "No Conecta4G/DTunnel:"
                echo "  URL: http://${pub_ip}:${port}/checkuserxray"
            else
                echo -e "${TXT_RED}Inicie o servidor primeiro!${RESET}"
            fi
            read -rp "Enter..."
        ;;
        0) exit 0 ;;
        *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
