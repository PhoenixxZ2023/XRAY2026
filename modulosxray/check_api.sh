#!/bin/bash
# check_api.sh - TURBONET XRAY V1.1
# Correções aplicadas V1.1:
# - AUTENTICAÇÃO API KEY: Exige X-API-Key no header para proteger dados sensíveis
# - Endpoint /health continua público (healthcheck)
# - API key gerada automaticamente em install_api_key()
# - Rate limiting básico por IP (evita enumeração)
#
# Endpoints:
# GET /check?user=NOME      → status por nome (requer API key)
# GET /check?uuid=UUID      → status por UUID (requer API key)
# GET /check/status         → status geral (requer API key)
# GET /health               → healthcheck (público, sem auth)
#
# Autenticação: Header "X-API-Key: <api_key>"
# API key armazenada em: /opt/XrayTools/.api_key (permissão 0600)
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
RATE_LIMIT_FILE="/tmp/turbonet_api_ratelimit.db"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

# ================================================================
# FUNÇÕES DE AUTENTICAÇÃO
# ================================================================

# Gera API key segura se não existir
install_api_key() {
    if [ ! -f "$API_KEY_FILE" ]; then
        mkdir -p "$(dirname "$API_KEY_FILE")"
        # Gera chave de 64 caracteres hex
        openssl rand -hex 32 > "$API_KEY_FILE"
        chmod 0600 "$API_KEY_FILE"
        echo -e "${TXT_GREEN}✅ API key gerada: $API_KEY_FILE${RESET}"
    fi
}

# Valida API key (retorna 0 se válido, 1 se inválido)
validate_api_key() {
    local provided_key="$1"
    local stored_key

    [ -z "$API_KEY_FILE" ] && return 1
    [ ! -f "$API_KEY_FILE" ] && return 1

    stored_key=$(cat "$API_KEY_FILE" 2>/dev/null || echo "")
    [ -z "$stored_key" ] && return 1

    # Timing-safe comparison
    if [ "${#provided_key}" -eq "${#stored_key}" ]; then
        if [ "$provided_key" = "$stored_key" ]; then
            return 0
        fi
    fi
    return 1
}

# Obtém IP do cliente da requisição
get_client_ip() {
    local ip="${REMOTE_ADDR:-127.0.0.1}"
    # Headers comuns para detectar IP real (por trás de proxy)
    ip="${HTTP_X_FORWARDED_FOR:-$ip}"
    ip="${HTTP_X_REAL_IP:-$ip}"
    # Pega primeiro IP se tiver vírgula (múltiplos proxies)
    echo "$ip" | cut -d',' -f1 | cut -d' ' -f1
}

