#!/bin/bash
# checkuser.sh - TURBONET XRAY V1.4 (Híbrido Xray + SSH/SOCKS5 + Multi-Thread)
# Endpoint: http://IP:PORTA/checkuserxray?user=NOME&pass=SENHA
#
# Atualizações V1.4:
#   - Parsing JSON via `xray api statsquery` + medição de delta de tráfego (janela 20s) e sessões SSH/SOCKS5
#   - Cache thread-safe de 3s para evitar gargalo de subprocessos em consultas simultâneas de apps VPN
#   - ThreadingHTTPServer com reuse_address e daemon_threads
#   - Exigência de senha em `/checkuserxray` com `hmac.compare_digest` (mantendo `/check?user=NOME` público sem UUID)
#   - Cálculo de vencimento alinhado ao dia inteiro (`exp_date < today`) e suporte a systemd com caminho dinâmico

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
PID_FILE="/tmp/turbonet_checkuser.pid"
PORT_FILE="/tmp/turbonet_checkuser.port"
LOG_FILE="/tmp/turbonet_checkuser.log"
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
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

_get_port() {
    [ -f "$PORT_FILE" ] && cat "$PORT_FILE" || echo "$DEFAULT_PORT"
}

_get_api_port() {
    if [ -s "$CONFIG_PATH" ] && command -v jq &>/dev/null; then
        local detected
        detected=$(jq -r '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door") | .port // empty' \
            "$CONFIG_PATH" 2>/dev/null | head -1 || true)
        if [[ "${detected:-}" =~ ^[0-9]+$ ]]; then
            echo "$detected"
            return 0
        fi
    fi
    echo "1080"
}

# --- DETECÇÃO DE IP PÚBLICO DA VPS ---
_get_server_addr() {
    local addr=""
    if command -v curl &>/dev/null; then
        addr=$(curl -4fsSL --max-time 5 --connect-timeout 3 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || \
               curl -4fsSL --max-time 5 --connect-timeout 3 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || echo "")
    fi
    [ -n "$addr" ] && echo "$addr" || echo "SEU_IP"
}

