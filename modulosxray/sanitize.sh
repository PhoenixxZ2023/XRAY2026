#!/bin/bash
# sanitize.sh - TURBONET XRAY V1.0
# Módulo de sanitização e validação de entrada
#用法: source sanitize.sh; validate_input "nick" "usuario123"
#
# Este módulo deve ser "sourceado" por outros scripts:
#   source /usr/local/bin/sanitize.sh
#
# Funções disponíveis:
#   validate_nick()         - Valida nome de usuário
#   validate_domain()      - Valida domínio
#   validate_port()        - Valida porta
#   validate_uuid()        - Valida UUID
#   validate_date()        - Valida data (YYYY-MM-DD)
#   sanitize_path()        - Sanitiza caminho de arquivo
#   sanitize_json()        - Escapa caracteres para JSON
#   log_audit()            - Log de auditoria (criação, exclusão, etc.)

TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

# ================================================================
# CONFIGURAÇÕES
# ================================================================
AUDIT_LOG="/opt/XrayTools/audit.log"
MAX_NICK_LENGTH=9
MIN_NICK_LENGTH=5
MAX_PATH_LENGTH=255
MAX_INPUT_LENGTH=1024

# ================================================================
# VALIDAÇÃO DE NOME DE USUÁRIO
# ================================================================

