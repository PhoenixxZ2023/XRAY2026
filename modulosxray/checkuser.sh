#!/bin/bash
# checkuser.sh - TURBONET XRAY V1.2 (HIBRIDO)
# Servidor CheckUser compativel com apps VPN (Conecta4G, DTunnel, HTTP Custom, etc.)
#
# Endpoint: http://IP:PORTA/checkuserxray?user=NOME&pass=SENHA
# Resposta: {"username":"joao","count_connections":1,"expiration_date":"01/06/2026",
#            "expiration_days":30,"limit_connections":2}
#
# Tambem suporta:
#   /checkuserxray          -> autenticacao por usuario+senha
#   /check?user=NOME       -> consulta publica (sem senha, só status)
#   /health                 -> healthcheck
#
# Correções Aplicadas:
# - Compatibilidade estendida do Python (subprocess.run com stdout=PIPE em vez de capture_output)
# - Hardening de arquivos (logs e pids gerados como 600)
# - Força o uso do IP da VPS na geração dos links, ignorando domínios
#
set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
ACTIVE_DOMAIN_FILE="/opt/XrayTools/active_domain"
XRAY_BIN="/usr/local/bin/xray"
PID_FILE="/tmp/turbonet_checkuser.pid"
PORT_FILE="/tmp/turbonet_checkuser.port"
LOG_FILE="/tmp/turbonet_checkuser.log"
CONN_DB="/tmp/turbonet_connections.json"
DEFAULT_PORT=6000

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

[ "${EUID:-$(id -u)}" -ne 0 ] && { echo -e "${TXT_RED}Execute como root!${RESET}"; exit 1; }

# --- STATUS ---
_is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

_get_port() {
    [ -f "$PORT_FILE" ] && cat "$PORT_FILE" || echo "$DEFAULT_PORT"
}

_get_api_port() {
    [ -s "$CONFIG_PATH" ] || { echo "1080"; return; }
    jq -r '.inbounds[]? | select(.tag=="api") | .port // empty' \
        "$CONFIG_PATH" 2>/dev/null | head -1 || echo "1080"
}

# --- DETECCAO APENAS DE IP DA VPS ---
_get_server_addr() {
    local addr=""
    
    # Consulta diretamente o IP público da VPS, ignorando domínios
    addr=$(curl -4fsSL --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || \
           curl -4fsSL --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || echo "")
    
    if [ -z "$addr" ]; then
        addr="SEU_IP"
    fi
    
    echo "$addr"
}