# --- SERVIDOR PYTHON (MULTI-THREAD + CACHE) ---
_start_server() {
    local port="${1:-$DEFAULT_PORT}"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${TXT_RED}Porta inválida: ${port}${RESET}"; return 1
    fi

    if _is_running; then
        echo -e "${TXT_RED}Já existe um servidor CheckUser rodando (PID $(cat "$PID_FILE")).${RESET}"; return 1
    fi

    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${TXT_RED}Porta ${port} já está em uso por outro processo.${RESET}"; return 1
    fi

    local api_port; api_port=$(_get_api_port)
    local server_addr; server_addr=$(_get_server_addr)

    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"

    python3 - "$port" "$USER_DB" "$CONFIG_PATH" "$XRAY_BIN" \
              "$api_port" "$LOG_FILE" </dev/null >>"$LOG_FILE" 2>&1 << 'PYSERVER' &
import sys, json, os, subprocess, time, threading, re, hmac
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime

PORT     = int(sys.argv[1])
USER_DB  = sys.argv[2]
CFG_PATH = sys.argv[3]
XRAY_BIN = sys.argv[4]
API_PORT = sys.argv[5]
LOG_FILE = sys.argv[6]

ACTIVE_WINDOW_SEC = 20
CACHE_TTL_SEC     = 3.0

state_lock = threading.Lock()
stats_cache = {
    'last_poll': 0.0,
    'xray_bytes': {},     # nick -> int(down + up)
    'xray_last_seen': {}, # nick -> float(timestamp)
    'ssh_counts': {},     # nick -> int(active ssh/socks processes)
}

def log(msg):
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(f"[{ts}] {msg}\n")
    except Exception:
        pass

def is_safe_input(val):
    return bool(val) and bool(re.match(r'^[a-zA-Z0-9_-]{1,32}$', val))

def load_users():
    """Carrega users.db - formato: nick|uuid|expiry|password|limit"""
    users = {}
    if not os.path.exists(USER_DB):
        return users
    try:
        with open(USER_DB, encoding='utf-8', errors='ignore') as f:
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
                    if nick:
                        users[nick] = {
                            'uuid':     uuid,
                            'expiry':   expiry,
                            'password': password,
                            'limit':    limit
                        }
    except Exception as e:
        log(f"ERROR load_users: {e}")
    return users

def load_cfg():
    try:
        with open(CFG_PATH, encoding='utf-8') as f:
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

def check_expiry(expiry):
    """Retorna (days_remaining, is_expired) considerando o dia inteiro do vencimento."""
    try:
        exp_date = datetime.strptime(expiry, '%Y-%m-%d').date()
        today = datetime.now().date()
        if exp_date < today:
            return 0, True
        return (exp_date - today).days, False
    except Exception:
        return 0, True

def expiry_formatted(expiry):
    try:
        d = datetime.strptime(expiry, '%Y-%m-%d')
        return d.strftime('%d/%m/%Y')
    except Exception:
        return expiry

def _refresh_connections_cache():
    now = time.time()
    with state_lock:
        if (now - stats_cache['last_poll']) < CACHE_TTL_SEC:
            return

    # 1. Consulta única à API do Xray via statsquery (JSON)
    current_totals = {}
    if os.path.isfile(XRAY_BIN) and os.access(XRAY_BIN, os.X_OK):
        try:
            res = subprocess.run(
                [XRAY_BIN, 'api', 'statsquery',
                 f'-server=127.0.0.1:{API_PORT}',
                 '-pattern=user>>>'],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3
            )
            if res.returncode == 0 and res.stdout:
                payload = json.loads(res.stdout.decode('utf-8', errors='ignore') or '{}')
                for item in payload.get('stat', []):
                    name = item.get('name', '')
                    m = re.match(r'^user>>>([^>]+)>>>traffic>>>(downlink|uplink)$', name)
                    if m:
                        u = m.group(1).lower()
                        raw_val = re.sub(r'[^0-9]', '', str(item.get('value', 0)))
                        val = int(raw_val) if raw_val else 0
                        current_totals[u] = current_totals.get(u, 0) + val
        except Exception:
            pass

    # 2. Consulta leve de sessões locais SSH / Dropbear / SOCKS5
    ssh_counts = {}
    try:
        ps_res = subprocess.run(
            ['ps', '-eo', 'user='],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2
        )
        if ps_res.returncode == 0:
            for line in ps_res.stdout.decode('utf-8', errors='ignore').splitlines():
                u = line.strip().lower()
                if u and u not in ('root', 'nobody', 'botxray', 'www-data', 'systemd-network', 'systemd-resolve', 'messagebus'):
                    ssh_counts[u] = ssh_counts.get(u, 0) + 1
    except Exception:
        pass

    with state_lock:
        prev_bytes = stats_cache['xray_bytes']
        last_seen  = stats_cache['xray_last_seen']

        for u, total in current_totals.items():
            if u not in prev_bytes:
                # Baseline inicial sem falso positivo
                prev_bytes[u] = total
            else:
                if total != prev_bytes[u] and total > 0:
                    last_seen[u] = now
                prev_bytes[u] = total

        stats_cache['ssh_counts'] = ssh_counts
        stats_cache['last_poll']  = now

def get_active_connections(nick):
    if not is_safe_input(nick):
        return 0
    _refresh_connections_cache()
    now = time.time()
    with state_lock:
        seen_ts   = stats_cache['xray_last_seen'].get(nick, 0.0)
        xray_conn = 1 if (seen_ts > 0.0 and (now - seen_ts) <= ACTIVE_WINDOW_SEC) else 0
        ssh_conn  = stats_cache['ssh_counts'].get(nick, 0)
    return xray_conn + ssh_conn

class ThreadedCheckUserServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

class CheckUserHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log(f"{self.address_string()} - {fmt % args}")

    def _send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        try:
            parsed = urlparse(self.path)
            qs     = parse_qs(parsed.query)
            path   = parsed.path.rstrip('/')

            if path == '/health':
                self._send_json(200, {
                    'status':  'ok',
                    'service': 'TURBONET XRAY CheckUser V1.4'
                })
                return

            if path == '/status':
                users = load_users()
                self._send_json(200, {
                    'status': 'running',
                    'users_count': len(users)
                })
                return

            # CheckUser principal - compatível com apps VPN (Conecta4G, DTunnel, HTTP Custom, etc.)
            if path in ('/checkuserxray', '/checkuser'):
                raw_user = qs.get('user', [None])[0]
                pwd      = qs.get('pass', qs.get('password', [None]))[0]

                if not raw_user:
                    self._send_json(400, {'error': 'user parameter required'})
                    return

                user  = raw_user.lower().strip()
                users = load_users()

                if not is_safe_input(user) or user not in users:
                    self._send_json(200, {
                        'username':          user,
                        'count_connections': 0,
                        'expiration_date':   '',
                        'expiration_days':   0,
                        'limit_connections': 0,
                        'valid':             False,
                        'status':            'invalid'
                    })
                    return

                u = users[user]

                # Exige senha sempre que houver senha cadastrada no users.db
                if u['password']:
                    if not pwd or not hmac.compare_digest(str(pwd), str(u['password'])):
                        self._send_json(200, {
                            'username':          user,
                            'count_connections': 0,
                            'expiration_date':   '',
                            'expiration_days':   0,
                            'limit_connections': 0,
                            'valid':             False,
                            'status':            'invalid'
                        })
                        log(f"AUTH FAIL: user={user}")
                        return

                cfg        = load_cfg()
                locked     = is_locked(user, cfg)
                dl, is_exp = check_expiry(u['expiry'])
                conns      = get_active_connections(user)

                status_str = 'locked' if locked else ('expired' if is_exp else 'active')
                is_valid   = (status_str == 'active')

                log(f"CHECK: user={user} conns={conns} limit={u['limit']} days={dl} status={status_str}")

                self._send_json(200, {
                    'username':          user,
                    'uuid':              u['uuid'],
                    'count_connections': conns,
                    'expiration_date':   expiry_formatted(u['expiry']),
                    'expiration_days':   dl,
                    'limit_connections': u['limit'],
                    'valid':             is_valid,
                    'status':            status_str
                })
                return

            # Consulta pública /check (sem senha, não expõe UUID)
            if path == '/check':
                raw_user = qs.get('user', [None])[0]
                if not raw_user:
                    self._send_json(400, {'error': 'user parameter required'})
                    return
                user = raw_user.lower().strip()
                if not is_safe_input(user):
                    self._send_json(400, {'error': 'invalid user parameter'})
                    return
                users = load_users()
                if user not in users:
                    self._send_json(404, {'error': 'user not found'})
                    return
                u          = users[user]
                cfg        = load_cfg()
                locked     = is_locked(user, cfg)
                dl, is_exp = check_expiry(u['expiry'])
                conns      = get_active_connections(user)
                status_str = 'locked' if locked else ('expired' if is_exp else 'active')

                self._send_json(200, {
                    'username':          user,
                    'count_connections': conns,
                    'expiration_date':   expiry_formatted(u['expiry']),
                    'expiration_days':   dl,
                    'limit_connections': u['limit'],
                    'status':            status_str
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
        except Exception:
            self._send_json(500, {'error': 'internal_server_error'})

try:
    server = ThreadedCheckUserServer(('0.0.0.0', PORT), CheckUserHandler)
    log(f"TURBONET XRAY CheckUser V1.4 iniciado na porta {PORT} (API Xray: {API_PORT})")
    server.serve_forever()
except Exception as e:
    log(f"FATAL: {e}")
    sys.exit(1)
PYSERVER

    local server_pid=$!
    sleep 1

    if kill -0 "$server_pid" 2>/dev/null; then
        echo "$server_pid" > "$PID_FILE"
        echo "$port"       > "$PORT_FILE"
        chmod 0600 "$PID_FILE" "$PORT_FILE"

        echo -e "${TXT_GREEN}✅ CheckUser V1.4 iniciado! PID: ${server_pid}${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}URL para apps VPN:${RESET}"
        echo -e "  ${TXT_YELLOW}http://${server_addr}:${port}/checkuserxray${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}Exemplo de uso no app:${RESET}"
        echo -e "  Host CheckUser: ${TXT_YELLOW}http://${server_addr}:${port}${RESET}"
        echo -e "  Endpoint:       ${TXT_YELLOW}/checkuserxray${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}Teste rápido:${RESET}"
        echo -e "  curl \"http://127.0.0.1:${port}/checkuserxray?user=NOME&pass=SENHA\""
        echo ""
        echo -e " ${TXT_RED}Abrir porta no firewall:${RESET}"
        echo -e "  ufw allow ${port}/tcp"
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar o CheckUser. Verifique ${LOG_FILE}.${RESET}"
        rm -f "$PID_FILE" "$PORT_FILE"
        return 1
    fi
}

_stop_server() {
    if ! _is_running; then
        rm -f "$PID_FILE" "$PORT_FILE"
        echo -e "${TXT_YELLOW}CheckUser não está rodando.${RESET}"; return
    fi
    local pid; pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE" "$PORT_FILE"
    echo -e "${TXT_GREEN}✅ CheckUser parado.${RESET}"
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
        echo -e "${TXT_RED}CheckUser não está rodando.${RESET}"; return
    fi
    local port; port=$(_get_port)

    echo -e "${TXT_CYAN}[GET /health]${RESET}"
    curl -fsS --max-time 5 "http://127.0.0.1:${port}/health" | python3 -m json.tool 2>/dev/null || \
        curl -fsS --max-time 5 "http://127.0.0.1:${port}/health" || echo "Falha no /health"
    echo ""

    if [ -s "$USER_DB" ]; then
        local first; first=$(head -1 "$USER_DB")
        local nick; nick=$(echo "$first" | cut -d'|' -f1 | tr '[:upper:]' '[:lower:]')
        local pass; pass=$(echo "$first" | cut -d'|' -f4)
        echo -e "${TXT_CYAN}[GET /checkuserxray?user=${nick}&pass=***]${RESET}"
        curl -fsS --max-time 5 "http://127.0.0.1:${port}/checkuserxray?user=${nick}&pass=${pass}" | \
            python3 -m json.tool 2>/dev/null || \
            curl -fsS --max-time 5 "http://127.0.0.1:${port}/checkuserxray?user=${nick}&pass=${pass}" || echo "Falha no teste"
        echo ""
    fi
}

_show_config_link() {
    local port; port=$(_get_port)
    local addr; addr=$(_get_server_addr)

    echo ""
    echo -e "${TXT_CYAN}========================================${RESET}"
    echo -e "${TXT_YELLOW}LINK DE CONFIGURAÇÃO PARA APPS${RESET}"
    echo -e "${TXT_CYAN}========================================${RESET}"
    echo ""
    echo -e "URL da API: ${TXT_GREEN}http://${addr}:${port}/checkuserxray${RESET}"
    echo ""
    echo -e "${TXT_YELLOW}Parâmetros:${RESET}"
    echo "  user = nome do usuário"
    echo "  pass = senha do usuário"
    echo ""
    echo -e "${TXT_YELLOW}Exemplo:${RESET}"
    echo "  http://${addr}:${port}/checkuserxray?user=joao&pass=senha123"
    echo ""
    echo -e "${TXT_CYAN}========================================${RESET}"
}

_view_logs() {
    if [ -s "$LOG_FILE" ]; then
        tail -40 "$LOG_FILE"
    else
        echo "Sem logs registrados."
    fi
}

_setup_autostart() {
    local port="${1:-$DEFAULT_PORT}"
    local script_path
    script_path="$(readlink -f "$0")"
    chmod +x "$script_path" 2>/dev/null || true

    cat > /etc/systemd/system/turbonet-checkuser.service << EOF
[Unit]
Description=TURBONET XRAY CheckUser Service
After=network.target xray.service

[Service]
Type=forking
ExecStart=${script_path} --start ${port}
ExecStop=${script_path} --stop
PIDFile=${PID_FILE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable turbonet-checkuser >/dev/null 2>&1
    echo -e "${TXT_GREEN}✅ CheckUser configurado para iniciar automaticamente na porta ${port}.${RESET}"
}

_view_users() {
    clear
    echo -e "${TITLE_BAR}   USUÁRIOS E SENHAS   ${RESET}"
    echo ""
    if [ ! -f "$USER_DB" ]; then
        echo -e "${TXT_RED}Arquivo users.db não encontrado.${RESET}"
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

    echo -e "${TXT_CYAN}Verificando firewall para porta ${port}/tcp...${RESET}"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status 2>/dev/null | grep -q "${port}/tcp"; then
            echo -e "${TXT_GREEN}✅ Porta ${port}/tcp liberada no UFW${RESET}"
        else
            echo -e "${TXT_YELLOW}⚠ Porta ${port}/tcp não encontrada no UFW${RESET}"
            echo "Execute: ufw allow ${port}/tcp"
        fi
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        if firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/tcp"; then
            echo -e "${TXT_GREEN}✅ Porta ${port}/tcp liberada no firewalld${RESET}"
        else
            echo -e "${TXT_YELLOW}⚠ Porta ${port}/tcp não encontrada no firewalld${RESET}"
            echo "Execute: firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload"
        fi
    elif command -v iptables &>/dev/null; then
        if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:${port}"; then
            echo -e "${TXT_GREEN}✅ Porta ${port}/tcp encontrada no iptables${RESET}"
        else
            echo -e "${TXT_YELLOW}⚠ Regra explícita para ${port}/tcp não encontrada no iptables${RESET}"
        fi
    fi
}

# Modo não-interativo (para systemd)
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
    echo -e "${TITLE_BAR}   CHECKUSER - TURBONET XRAY V1.4   ${RESET}"
    echo ""
    echo -e " Status:$(_status)"
    echo ""
    echo "-----------------------------------------"
    echo -e "${TXT_CYAN}[1]${RESET} Iniciar CheckUser (porta padrão: 6000)"
    echo -e "${TXT_CYAN}[2]${RESET} Iniciar em porta personalizada"
    echo -e "${TXT_RED}[3]${RESET} Parar CheckUser"
    echo -e "${TXT_CYAN}[4]${RESET} Testar (curl local)"
    echo -e "${TXT_CYAN}[5]${RESET} Ver logs"
    echo -e "${TXT_CYAN}[6]${RESET} Ver link de configuração (para apps)"
    echo -e "${TXT_CYAN}[7]${RESET} Verificar firewall"
    echo -e "${TXT_CYAN}[8]${RESET} Configurar início automático (systemd)"
    echo -e "${TXT_CYAN}[9]${RESET} Ver usuários e senhas"
    echo -e "${TXT_CYAN}[0]${RESET} Voltar"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "${opt:-0}" in
        1) _start_server "$DEFAULT_PORT"; read -rp "Enter..." ;;
        2)
            read -rp "Porta (1024-65535): " p
            [[ "${p:-}" =~ ^[0-9]+$ ]] && [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] && \
                _start_server "$p" || echo -e "${TXT_RED}Porta inválida.${RESET}"
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
        *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
