#!/bin/bash
# check_api.sh - TURBONET XRAY V1.3
# Correções aplicadas V1.3:
# - Daemon iniciado com nohup + redirecionamento para $API_LOG (sobrevive ao logout SSH)
# - ThreadingHTTPServer com allow_reuse_address = True (evita erro TIME_WAIT ao reiniciar)
# - Correção em days_left() comparando .date() (não marca usuário como expirado no dia do vencimento)
# - Rate limiting thread-safe em memória com limpeza automática e proteção contra spoof de X-Forwarded-For
# - Comparação de API Key via hmac.compare_digest() e restart automático ao regenerar chave

set -Eeuo pipefail

trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
API_KEY_FILE="/opt/XrayTools/.api_key"
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

# ================================================================
# FUNÇÕES DE AUTENTICAÇÃO
# ================================================================

install_api_key() {
    if [ ! -s "$API_KEY_FILE" ]; then
        mkdir -p "$(dirname "$API_KEY_FILE")"
        openssl rand -hex 32 > "$API_KEY_FILE"
        chmod 0600 "$API_KEY_FILE"
        chown root:root "$API_KEY_FILE"
        echo -e "${TXT_GREEN}✅ API key gerada: $API_KEY_FILE${RESET}"
    fi
}

show_api_key() {
    if [ -s "$API_KEY_FILE" ]; then
        echo -e "${TXT_CYAN}API Key atual:${RESET}"
        cat "$API_KEY_FILE"
    else
        echo -e "${TXT_YELLOW}⚠ Nenhuma API key encontrada. Execute [6] para gerar.${RESET}"
    fi
}

regenerate_api_key() {
    echo -e "${TXT_YELLOW}⚠ Isso irá invalidar a API key atual!${RESET}"
    read -rp "Continuar? [s/N]: " confirm
    if [[ ! "${confirm:-n}" =~ ^[Ss]$ ]]; then
        echo "Cancelado."
        return 1
    fi

    local was_running=false
    local running_port="$DEFAULT_PORT"
    if [ -f "$API_PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$API_PID_FILE" 2>/dev/null || true)
        if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
            was_running=true
            [ -f "$API_PORT_FILE" ] && running_port=$(cat "$API_PORT_FILE" 2>/dev/null || echo "$DEFAULT_PORT")
        fi
    fi

    rm -f "$API_KEY_FILE"
    install_api_key
    echo -e "${TXT_GREEN}✅ Nova API key gerada!${RESET}"
    show_api_key

    if [ "$was_running" = true ]; then
        echo ""
        echo -e "${TXT_YELLOW}Reiniciando API na porta ${running_port} para aplicar a nova chave...${RESET}"
        _stop_api_server
        _start_api_server "$running_port"
    fi
}

# ================================================================
# SERVIDOR HTTP COM AUTENTICAÇÃO
# ================================================================

_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${port}$"
    else
        python3 -c "import socket,sys; s=socket.socket(); r=s.connect_ex(('127.0.0.1',int(sys.argv[1]))); s.close(); sys.exit(0 if r==0 else 1)" "$port" 2>/dev/null
    fi
}