# Valida nome de usuário (5-9 caracteres, letras e números, minúsculas)
# Retorna 0 se válido, 1 se inválido
# Uso: validate_nick "usuario123" && echo "Válido" || echo "Inválido"
validate_nick() {
    local nick="${1:-}"

    # Verifica se está vazio
    if [ -z "$nick" ]; then
        echo -e "${TXT_RED}❌ Nick não pode estar vazio.${RESET}" >&2
        return 1
    fi

    # Verifica tamanho máximo da entrada
    if [ ${#nick} -gt $MAX_INPUT_LENGTH ]; then
        echo -e "${TXT_RED}❌ Nick muito longo (máx ${MAX_INPUT_LENGTH} caracteres).${RESET}" >&2
        return 1
    fi

    # Normaliza para minúsculas
    nick=$(echo "$nick" | tr '[:upper:]' '[:lower:]')

    # Remove caracteres não alfanuméricos (sanitização)
    local sanitized
    sanitized=$(echo "$nick" | tr -cd 'a-z0-9')

    # Verifica se ficou vazio após sanitização
    if [ -z "$sanitized" ]; then
        echo -e "${TXT_RED}❌ Nick contém apenas caracteres inválidos.${RESET}" >&2
        return 1
    fi

    # Verifica tamanho (5-9 caracteres)
    if [ ${#sanitized} -lt $MIN_NICK_LENGTH ] || [ ${#sanitized} -gt $MAX_NICK_LENGTH ]; then
        echo -e "${TXT_RED}❌ Nick deve ter entre ${MIN_NICK_LENGTH} e ${MAX_NICK_LENGTH} caracteres.${RESET}" >&2
        return 1
    fi

    # Verifica se não começou com número (evita problemas com parsing)
    if [[ "$sanitized" =~ ^[0-9] ]]; then
        echo -e "${TXT_RED}❌ Nick não pode começar com número.${RESET}" >&2
        return 1
    fi

    return 0
}

# Versão "quiet" - retorna 0/1 sem mensagens
validate_nick_quiet() {
    local nick="${1:-}"
    [ -z "$nick" ] && return 1
    [ ${#nick} -gt $MAX_INPUT_LENGTH ] && return 1
    nick=$(echo "$nick" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    [ -z "$nick" ] && return 1
    [ ${#nick} -lt $MIN_NICK_LENGTH ] && return 1
    [ ${#nick} -gt $MAX_NICK_LENGTH ] && return 1
    [[ "$nick" =~ ^[0-9] ]] && return 1
    return 0
}

# Normaliza nick (converte para minúsculas e remove chars inválidos)
normalize_nick() {
    local nick="${1:-}"
    echo "$nick" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

# ================================================================
# VALIDAÇÃO DE DOMÍNIO
# ================================================================

validate_domain() {
    local domain="${1:-}"
    domain=$(echo "$domain" | tr -d '[:space:][:cntrl:]')

    [ -z "$domain" ] && return 1

    # Não aceita IP direto
    if [[ "$domain" =~ ^[0-9.]+$ ]]; then
        return 1
    fi

    # Valida formato de domínio
    if [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi

    return 1
}

validate_domain_or_ip() {
    local d="${1:-}"
    d=$(echo "$d" | tr -d '[:space:][:cntrl:]')

    [ -z "$d" ] && return 1

    # Valida como IP
    if [[ "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra parts <<< "$d"
        for p in "${parts[@]}"; do
            if ! (( p <= 255 )); then return 1; fi
        done
        local o1="${parts[0]}"
        # Rejeita IPs privados/reservados
        if [ "$o1" -eq 0 ] || [ "$o1" -eq 127 ]; then return 1; fi
        if [ "$o1" -eq 255 ]; then return 1; fi
        if [ "$o1" -eq 10 ]; then return 1; fi
        if [ "$o1" -eq 172 ] && ((${parts[1]} >= 16 && ${parts[1]} <= 31)); then return 1; fi
        if [ "$o1" -eq 192 ] && [ "${parts[1]}" -eq 168 ]; then return 1; fi
        return 0
    fi

    validate_domain "$d"
}

# ================================================================
# VALIDAÇÃO DE PORTA
# ================================================================

validate_port() {
    local p="${1:-}"

    if [[ ! "$p" =~ ^[0-9]{1,5}$ ]]; then
        return 1
    fi

    if (( p >= 1 && p <= 65535 )); then
        return 0
    fi

    return 1
}

# ================================================================
# VALIDAÇÃO DE UUID
# ================================================================

validate_uuid() {
    local uuid="${1:-}"

    if [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        return 0
    fi

    return 1
}

validate_uuid_quiet() {
    local uuid="${1:-}"
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# ================================================================
# VALIDAÇÃO DE DATA
# ================================================================

validate_date() {
    local date="${1:-}"

    if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        return 1
    fi

    # Verifica se a data é válida (dia/mes)
    local year month day
    year=$(echo "$date" | cut -d'-' -f1)
    month=$(echo "$date" | cut -d'-' -f2)
    day=$(echo "$date" | cut -d'-' -f3)

    if (( month < 1 || month > 12 )); then
        return 1
    fi

    if (( day < 1 || day > 31 )); then
        return 1
    fi

    return 0
}

# ================================================================
# SANITIZAÇÃO DE CAMINHO
# ================================================================

sanitize_path() {
    local path="${1:-}"

    # Remove null bytes
    path=$(echo "$path" | tr -d '\0')

    # Remove caracteres perigosos para caminhos
    path=$(echo "$path" | tr -cd 'a-zA-Z0-9._/-')

    # Limita tamanho
    if [ ${#path} -gt $MAX_PATH_LENGTH ]; then
        path="${path:0:$MAX_PATH_LENGTH}"
    fi

    # Impede traversal de caminho (..)
    if [[ "$path" == *".."* ]]; then
        echo "/tmp/invalid_path"
        return 1
    fi

    echo "$path"
}

# ================================================================
# SANITIZAÇÃO DE JSON
# ================================================================

sanitize_json() {
    local input="${1:-}"

    # Escapa caracteres especiais para JSON
    # \ → \\
    # " → \"
    # Newlines → \n
    # Tabs → \t
    input=$(echo "$input" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g')

    echo "$input"
}

# ================================================================
# LOG DE AUDITORIA
# ================================================================

log_audit() {
    local action="${1:-}"
    local target="${2:-}"
    local details="${3:-}"
    local user="${4:-root}"
    local timestamp ip

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    ip=$(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()' || echo "local")

    # Cria diretório de logs se não existir
    mkdir -p "$(dirname "$AUDIT_LOG")"

    # Formato: timestamp|user|action|target|details|ip
    echo "${timestamp}|${user}|${action}|${target}|${details}|${ip}" >> "$AUDIT_LOG"

    # Mantém apenas os últimos 10000 registros
    if [ -f "$AUDIT_LOG" ]; then
        lines=$(wc -l < "$AUDIT_FILE" 2>/dev/null || echo 0)
        if [ "$lines" -gt 10000 ]; then
            tail -n 9000 "$AUDIT_LOG" > "${AUDIT_LOG}.tmp"
            mv "${AUDIT_LOG}.tmp" "$AUDIT_LOG"
        fi
    fi
}

# ================================================================
# VALIDAÇÃO DE ENTRADA CRÍTICA (anti-injection)
# ================================================================

# Verifica se a entrada contém caracteres potencialmente perigosos
check_dangerous_chars() {
    local input="${1:-}"

    # Caracteres que podem causar problemas em shell/scripts
    local dangerous=';|&$`\!#*?<>[]{}()'

    for char in $(echo "$dangerous" | grep -o '.'); do
        if echo "$input" | grep -qF "$char"; then
            return 1  # Caractere perigoso encontrado
        fi
    done

    return 0
}

# Versão estrita: rejeita qualquer caractere não alfanumérico
sanitize_strict() {
    local input="${1:-}"
    echo "$input" | tr -cd 'a-zA-Z0-9'
}

# ================================================================
# HELPERS DE VALIDAÇÃO RÁPIDA
# ================================================================

is_valid_nick_format() {
    local nick="${1:-}"
    [[ "$nick" =~ ^[a-z][a-z0-9]{4,8}$ ]]
}

is_existing_user() {
    local nick="${1:-}"
    local user_db="${2:-/opt/XrayTools/users.db}"

    [ -z "$nick" ] && return 1
    [ ! -f "$user_db" ] && return 1

    if grep -q "^${nick}|" "$user_db" 2>/dev/null; then
        return 0
    fi

    return 1
}

is_locked_user() {
    local nick="${1:-}"
    local config="${2:-/usr/local/etc/xray/config.json}"

    [ -z "$nick" ] && return 1
    [ ! -f "$config" ] && return 1

    if jq -e --arg lock "LOCKED_${nick}" \
        'any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?; .email == $lock)' \
        "$config" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# ================================================================
# EXPORTAÇÃO DE FUNÇÕES
# Exporta apenas as funções seguras para uso em scripts filhos
# ================================================================

# Para usar em outros scripts:
# source /usr/local/bin/sanitize.sh
#
# validate_nick "usuario123" && echo "OK"
# normalize_nick "Usuario123"  # retorna "usuario123"

# Se for executado diretamente (não sourceado), mostra ajuda
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "========================================="
    echo " SANITIZE.SH - Módulo de Validação V1.0"
    echo "========================================="
    echo ""
    echo "Este arquivo deve ser 'sourceado' por outros scripts."
    echo ""
    echo "Uso: source sanitize.sh"
    echo ""
    echo "Funções disponíveis:"
    echo "  validate_nick()      - Valida nome (5-9 chars, a-z0-9)"
    echo "  normalize_nick()    - Normaliza para minúsculas"
    echo "  validate_domain()   - Valida domínio"
    echo "  validate_port()     - Valida porta (1-65535)"
    echo "  validate_uuid()     - Valida UUID"
    echo "  validate_date()     - Valida data (YYYY-MM-DD)"
    echo "  sanitize_path()     - Sanitiza caminho"
    echo "  sanitize_json()     - Escapa para JSON"
    echo "  log_audit()         - Log de auditoria"
    echo ""
fi