# --- SERVIDOR PYTHON (THREAD-SAFE) ---
_start_server() {
    local port="${1:-$DEFAULT_PORT}"

    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${TXT_RED}Porta ${port} em uso.${RESET}"; return 1
    fi

    if _is_running; then
        echo -e "${TXT_RED}Ja existe um servidor rodando.${RESET}"; return 1
    fi

    local api_port; api_port=$(_get_api_port)
    local server_addr; server_addr=$(_get_server_addr)

    # Hardening: Garante que os logs comecem com permissão restrita.
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"

    python3 - "$port" "$USER_DB" "$CONFIG_PATH" "$XRAY_BIN" \
              "$api_port" "$CONN_DB" "$LOG_FILE" << 'PYSERVER' &
import sys, json, os, subprocess, time, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime

PORT      = int(sys.argv[1])
USER_DB   = sys.argv[2]
CFG_PATH  = sys.argv[3]
XRAY_BIN  = sys.argv[4]
API_PORT  = sys.argv[5]
CONN_DB   = sys.argv[6]
LOG_FILE  = sys.argv[7]

# Lock para acesso thread-safe ao CONN_DB
conn_lock = threading.Lock()

def log(msg):
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(f"[{ts}] {msg}\n")
    except: pass

def load_users():
    """Carrega users.db - formato: nick|uuid|expiry|password|limit"""
    users = {}
    if not os.path.exists(USER_DB):
        return users
    with open(USER_DB) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('|')
            if len(parts) >= 3:
                nick     = parts[0].lower().strip()
                uuid     = parts[1].strip() if len(parts) > 1 else ''
                expiry   = parts[2].strip() if len(parts) > 2 else ''
                password = parts[3].strip() if len(parts) > 3 else ''
                limit    = int(parts[4]) if len(parts) > 4 and parts[4].strip().isdigit() else 0
                users[nick] = {
                    'uuid':     uuid,
                    'expiry':   expiry,
                    'password': password,
                    'limit':    limit
                }
    return users

def load_cfg():
    try:
        with open(CFG_PATH) as f:
            return json.load(f)
    except Exception:
        return {}

def is_locked(nick, cfg):
    for inb in cfg.get('inbounds', []):
        if inb.get('tag') == 'inbound-turbonet':
            for c in inb.get('settings', {}).get('clients', []):
                if c.get('email') == f'LOCKED_{nick}':
                    return True
    return False

def days_left(expiry):
    try:
        exp = datetime.strptime(expiry, '%Y-%m-%d')
        return max(0, (exp - datetime.now()).days)
    except Exception:
        return 0

def expiry_formatted(expiry):
    """Converte YYYY-MM-DD para DD/MM/YYYY"""
    try:
        d = datetime.strptime(expiry, '%Y-%m-%d')
        return d.strftime('%d/%m/%Y')
    except Exception:
        return expiry

def get_active_connections(nick):
    """Consulta conexoes ativas via API do Xray"""
    try:
        down = 0
        up = 0
        
        down_result = subprocess.run(
            [XRAY_BIN, 'api', 'stats',
             f'-server=127.0.0.1:{API_PORT}',
             f'-name=user>>>{nick}>>>traffic>>>downlink'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3
        )
        
        for line in down_result.stdout.decode().split('\n'):
            parts = line.split()
            for i, p in enumerate(parts):
                if p == 'value' and i + 1 < len(parts):
                    down = int(parts[i + 1])
                    break
        
        up_result = subprocess.run(
            [XRAY_BIN, 'api', 'stats',
             f'-server=127.0.0.1:{API_PORT}',
             f'-name=user>>>{nick}>>>traffic>>>uplink'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3
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

def load_conn_tracking():
    with conn_lock:
        try:
            if os.path.exists(CONN_DB):
                with open(CONN_DB) as f:
                    return json.load(f)
        except Exception: pass
        return {}

def save_conn_tracking(data):
    with conn_lock:
        try:
            with open(CONN_DB, 'w') as f:
                json.dump(data, f)
        except Exception: pass

def check_and_enforce_limit(nick, limit, current_conns):
    """Verifica limite de conexoes"""
    if limit == 0:  # ilimitado
        return True
    return current_conns < limit

class CheckUserHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log(f"{self.address_string()} - {fmt % args}")

    def _send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        qs     = parse_qs(parsed.query)
        path   = parsed.path.rstrip('/')

        # Health check
        if path == '/health':
            self._send_json(200, {
                'status':  'ok',
                'service': 'TURBONET XRAY CheckUser V1.2'
            })
            return

        # Status endpoint
        if path == '/status':
            users = load_users()
            self._send_json(200, {
                'status': 'running',
                'users_count': len(users)
            })
            return

        # CheckUser principal - compativel com apps VPN
        if path in ('/checkuserxray', '/checkuser'):
            user = qs.get('user', [None])[0]
            pwd  = qs.get('pass', qs.get('password', [None]))[0]

            if not user:
                self._send_json(400, {'error': 'user parameter required'})
                return

            users = load_users()
            user  = user.lower().strip()

            if user not in users:
                self._send_json(200, {
                    'username':           user,
                    'count_connections':  0,
                    'expiration_date':    '',
                    'expiration_days':    0,
                    'limit_connections':  0,
                    'status':             'invalid'
                })
                return

            u = users[user]

            # Valida senha se fornecida e cadastrada
            if u['password'] and pwd is not None:
                if pwd != u['password']:
                    self._send_json(200, {
                        'username':          user,
                        'count_connections': 0,
                        'expiration_date':   '',
                        'expiration_days':   0,
                        'limit_connections': 0,
                        'status':            'invalid'
                    })
                    log(f"AUTH FAIL: user={user} wrong password")
                    return

            cfg    = load_cfg()
            locked = is_locked(user, cfg)
            dl     = days_left(u['expiry'])
            conns  = get_active_connections(user)

            log(f"CHECK: user={user} conns={conns} limit={u['limit']} days={dl} locked={locked}")

            self._send_json(200, {
                'username':          user,
                'uuid':              u['uuid'],
                'count_connections': conns,
                'expiration_date':   expiry_formatted(u['expiry']),
                'expiration_days':   dl,
                'limit_connections': u['limit'],
                'valid':             True,
                'status': 'locked'   if locked  else
                          'expired'  if dl <= 0  else
                          'active'
            })
            return

        # Consulta publica /check (sem senha)
        if path == '/check':
            user = qs.get('user', [None])[0]
            if not user:
                self._send_json(400, {'error': 'user parameter required'})
                return
            users = load_users()
            user  = user.lower().strip()
            if user not in users:
                self._send_json(404, {'error': 'user not found'})
                return
            u      = users[user]
            cfg    = load_cfg()
            locked = is_locked(user, cfg)
            dl     = days_left(u['expiry'])
            conns  = get_active_connections(user)
            self._send_json(200, {
                'username':          user,
                'count_connections': conns,
                'expiration_date':   expiry_formatted(u['expiry']),
                'expiration_days':   dl,
                'limit_connections': u['limit'],
                'status': 'locked'  if locked else
                          'expired' if dl <= 0 else 'active'
            })
            return

        self._send_json(404, {
            'error':     'endpoint not found',
            'endpoints': [
                '/checkuserxray?user=NOME&pass=SENHA',
                '/check?user=NOME',
                '/health',
                '/status'
            ]
        })

try:
    server = HTTPServer(('0.0.0.0', PORT), CheckUserHandler)
    log(f"TURBONET XRAY CheckUser V1.2 iniciado na porta {PORT}")
    print(f'Server started on port {PORT}')
    server.serve_forever()
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
PYSERVER

    local server_pid=$!
    sleep 1

    if kill -0 "$server_pid" 2>/dev/null; then
        echo "$server_pid" > "$PID_FILE"
        echo "$port"       > "$PORT_FILE"
        # Hardening
        chmod 0600 "$PID_FILE" "$PORT_FILE"

        echo -e "${TXT_GREEN}CheckUser iniciado! PID: ${server_pid}${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}URL para apps VPN:${RESET}"
        echo -e "  ${TXT_YELLOW}http://${server_addr}:${port}/checkuserxray${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}Exemplo de uso no app:${RESET}"
        echo -e "  Host CheckUser: ${TXT_YELLOW}http://${server_addr}:${port}${RESET}"
        echo -e "  Endpoint:       ${TXT_YELLOW}/checkuserxray${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}Teste rapido:${RESET}"
        echo -e "  curl \"http://127.0.0.1:${port}/checkuserxray?user=NOME&pass=SENHA\""
        echo ""
        echo -e " ${TXT_RED}Abrir porta no firewall:${RESET}"
        echo -e "  ufw allow ${port}/tcp"
    else
        echo -e "${TXT_RED}Falha ao iniciar o CheckUser.${RESET}"
        rm -f "$PID_FILE" "$PORT_FILE"
        return 1
    fi
}

_stop_server() {
    if ! _is_running; then
        echo -e "${TXT_YELLOW}CheckUser nao esta rodando.${RESET}"; return
    fi
    local pid; pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    sleep 1
    rm -f "$PID_FILE" "$PORT_FILE"
    echo -e "${TXT_GREEN}CheckUser parado.${RESET}"
}

_status() {
    if _is_running; then
        local port; port=$(_get_port)
        local pid; pid=$(cat "$PID_FILE")
        local addr; addr=$(_get_server_addr)
        echo -e " ${TXT_GREEN}ATIVO${RESET} - PID ${pid}, porta ${port}"
        echo -e "  URL: ${TXT_YELLOW}http://${addr}:${port}/checkuserxray${RESET}"
    else
        echo -e " ${TXT_RED}INATIVO${RESET}"
    fi
}

_test() {
    if ! _is_running; then
        echo -e "${TXT_RED}CheckUser nao esta rodando.${RESET}"; return
    fi
    local port; port=$(_get_port)

    echo -e "${TXT_CYAN}[GET /health]${RESET}"
    curl -s "http://127.0.0.1:${port}/health" | python3 -m json.tool 2>/dev/null || \
        curl -s "http://127.0.0.1:${port}/health"
    echo ""

    if [ -s "$USER_DB" ]; then
        local first; first=$(head -1 "$USER_DB")
        local nick; nick=$(echo "$first" | cut -d'|' -f1 | tr '[:upper:]' '[:lower:]')
        local pass; pass=$(echo "$first" | cut -d'|' -f4)
        echo -e "${TXT_CYAN}[GET /checkuserxray?user=${nick}&pass=***]${RESET}"
        curl -s "http://127.0.0.1:${port}/checkuserxray?user=${nick}&pass=${pass}" | \
            python3 -m json.tool 2>/dev/null || \
            curl -s "http://127.0.0.1:${port}/checkuserxray?user=${nick}&pass=${pass}"
        echo ""
    fi
}

_show_config_link() {
    local port; port=$(_get_port)
    local addr; addr=$(_get_server_addr)
    
    echo ""
    echo -e "${TXT_CYAN}========================================${RESET}"
    echo -e "${TXT_YELLOW}LINK DE CONFIGURACAO PARA APPS${RESET}"
    echo -e "${TXT_CYAN}========================================${RESET}"
    echo ""
    echo -e "URL da API: ${TXT_GREEN}http://${addr}:${port}/checkuserxray${RESET}"
    echo ""
    echo -e "${TXT_YELLOW}Parametros:${RESET}"
    echo "  user = nome do usuario"
    echo "  pass = senha do usuario"
    echo ""
    echo -e "${TXT_YELLOW}Exemplo:${RESET}"
    echo "  http://${addr}:${port}/checkuserxray?user=joao&pass=senha123"
    echo ""
    echo -e "${TXT_CYAN}========================================${RESET}"
}

_view_logs() {
    [ -f "$LOG_FILE" ] && tail -40 "$LOG_FILE" || echo "Sem logs."
}

_setup_autostart() {
    local port="${1:-$DEFAULT_PORT}"
    cat > /etc/systemd/system/turbonet-checkuser.service << EOF
[Unit]
Description=TURBONET XRAY CheckUser Service
After=network.target xray.service

[Service]
Type=forking
ExecStart=/usr/local/bin/checkuser.sh --start ${port}
ExecStop=/usr/local/bin/checkuser.sh --stop
PIDFile=${PID_FILE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable turbonet-checkuser >/dev/null 2>&1
    echo -e "${TXT_GREEN}CheckUser configurado para iniciar automaticamente.${RESET}"
}

_view_users() {
    clear
    echo -e "${TITLE_BAR}   USUARIOS E SENHAS   ${RESET}"
    echo ""
    if [ ! -f "$USER_DB" ]; then
        echo -e "${TXT_RED}Arquivo users.db nao encontrado${RESET}"
        return
    fi
    printf "%-12s | %-10s | %-12s | %-7s\n" "NOME" "SENHA" "EXPIRA" "LIMITE"
    echo "---------------------------------------------------"
    while IFS='|' read -r nick uuid expiry pass limit _rest; do
        [ -n "${nick:-}" ] || continue
        limit_show="${limit:-0}"
        [ "$limit_show" = "0" ] && limit_show="ilimitado"
        printf "%-12s | %-10s | %-12s | %-7s\n" \
            "$nick" "${pass:-sem senha}" "$expiry" "$limit_show"
    done < "$USER_DB"
    echo ""
}

_check_firewall() {
    local port; port=$(_get_port)
    
    echo -e "${TXT_CYAN}Verificando firewall...${RESET}"
    
    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "${port}/tcp"; then
            echo -e "${TXT_GREEN}Porta ${port} liberada no UFW${RESET}"
        else
            echo -e "${TXT_YELLOW}Porta ${port} pode nao estar liberada${RESET}"
            echo "Execute: ufw allow ${port}/tcp"
        fi
    fi
    
    if command -v iptables &>/dev/null; then
        if iptables -L -n 2>/dev/null | grep -q "${port}"; then
            echo -e "${TXT_GREEN}Porta ${port} encontrada no iptables${RESET}"
        fi
    fi
}

# Modo nao-interativo (para systemd)
if [ "${1:-}" = "--start" ]; then
    _start_server "${2:-$DEFAULT_PORT}"
    exit 0
elif [ "${1:-}" = "--stop" ]; then
    _stop_server
    exit 0
fi

# --- MENU INTERATIVO ---
while true; do
    clear
    echo -e "${TITLE_BAR}   CHECKUSER - TURBONET XRAY V1.2   ${RESET}"
    echo ""
    echo -e " Status:$(_status)"
    echo ""
    echo "-----------------------------------------"
    echo -e "${TXT_CYAN}[1]${RESET} Iniciar CheckUser (porta padrao: 6000)"
    echo -e "${TXT_CYAN}[2]${RESET} Iniciar em porta personalizada"
    echo -e "${TXT_RED}[3]${RESET} Parar CheckUser"
    echo -e "${TXT_CYAN}[4]${RESET} Testar (curl local)"
    echo -e "${TXT_CYAN}[5]${RESET} Ver logs"
    echo -e "${TXT_CYAN}[6]${RESET} Ver link de configuracao (para apps)"
    echo -e "${TXT_CYAN}[7]${RESET} Verificar firewall"
    echo -e "${TXT_CYAN}[8]${RESET} Configurar inicio automatico (systemd)"
    echo -e "${TXT_CYAN}[9]${RESET} Ver usuarios e senhas"
    echo -e "${TXT_CYAN}[0]${RESET} Voltar"
    echo "-----------------------------------------"
    read -rp "Opcao: " opt

    case "${opt:-0}" in
        1) _start_server "$DEFAULT_PORT"; read -rp "Enter..." ;;
        2)
            read -rp "Porta (1024-65535): " p
            [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] && \
                _start_server "$p" || echo -e "${TXT_RED}Porta invalida.${RESET}"
            read -rp "Enter..."
            ;;
        3) _stop_server; read -rp "Enter..." ;;
        4) _test; read -rp "Enter..." ;;
        5) _view_logs; read -rp "Enter..." ;;
        6) _show_config_link; read -rp "Enter..." ;;
        7) _check_firewall; read -rp "Enter..." ;;
        8)
            read -rp "Porta para autostart [${DEFAULT_PORT}]: " ap
            [ -z "${ap:-}" ] && ap="$DEFAULT_PORT"
            _setup_autostart "$ap"
            read -rp "Enter..."
            ;;
        9) _view_users; read -rp "Enter..." ;;
        0) exit 0 ;;
        *) echo -e "${TXT_RED}Invalido.${RESET}"; sleep 1 ;;
    esac
done