_start_api_server() {
    local port="${1:-$DEFAULT_PORT}"

    if [ -f "$API_PID_FILE" ]; then
        local existing_pid
        existing_pid=$(cat "$API_PID_FILE" 2>/dev/null || true)
        if [ -n "${existing_pid:-}" ] && kill -0 "$existing_pid" 2>/dev/null; then
            echo -e "${TXT_YELLOW}⚠ A API já está em execução (PID ${existing_pid}). Pare-a antes de iniciar outra.${RESET}"
            return 1
        fi
        rm -f "$API_PID_FILE" "$API_PORT_FILE"
    fi

    if _port_in_use "$port"; then
        echo -e "${TXT_RED}❌ Porta ${port} já está em uso.${RESET}"
        return 1
    fi

    install_api_key

    local api_key
    api_key=$(tr -d '[:space:]' < "$API_KEY_FILE" 2>/dev/null || echo "")
    if [ -z "$api_key" ]; then
        echo -e "${TXT_RED}❌ Falha ao ler API key.${RESET}"
        return 1
    fi

    touch "$API_LOG"
    chmod 0600 "$API_LOG"

    echo -e "${TXT_YELLOW}Iniciando API protegida na porta ${port}...${RESET}"

    nohup python3 - "$port" "$api_key" "$USER_DB" "$CONFIG_PATH" "$PRESET_FILE" </dev/null >>"$API_LOG" 2>&1 << 'PYSERVER' &
import sys, json, os, time, hmac, threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime

PORT = int(sys.argv[1])
API_KEY = sys.argv[2]
USER_DB = sys.argv[3]
CFG = sys.argv[4]
PRESET = sys.argv[5]

RATE_LOCK = threading.Lock()
RATE_BUCKETS = {}
RATE_MAX = 60
RATE_WINDOW = 60

class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

def is_process_running(proc_name):
    try:
        for pid in os.listdir('/proc'):
            if pid.isdigit():
                try:
                    with open(os.path.join('/proc', pid, 'comm'), 'r') as f:
                        if f.read().strip() == proc_name:
                            return True
                except Exception:
                    continue
    except Exception:
        pass
    return False

def load_db():
    users = {}
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                parts = line.strip().split('|')
                if len(parts) >= 3 and parts[0]:
                    users[parts[0].lower()] = {'uuid': parts[1], 'expiry': parts[2]}
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
        exp_date = datetime.strptime(expiry, '%Y-%m-%d').date()
        return (exp_date - datetime.now().date()).days
    except Exception:
        return -1

def user_status(expiry, locked):
    if locked:
        return 'suspended'
    if days_left(expiry) < 0:
        return 'expired'
    return 'active'

def load_cfg():
    try:
        with open(CFG, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}

def load_preset():
    try:
        with open(PRESET, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}

def check_rate_limit(ip):
    now = time.time()
    cutoff = now - RATE_WINDOW
    with RATE_LOCK:
        # Limpeza periódica para evitar crescimento de memória
        if len(RATE_BUCKETS) > 1024:
            stale = [k for k, v in RATE_BUCKETS.items() if not v or v[-1] <= cutoff]
            for k in stale:
                del RATE_BUCKETS[k]

        timestamps = [t for t in RATE_BUCKETS.get(ip, []) if t > cutoff]
        if len(timestamps) >= RATE_MAX:
            RATE_BUCKETS[ip] = timestamps
            return False
        timestamps.append(now)
        RATE_BUCKETS[ip] = timestamps
        return True

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        sys.stdout.write(f"[{ts}] {self.client_address[0]} - {fmt % args}\n")
        sys.stdout.flush()

    def send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def get_client_ip(self):
        peer_ip = self.client_address[0]
        # Aceita cabeçalhos de encaminhamento apenas se vierem de proxy reverso local
        if peer_ip in ('127.0.0.1', '::1'):
            xff = self.headers.get('X-Forwarded-For')
            if xff:
                return xff.split(',')[0].strip()
            xri = self.headers.get('X-Real-IP')
            if xri:
                return xri.strip()
        return peer_ip

    def check_auth(self):
        provided_key = self.headers.get('X-API-Key', '').strip()
        if not provided_key or not API_KEY:
            return False
        return hmac.compare_digest(provided_key, API_KEY)

    def do_GET(self):
        try:
            parsed = urlparse(self.path)
            qs = parse_qs(parsed.query)
            path = parsed.path.rstrip('/') or '/'
            client_ip = self.get_client_ip()

            if path != '/health' and not check_rate_limit(client_ip):
                self.send_json(429, {
                    'error': 'rate_limit_exceeded',
                    'message': 'Máximo 60 requests/minuto',
                    'retry_after': 60
                })
                return

            if path == '/health':
                self.send_json(200, {
                    'status': 'ok',
                    'service': 'TURBONET XRAY Check API V1.3',
                    'version': 'auth_required'
                })
                return

            if not self.check_auth():
                self.send_json(401, {
                    'error': 'unauthorized',
                    'message': 'API key inválida ou não fornecida',
                    'hint': 'Use header: X-API-Key: <sua_api_key>'
                })
                return

            if path in ('/check/status', '/status'):
                cfg = load_cfg()
                preset = load_preset()
                xray_ok = is_process_running('xray') or is_process_running('xray-core')
                users = load_db()
                total = len(users)
                active = sum(
                    1 for n, u in users.items()
                    if not is_locked(n, cfg) and days_left(u['expiry']) >= 0
                )
                expired = sum(
                    1 for n, u in users.items()
                    if not is_locked(n, cfg) and days_left(u['expiry']) < 0
                )
                suspended = total - active - expired

                self.send_json(200, {
                    'xray': 'active' if xray_ok else 'inactive',
                    'protocol': preset.get('network', ''),
                    'port': preset.get('port', ''),
                    'domain': preset.get('domain', ''),
                    'users': {
                        'total': total,
                        'active': active,
                        'expired': expired,
                        'suspended': suspended
                    }
                })
                return

            if path == '/check':
                cfg_data = load_cfg()
                users = load_db()

                if 'user' in qs:
                    nick = qs['user'][0].lower().strip()
                    if nick not in users:
                        self.send_json(404, {
                            'error': 'user_not_found',
                            'name': nick
                        })
                        return

                    u = users[nick]
                    locked = is_locked(nick, cfg_data)
                    dl = days_left(u['expiry'])

                    self.send_json(200, {
                        'name': nick,
                        'uuid': u['uuid'],
                        'expiry': u['expiry'],
                        'status': user_status(u['expiry'], locked),
                        'days_left': dl,
                        'locked': locked
                    })
                    return

                if 'uuid' in qs:
                    target_uuid = qs['uuid'][0].lower().strip()
                    for nick, u in users.items():
                        if u['uuid'].lower() == target_uuid:
                            locked = is_locked(nick, cfg_data)
                            dl = days_left(u['expiry'])
                            self.send_json(200, {
                                'name': nick,
                                'uuid': u['uuid'],
                                'expiry': u['expiry'],
                                'status': user_status(u['expiry'], locked),
                                'days_left': dl,
                                'locked': locked
                            })
                            return
                    self.send_json(404, {'error': 'uuid_not_found'})
                    return

                self.send_json(400, {
                    'error': 'invalid_request',
                    'usage': '/check?user=NAME ou /check?uuid=UUID'
                })
                return

            self.send_json(404, {
                'error': 'not_found',
                'endpoints': [
                    '/health (público)',
                    '/check?user=NAME (requer X-API-Key)',
                    '/check?uuid=UUID (requer X-API-Key)',
                    '/check/status (requer X-API-Key)'
                ]
            })
        except Exception:
            self.send_json(500, {'error': 'internal_server_error'})

ReusableThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
PYSERVER

    local server_pid=$!
    sleep 1

    if kill -0 "$server_pid" 2>/dev/null; then
        echo "$server_pid" > "$API_PID_FILE"
        echo "$port" > "$API_PORT_FILE"
        chmod 0600 "$API_PID_FILE" "$API_PORT_FILE"
        echo -e "${TXT_GREEN}✅ API protegida iniciada! PID: ${server_pid}${RESET}"
        echo ""
        echo -e " ${TXT_CYAN}Endpoints disponíveis:${RESET}"
        echo ""
        echo -e " ${TXT_GREEN}PÚBLICO (sem auth):${RESET}"
        echo -e "   GET /health — Status do serviço"
        echo ""
        echo -e " ${TXT_YELLOW}PROTEGIDOS (requer X-API-Key):${RESET}"
        local pub_ip
        pub_ip=$(curl -4fsSL --max-time 5 https://icanhazip.com 2>/dev/null || echo "SEU_IP")
        echo -e "   GET http://${pub_ip}:${port}/check?user=NOME"
        echo -e "   GET http://${pub_ip}:${port}/check?uuid=UUID"
        echo -e "   GET http://${pub_ip}:${port}/check/status"
        echo ""
        echo -e " ${TXT_CYAN}Cabeçalhos necessários:${RESET}"
        echo -e "   X-API-Key: ${api_key:0:8}..."
        echo ""
        echo -e " ${TXT_RED}⚠ Certifique-se que a porta ${port} está aberta no firewall!${RESET}"
        echo ""
        echo " Para parar: selecione [3] Parar API neste menu"
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar a API. Verifique os logs em [7].${RESET}"
        rm -f "$API_PID_FILE" "$API_PORT_FILE"
        return 1
    fi
}

_stop_api_server() {
    if [ ! -f "$API_PID_FILE" ]; then
        echo -e "${TXT_YELLOW}API não está rodando.${RESET}"
        return 0
    fi

    local pid
    pid=$(cat "$API_PID_FILE" 2>/dev/null || true)

    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
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

    local pid
    pid=$(cat "$API_PID_FILE" 2>/dev/null || true)
    local port=""
    [ -f "$API_PORT_FILE" ] && port=$(cat "$API_PORT_FILE" 2>/dev/null || true)

    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        echo -e " ${TXT_GREEN}ATIVA${RESET} — PID ${pid}, porta ${port}"
    else
        echo -e " ${TXT_RED}PROCESSO MORTO${RESET} (PID ${pid:-?} não existe)"
        rm -f "$API_PID_FILE" "$API_PORT_FILE"
    fi
}

_test_api() {
    if [ ! -f "$API_PORT_FILE" ]; then
        echo -e "${TXT_RED}API não está rodando.${RESET}"; return
    fi
    if [ ! -s "$API_KEY_FILE" ]; then
        echo -e "${TXT_RED}API key não encontrada.${RESET}"; return
    fi

    local port api_key
    port=$(cat "$API_PORT_FILE")
    api_key=$(tr -d '[:space:]' < "$API_KEY_FILE")

    echo -e "${TXT_CYAN}Testando API na porta ${port}...${RESET}"
    echo ""

    echo -e "${TXT_YELLOW}[GET /health] — SEM AUTENTICAÇÃO${RESET}"
    curl -s "http://127.0.0.1:${port}/health" | python3 -m json.tool 2>/dev/null || \
    curl -s "http://127.0.0.1:${port}/health"
    echo ""

    echo -e "${TXT_YELLOW}[GET /check/status] — SEM API KEY (deve falhar 401)${RESET}"
    curl -s "http://127.0.0.1:${port}/check/status" | python3 -m json.tool 2>/dev/null || \
    curl -s "http://127.0.0.1:${port}/check/status"
    echo ""

    echo -e "${TXT_YELLOW}[GET /check/status] — COM API KEY CORRETA${RESET}"
    curl -s -H "X-API-Key: ${api_key}" "http://127.0.0.1:${port}/check/status" | python3 -m json.tool 2>/dev/null || \
    curl -s -H "X-API-Key: ${api_key}" "http://127.0.0.1:${port}/check/status"
    echo ""

    if [ -s "$USER_DB" ]; then
        local first_user
        first_user=$(head -1 "$USER_DB" | cut -d'|' -f1)
        echo -e "${TXT_YELLOW}[GET /check?user=${first_user}] — COM API KEY${RESET}"
        curl -s -H "X-API-Key: ${api_key}" "http://127.0.0.1:${port}/check?user=${first_user}" | python3 -m json.tool 2>/dev/null || \
        curl -s -H "X-API-Key: ${api_key}" "http://127.0.0.1:${port}/check?user=${first_user}"
        echo ""
    fi

    echo -e "${TXT_CYAN}✅ Testes concluídos!${RESET}"
}

# ================================================================
# MENU PRINCIPAL
# ================================================================

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"; exit 1
fi

while true; do
    clear
    echo -e "${TITLE_BAR} API /CHECK — TURBONET XRAY V1.3 ${RESET}"
    echo ""
    echo -e " Status:$(_api_status)"
    echo ""
    echo -e "${TXT_GREEN}[1] Iniciar API (porta padrão: ${DEFAULT_PORT})${RESET}"
    echo -e "${TXT_GREEN}[2] Iniciar API em porta personalizada${RESET}"
    echo -e "${TXT_RED}[3] Parar API${RESET}"
    echo -e "${TXT_CYAN}[4] Testar API${RESET}"
    echo -e "${TXT_CYAN}[5] Ver API Key atual${RESET}"
    echo -e "${TXT_YELLOW}[6] Gerar nova API Key${RESET}"
    echo -e "${TXT_CYAN}[7] Ver logs${RESET}"
    echo -e "${TXT_YELLOW}[8] Verificar firewall (ufw)${RESET}"
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
            if [ -s "$API_KEY_FILE" ]; then
                echo ""
                echo -e "${TXT_CYAN}Sua API Key:${RESET}"
                cat "$API_KEY_FILE"
                echo ""
                echo -e "${TXT_YELLOW}⚠ Mantenha esta chave segura!${RESET}"
            else
                echo -e "${TXT_YELLOW}⚠ Nenhuma API key encontrada.${RESET}"
            fi
            read -rp "Enter..."
        ;;
        6)
            regenerate_api_key || true
            read -rp "Enter..."
        ;;
        7)
            if [ -s "$API_LOG" ]; then
                tail -30 "$API_LOG"
            else
                echo "Sem logs disponíveis."
            fi
            read -rp "Enter..."
        ;;
        8)
            echo ""
            echo -e "${TXT_CYAN}Verificando firewall...${RESET}"
            if command -v ufw &>/dev/null; then
                echo "Regras UFW ativas:"
                ufw status numbered 2>/dev/null || echo "UFW desabilitado"
            fi
            echo ""
            echo -e "${TXT_YELLOW}Para abrir porta ${DEFAULT_PORT}:${RESET}"
            echo "  ufw allow ${DEFAULT_PORT}/tcp"
            read -rp "Enter..."
        ;;
        0) exit 0 ;;
        *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