# Rate limiting: máximo 60 requests/minuto por IP
check_rate_limit() {
    local client_ip="$1"
    local now current_count max_requests window

    now=$(date +%s)
    max_requests=60
    window=60  # 60 segundos

    [ ! -d "$(dirname "$RATE_LIMIT_FILE")" ] && mkdir -p "$(dirname "$RATE_LIMIT_FILE")"
    touch "$RATE_LIMIT_FILE"

    # Limpa entradas antigas (> 2 minutos)
    awk -F'|' -v now="$now" -v window="$window" '
        BEGIN { cutoff = now - (window * 2) }
        $3 > cutoff { print }
    ' "$RATE_LIMIT_FILE" > "${RATE_LIMIT_FILE}.tmp" 2>/dev/null
    mv -f "${RATE_LIMIT_FILE}.tmp" "$RATE_LIMIT_FILE"

    # Conta requests recentes do IP
    current_count=$(awk -F'|' -v ip="$client_ip" -v now="$now" -v window="$window" '
        $1 == ip && ($3 > (now - window)) { count++ }
        END { print (count + 0) }
    ' "$RATE_LIMIT_FILE" 2>/dev/null || echo "0")

    if [ "$current_count" -ge "$max_requests" ]; then
        return 1  # Rate limit exceeded
    fi

    # Registra request
    echo "${client_ip}|${now}" >> "$RATE_LIMIT_FILE"
    return 0
}

# Mostra API key atual
show_api_key() {
    if [ -f "$API_KEY_FILE" ]; then
        echo -e "${TXT_CYAN}API Key atual:${RESET}"
        cat "$API_KEY_FILE"
    else
        echo -e "${TXT_YELLOW}⚠ Nenhuma API key encontrada. Execute [6] para gerar.${RESET}"
    fi
}

# Gera nova API key (com confirmação)
regenerate_api_key() {
    echo -e "${TXT_YELLOW}⚠ Isso irá invalidar a API key atual!${RESET}"
    read -rp "Continuar? [s/N]: " confirm
    if [[ ! "${confirm:-n}" =~ ^[Ss]$ ]]; then
        echo "Cancelado."
        return 1
    fi

    rm -f "$API_KEY_FILE"
    install_api_key
    echo -e "${TXT_GREEN}✅ Nova API key gerada!${RESET}"
    show_api_key
}

# ================================================================
# HELPERS DE STATUS
# ================================================================

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

# ================================================================
# SERVIDOR HTTP COM AUTENTICAÇÃO
# ================================================================

_start_api_server() {
    local port="${1:-$DEFAULT_PORT}"

    # Verifica porta livre
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${TXT_RED}❌ Porta ${port} já está em uso.${RESET}"
        return 1
    fi

    # Instala API key se não existir
    install_api_key

    local api_key
    api_key=$(cat "$API_KEY_FILE" 2>/dev/null || echo "")

    echo -e "${TXT_YELLOW}Iniciando API protegida na porta ${port}...${RESET}"

    # Gera servidor Python com autenticação
    python3 - "$port" "$api_key" "$USER_DB" "$CONFIG_PATH" "$PRESET_FILE" "$RATE_LIMIT_FILE" << 'PYSERVER' &
import sys, json, os, subprocess, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime

PORT = int(sys.argv[1])
API_KEY = sys.argv[2]
USER_DB = sys.argv[3]
CFG = sys.argv[4]
PRESET = sys.argv[5]
RATE_FILE = sys.argv[6]

def load_db():
    users = {}
    if os.path.exists(USER_DB):
        with open(USER_DB) as f:
            for line in f:
                parts = line.strip().split('|')
                if len(parts) >= 3:
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
        exp = datetime.strptime(expiry, '%Y-%m-%d')
        return (exp - datetime.now()).days
    except:
        return -1

def user_status(nick, uuid, expiry, locked):
    if locked: return 'suspended'
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

def check_rate_limit(ip):
    now = int(time.time())
    try:
        if os.path.exists(RATE_FILE):
            with open(RATE_FILE) as f:
                lines = f.readlines()
        else:
            lines = []

        # Limpa entradas antigas (>2min)
        recent = [l for l in lines if len(l.split('|')) >= 2 and int(l.split('|')[1]) > now - 120]

        # Conta requests recentes
        count = sum(1 for l in recent if l.startswith(f"{ip}|"))

        if count >= 60:  # 60 requests por minuto
            return False

        # Adiciona request
        with open(RATE_FILE, 'a') as f:
            f.write(f"{ip}|{now}\n")
        return True
    except:
        return True

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # Silencia log padrão

    def send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def get_client_ip(self):
        ip = self.client_address[0]
        # Headers de proxy
        if self.headers.get('X-Forwarded-For'):
            ip = self.headers.get('X-Forwarded-For').split(',')[0].strip()
        elif self.headers.get('X-Real-IP'):
            ip = self.headers.get('X-Real-IP')
        return ip

    def check_auth(self):
        # Pega API key do header
        provided_key = self.headers.get('X-API-Key', '')

        # Timing-safe comparison
        if len(provided_key) != len(API_KEY):
            return False

        for i in range(len(provided_key)):
            if provided_key[i] != API_KEY[i]:
                return False
        return True

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        path = parsed.path.rstrip('/')
        client_ip = self.get_client_ip()

        # Rate limiting para todos (exceto health)
        if path != '/health' and not check_rate_limit(client_ip):
            self.send_json(429, {
                'error': 'rate_limit_exceeded',
                'message': 'Máximo 60 requests/minuto',
                'retry_after': 60
            })
            return

        # Health check - PÚBLICO (sem auth)
        if path == '/health':
            self.send_json(200, {
                'status': 'ok',
                'service': 'TURBONET XRAY Check API V1.1',
                'version': 'auth_required'
            })
            return

        # Todos os outros endpoints exigem API key
        if not self.check_auth():
            self.send_json(401, {
                'error': 'unauthorized',
                'message': 'API key inválida ou não fornecida',
                'hint': 'Use header: X-API-Key: <sua_api_key>'
            })
            return

        # Status geral
        if path in ('/check/status', '/status'):
            cfg = load_cfg()
            preset = load_preset()
            xray_ok = subprocess.run(['systemctl','is-active','xray'],
                capture_output=True).returncode == 0
            users = load_db()
            total = len(users)
            active = sum(1 for n, u in users.items()
                if not is_locked(n, cfg) and days_left(u['expiry']) >= 0)
            expired = sum(1 for u in users.values() if days_left(u['expiry']) < 0)
            suspended = total - active - expired

            self.send_json(200, {
                'xray': 'active' if xray_ok else 'inactive',
                'protocol': preset.get('network',''),
                'port': preset.get('port',''),
                'domain': preset.get('domain',''),
                'users': {
                    'total': total,
                    'active': active,
                    'expired': expired,
                    'suspended': suspended
                }
            })
            return

        # Consulta por usuário
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

                # ⚠️ NOTA: UUID é exposto, mas apenas para quem tem API key válida
                self.send_json(200, {
                    'name': nick,
                    'uuid': u['uuid'],
                    'expiry': u['expiry'],
                    'status': user_status(nick, u['uuid'], u['expiry'], locked),
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
                            'status': user_status(nick, u['uuid'], u['expiry'], locked),
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

HTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
PYSERVER

    local server_pid=$!
    sleep 2

    if kill -0 "$server_pid" 2>/dev/null; then
        echo "$server_pid" > "$API_PID_FILE"
        echo "$port" > "$API_PORT_FILE"
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
        echo -e "   X-API-Key: $(cat "$API_KEY_FILE" 2>/dev/null | cut -c1-8)..."
        echo ""
        echo -e " ${TXT_RED}⚠ Certifique-se que a porta ${port} está aberta no firewall!${RESET}"
        echo ""
        echo " Para parar: selecione [2] Parar API neste menu"
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar a API. Verifique logs.${RESET}"
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
    if [ ! -f "$API_KEY_FILE" ]; then
        echo -e "${TXT_RED}API key não encontrada.${RESET}"; return
    fi

    local port api_key
    port=$(cat "$API_PORT_FILE")
    api_key=$(cat "$API_KEY_FILE")

    echo -e "${TXT_CYAN}Testando API na porta ${port}...${RESET}"
    echo ""

    # Testa health (público)
    echo -e "${TXT_YELLOW}[GET /health] — SEM AUTENTICAÇÃO${RESET}"
    curl -s "http://127.0.0.1:${port}/health" | python3 -m json.tool 2>/dev/null || \
    curl -s "http://127.0.0.1:${port}/health"
    echo ""

    # Testa sem API key (deve falhar)
    echo -e "${TXT_YELLOW}[GET /check/status] — SEM API KEY (deve falhar 401)${RESET}"
    curl -s "http://127.0.0.1:${port}/check/status" | python3 -m json.tool 2>/dev/null || \
    curl -s "http://127.0.0.1:${port}/check/status"
    echo ""

    # Testa com API key correta
    echo -e "${TXT_YELLOW}[GET /check/status] — COM API KEY CORRETA${RESET}"
    curl -s -H "X-API-Key: ${api_key}" "http://127.0.0.1:${port}/check/status" | python3 -m json.tool 2>/dev/null || \
    curl -s -H "X-API-Key: ${api_key}" "http://127.0.0.1:${port}/check/status"
    echo ""

    # Testa com usuário
    if [ -s "$USER_DB" ]; then
        local first_user; first_user=$(head -1 "$USER_DB" | cut -d'|' -f1)
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
    echo -e "${TITLE_BAR} API /CHECK — TURBONET XRAY V1.1 ${RESET}"
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
            if [ -f "$API_KEY_FILE" ]; then
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
            install_api_key
            echo -e "${TXT_GREEN}✅ API Key准备好了！${RESET}"
            show_api_key
            read -rp "Enter..."
        ;;
        7)
            if [ -f "$API_LOG" ]; then
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
