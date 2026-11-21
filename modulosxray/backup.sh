#!/bin/bash
# backup.sh - TURBONET XRAY V1.2 (PRO + Compatibilidade Bot Telegram)
# Atualizações V1.2:
#   - _apply_xraytools_perms e _apply_config_perms preservam permissões 2770/0660 quando o usuário `botxray` existe
#   - Backup inclui também arquivos de configuração/estado do bot em /opt/XrayTools (*.env, *.json, bot.db)
#   - Sincronização completa de contas Linux (`usermod`, `chage`, `passwd`, `pkill`) com validação de nick e UID >= 1000
#   - Reinício garantido dos serviços `xray` e `botxray` mesmo em caso de rollback por falha na extração

set -Eeuo pipefail

# --- CLEANUP CENTRALIZADO ---
_TMPDIR_BKP=""
_SNAP_FILE=""
_cleanup() {
    [ -n "${_TMPDIR_BKP:-}" ] && rm -rf "$_TMPDIR_BKP" 2>/dev/null || true
    [ "${_SNAP_REMOVE_OK:-0}" = "1" ] && [ -n "${_SNAP_FILE:-}" ] && rm -f "$_SNAP_FILE" 2>/dev/null || true
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; read -rp "Enter...";' ERR

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

BACKUP_DIR="/root/backups"
XRAYTOOLS_DIR="/opt/XrayTools"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAY_BIN="/usr/local/bin/xray"
MAX_BACKUPS=5
_SNAP_REMOVE_OK=0

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${TXT_RED}❌ Execute como root!${RESET}"
        exit 1
    fi
}

require_root
mkdir -p "$BACKUP_DIR"

validate_nick() { [[ "${1:-}" =~ ^[a-zA-Z0-9]{5,9}$ ]]; }

# --- DETECÇÃO DINÂMICA DE DONO E PERMISSÕES ---
_detect_xray_owner() {
    local svc_user=""
    if command -v systemctl &>/dev/null; then
        svc_user=$(systemctl show -p User --value xray 2>/dev/null || true)
    fi
    svc_user="${svc_user:-nobody}"
    if ! id "$svc_user" &>/dev/null; then
        svc_user="root"
    fi
    XRAY_USER="$svc_user"
    XRAY_GROUP="$(id -gn "$XRAY_USER")"
}

_apply_xraytools_perms() {
    mkdir -p "$XRAYTOOLS_DIR"
    if id -u botxray &>/dev/null; then
        chown root:botxray "$XRAYTOOLS_DIR"
        chmod 2770 "$XRAYTOOLS_DIR"

        for db_f in users.db limits.db usage.db session.db active_domain .api_key bot.db; do
            if [ -f "${XRAYTOOLS_DIR}/${db_f}" ]; then
                chown botxray:botxray "${XRAYTOOLS_DIR}/${db_f}"
                chmod 0660 "${XRAYTOOLS_DIR}/${db_f}"
            fi
        done

        find "$XRAYTOOLS_DIR" -maxdepth 1 \( -name "*.env" -o -name "*.json" \) -type f \
            -exec chown botxray:botxray {} \; \
            -exec chmod 0660 {} \; 2>/dev/null || true

        if [ -d "${XRAYTOOLS_DIR}/users" ]; then
            chown root:botxray "${XRAYTOOLS_DIR}/users"
            chmod 0750 "${XRAYTOOLS_DIR}/users"
            find "${XRAYTOOLS_DIR}/users" -maxdepth 1 -name "*.txt" -type f \
                -exec chown root:botxray {} \; \
                -exec chmod 0640 {} \; 2>/dev/null || true
        fi
    else
        chown root:root "$XRAYTOOLS_DIR"
        chmod 0750 "$XRAYTOOLS_DIR"

        for db_f in users.db limits.db usage.db session.db active_domain .api_key bot.db; do
            if [ -f "${XRAYTOOLS_DIR}/${db_f}" ]; then
                chown root:root "${XRAYTOOLS_DIR}/${db_f}"
                chmod 0600 "${XRAYTOOLS_DIR}/${db_f}"
            fi
        done

        find "$XRAYTOOLS_DIR" -maxdepth 1 \( -name "*.env" -o -name "*.json" \) -type f \
            -exec chown root:root {} \; \
            -exec chmod 0600 {} \; 2>/dev/null || true

        if [ -d "${XRAYTOOLS_DIR}/users" ]; then
            chown root:root "${XRAYTOOLS_DIR}/users"
            chmod 0700 "${XRAYTOOLS_DIR}/users"
            find "${XRAYTOOLS_DIR}/users" -maxdepth 1 -name "*.txt" -type f \
                -exec chown root:root {} \; \
                -exec chmod 0600 {} \; 2>/dev/null || true
        fi
    fi
}

_apply_all_restored_perms() {
    _detect_xray_owner

    local dir_mode="750"
    local file_mode="0640"
    if id -u botxray &>/dev/null; then
        dir_mode="2770"
        file_mode="0660"
    fi

    if [ -d /usr/local/etc/xray ]; then
        chown "root:${XRAY_GROUP}" /usr/local/etc/xray
        chmod "$dir_mode" /usr/local/etc/xray
    fi
    if [ -f "$CONFIG_PATH" ]; then
        chown "root:${XRAY_GROUP}" "$CONFIG_PATH"
        chmod "$file_mode" "$CONFIG_PATH"
    fi
    if [ -f "$PRESET_FILE" ]; then
        chown "root:${XRAY_GROUP}" "$PRESET_FILE"
        chmod "$file_mode" "$PRESET_FILE"
    fi

    if [ -d /opt/TurbonetCoreSSL ]; then
        chmod 750 /opt/TurbonetCoreSSL
        chown "root:${XRAY_GROUP}" /opt/TurbonetCoreSSL 2>/dev/null || true
        if [ -f /opt/TurbonetCoreSSL/fullchain.pem ]; then
            chmod 644 /opt/TurbonetCoreSSL/fullchain.pem
            chown root:root /opt/TurbonetCoreSSL/fullchain.pem
        fi
        if [ -f /opt/TurbonetCoreSSL/privkey.pem ]; then
            chmod 640 /opt/TurbonetCoreSSL/privkey.pem
            chown "root:${XRAY_GROUP}" /opt/TurbonetCoreSSL/privkey.pem
        fi
    fi

    _apply_xraytools_perms
}

_test_xray_config() {
    local cfg="$1"
    [ ! -x "$XRAY_BIN" ] && return 0
    _detect_xray_owner
    if command -v runuser &>/dev/null && [ "$XRAY_USER" != "root" ]; then
        runuser -u "$XRAY_USER" -- "$XRAY_BIN" run -test -config "$cfg"
    else
        "$XRAY_BIN" run -test -config "$cfg"
    fi
}

_wait_service_active() {
    local svc="$1"
    local tries=5
    while [ "$tries" -gt 0 ]; do
        systemctl is-active --quiet "$svc" 2>/dev/null && return 0
        sleep 1
        tries=$(( tries - 1 ))
    done
    return 1
}

_restart_services() {
    systemctl restart xray >/dev/null 2>&1 || true
    if systemctl list-unit-files botxray.service >/dev/null 2>&1; then
        systemctl restart botxray >/dev/null 2>&1 || true
    fi
}

_ensure_false_shell() {
    if [ -f /etc/shells ] && ! grep -qxF "/bin/false" /etc/shells 2>/dev/null; then
        echo "/bin/false" >> /etc/shells
    fi
}

# --- VALIDAÇÃO DE PATHS E TIPOS NO TAR (whitelist rigorosa) ---
is_safe_tar() {
    local tarfile="$1"
    local line mode entry
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        mode="${line%% *}"
        # Permite apenas arquivos regulares (-) e diretórios (d); rejeita symlinks (l) e dispositivos
        [[ "$mode" =~ ^[-d] ]] || return 1

        entry=$(echo "$line" | awk '{print $NF}')
        entry="${entry#./}"
        [ -n "$entry" ] || continue
        [[ "$entry" != /* ]]       || return 1   # path absoluto
        [[ "$entry" != *".."* ]] || return 1   # traversal
        case "$entry" in
            opt/XrayTools|opt/XrayTools/*)              ;;
            usr/local/etc/xray|usr/local/etc/xray/*)    ;;
            opt/TurbonetCoreSSL|opt/TurbonetCoreSSL/*)  ;;
            *) return 1 ;;
        esac
    done < <(tar -tvzf "$tarfile" 2>/dev/null)
    return 0
}

# --- VERIFICAÇÃO DE INTEGRIDADE DO TAR ---
verify_tar_integrity() {
    local tarfile="$1"
    if ! tar -tzf "$tarfile" >/dev/null 2>&1; then
        echo -e "${TXT_RED}❌ Arquivo tar corrompido ou ilegível.${RESET}"
        return 1
    fi

    local sha_file="${tarfile}.sha256"
    if [ -f "$sha_file" ]; then
        echo -n "Verificando integridade SHA256... "
        local expected actual
        expected=$(awk '{print $1}' "$sha_file")
        actual=$(sha256sum "$tarfile" | awk '{print $1}')
        if [ "$expected" != "$actual" ]; then
            echo -e "${TXT_RED}FALHOU${RESET}"
            echo -e "${TXT_RED}❌ SHA256 não confere — backup pode estar corrompido.${RESET}"
            echo "   Esperado: $expected"
            echo "   Obtido:   $actual"
            return 1
        fi
        echo -e "${TXT_GREEN}OK${RESET}"
    else
        echo -e "${TXT_YELLOW}⚠  Arquivo .sha256 não encontrado — verificação de integridade ignorada.${RESET}"
    fi
    return 0
}

# --- ROTAÇÃO DE BACKUPS ANTIGOS ---
rotate_backups() {
    local dir="$1" max="$2"
    local -a all_backups
    mapfile -d '' all_backups < <(find "$dir" -maxdepth 1 -name "*.tar.gz" -print0 | sort -z)
    local count="${#all_backups[@]}"
    if [ "$count" -gt "$max" ]; then
        local to_remove=$(( count - max ))
        echo -e "${TXT_CYAN}Removendo ${to_remove} backup(s) antigo(s)...${RESET}"
        local idx=0
        while [ "$idx" -lt "$to_remove" ]; do
            rm -f "${all_backups[$idx]}" "${all_backups[$idx]}.sha256"
            echo " removido: $(basename "${all_backups[$idx]}")"
            idx=$(( idx + 1 ))
        done
    fi
}

# --- MENU ---
clear
echo -e "${TITLE_BAR}   BACKUP & RESTORE (V1.2 PRO)   ${RESET}"
echo ""
echo -e "${TXT_CYAN}[1] CRIAR BACKUP${RESET}"
echo -e "${TXT_CYAN}[2] RESTAURAR BACKUP${RESET}"
echo -e "${TXT_CYAN}[0] SAIR${RESET}"
read -rp "Opção: " opt

case "${opt:-0}" in

  # ============================================================
  1)  # CRIAR BACKUP
  # ============================================================
    echo "Verificando arquivos necessários..."

    if [ ! -f "${XRAYTOOLS_DIR}/users.db" ]; then
        echo -e "${TXT_RED}❌ users.db não encontrado em ${XRAYTOOLS_DIR}/${RESET}"
        exit 1
    fi
    if [ ! -d "/usr/local/etc/xray" ]; then
        echo -e "${TXT_RED}❌ Pasta /usr/local/etc/xray não encontrada.${RESET}"
        exit 1
    fi

    umask 077
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    FILE="${BACKUP_DIR}/backup_turbonet_${TIMESTAMP}.tar.gz"
    SHA_FILE="${FILE}.sha256"

    _TMPDIR_BKP=$(mktemp -d)

    mkdir -p "$_TMPDIR_BKP/opt/XrayTools"
    for f in users.db limits.db usage.db session.db active_domain .api_key bot.db; do
        [ -f "${XRAYTOOLS_DIR}/$f" ] && cp -f "${XRAYTOOLS_DIR}/$f" "$_TMPDIR_BKP/opt/XrayTools/$f"
    done
    find "$XRAYTOOLS_DIR" -maxdepth 1 \( -name "*.env" -o -name "*.json" \) -type f \
        -exec cp -f {} "$_TMPDIR_BKP/opt/XrayTools/" \; 2>/dev/null || true

    [ -d "${XRAYTOOLS_DIR}/users" ] && \
        cp -r "${XRAYTOOLS_DIR}/users" "$_TMPDIR_BKP/opt/XrayTools/" 2>/dev/null || true

    mkdir -p "$_TMPDIR_BKP/usr/local/etc"
    cp -a /usr/local/etc/xray "$_TMPDIR_BKP/usr/local/etc/" 2>/dev/null || true

    if [ -d "/opt/TurbonetCoreSSL" ]; then
        mkdir -p "$_TMPDIR_BKP/opt"
        cp -a /opt/TurbonetCoreSSL "$_TMPDIR_BKP/opt/" 2>/dev/null || true
    fi

    echo "Criando backup..."
    if ! tar -czf "$FILE" -C "$_TMPDIR_BKP" . >/dev/null 2>&1; then
        echo -e "${TXT_RED}❌ Falha ao criar arquivo tar.${RESET}"
        rm -f "$FILE"
        exit 1
    fi

    if [ ! -s "$FILE" ]; then
        echo -e "${TXT_RED}❌ Backup criado está vazio.${RESET}"
        rm -f "$FILE"
        exit 1
    fi

    chmod 600 "$FILE"

    echo -n "Gerando SHA256... "
    sha256sum "$FILE" > "$SHA_FILE"
    chmod 600 "$SHA_FILE"
    echo -e "${TXT_GREEN}OK${RESET}"

    SIZE=$(du -sh "$FILE" | cut -f1)
    echo ""
    echo -e "${TXT_GREEN}✅ Backup criado com sucesso!${RESET}"
    echo "-----------------------------------------"
    echo -e " Arquivo: ${TXT_CYAN}$(basename "$FILE")${RESET}"
    echo -e " Tamanho: ${SIZE}"
    echo -e " SHA256:  $(basename "$SHA_FILE")"
    if [ ! -d "/opt/TurbonetCoreSSL" ]; then
        echo -e "${TXT_CYAN}Nota:${RESET} /opt/TurbonetCoreSSL não existia e não foi incluída."
    fi
    echo "-----------------------------------------"

    rotate_backups "$BACKUP_DIR" "$MAX_BACKUPS"
    ;;

  # ============================================================
  2)  # RESTAURAR BACKUP
  # ============================================================
    echo "Procurando backups disponíveis..."
    shopt -s nullglob
    FILES=("$BACKUP_DIR"/*.tar.gz)

    if [ ${#FILES[@]} -eq 0 ]; then
        echo -e "${TXT_RED}❌ Nenhum backup encontrado em ${BACKUP_DIR}.${RESET}"
        exit 1
    fi

    echo ""
    echo "Selecione um backup (0 para cancelar):"
    echo "-----------------------------------------"
    i=1
    for f in "${FILES[@]}"; do
        local_size=$(du -sh "$f" 2>/dev/null | cut -f1)
        local_date=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "$f" | cut -c1-16)
        local_sha=""
        [ -f "${f}.sha256" ] && local_sha=" [SHA256 ✓]"
        printf " [%d] %-45s %6s  %s%s\n" "$i" "$(basename "$f")" "$local_size" "$local_date" "$local_sha"
        i=$(( i + 1 ))
    done
    echo "-----------------------------------------"

    read -rp "Número: " n
    [ "${n:-0}" = "0" ] && exit 0

    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#FILES[@]}" ]; then
        echo -e "${TXT_RED}❌ Opção inválida.${RESET}"
        exit 1
    fi

    FILE="${FILES[$((n-1))]}"

    echo ""
    echo "Verificando arquivo selecionado..."
    if ! verify_tar_integrity "$FILE"; then
        exit 1
    fi

    echo -n "Validando conteúdo do backup... "
    if ! is_safe_tar "$FILE"; then
        echo -e "${TXT_RED}RECUSADO${RESET}"
        echo -e "${TXT_RED}❌ Backup contém paths ou tipos de arquivo não permitidos.${RESET}"
        exit 1
    fi
    echo -e "${TXT_GREEN}OK${RESET}"

    echo ""
    echo -e "${TXT_YELLOW}⚠  ATENÇÃO: O sistema atual será substituído pelo backup.${RESET}"
    echo -e " Backup selecionado: ${TXT_CYAN}$(basename "$FILE")${RESET}"
    read -rp "Confirmar RESTORE? [s/N]: " ok
    [[ "${ok:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

    umask 077

    echo ""
    echo "Criando snapshot do estado atual (segurança)..."
    SNAP_PATHS=( "opt/XrayTools" "usr/local/etc/xray" )
    [ -d "/opt/TurbonetCoreSSL" ] && SNAP_PATHS+=( "opt/TurbonetCoreSSL" )
    _SNAP_FILE=$(mktemp /tmp/xray_restore_snap_XXXXXX.tar.gz)
    if tar -czf "$_SNAP_FILE" -C / "${SNAP_PATHS[@]}" >/dev/null 2>&1 && [ -s "$_SNAP_FILE" ]; then
        chmod 600 "$_SNAP_FILE"
        echo -e "${TXT_GREEN}Snapshot salvo em: ${_SNAP_FILE}${RESET}"
    else
        echo -e "${TXT_YELLOW}⚠  Não foi possível criar snapshot — continuando mesmo assim.${RESET}"
        _SNAP_FILE=""
    fi

    echo "Parando serviços..."
    systemctl stop xray    >/dev/null 2>&1 || true
    systemctl stop botxray >/dev/null 2>&1 || true

    echo "Restaurando arquivos..."
    if ! tar -xzf "$FILE" -C / \
            --no-overwrite-dir \
            --no-same-permissions \
            --no-same-owner \
            2>/dev/null; then
        echo -e "${TXT_RED}❌ Falha ao extrair backup.${RESET}"
        if [ -n "${_SNAP_FILE:-}" ] && [ -f "$_SNAP_FILE" ]; then
            echo "Restaurando snapshot anterior..."
            tar -xzf "$_SNAP_FILE" -C / \
                --no-overwrite-dir \
                --no-same-permissions \
                --no-same-owner \
                >/dev/null 2>&1 || true
            _apply_all_restored_perms
            echo -e "${TXT_YELLOW}Estado anterior restaurado do snapshot.${RESET}"
        fi
        _restart_services
        exit 1
    fi

    echo "Aplicando permissões..."
    _apply_all_restored_perms

    if [ -f "$CONFIG_PATH" ]; then
        _test_xray_config "$CONFIG_PATH" >/dev/null 2>&1 || \
            echo -e "${TXT_YELLOW}⚠  Aviso: validação do config.json retornou alerta.${RESET}"
    fi

    echo "Reiniciando serviços..."
    _restart_services

    echo ""
    local_xray_status="${TXT_RED}FALHA${RESET}"
    if _wait_service_active "xray"; then
        local_xray_status="${TXT_GREEN}ATIVO${RESET}"
    fi

    local_bot_status=""
    if systemctl list-unit-files botxray.service >/dev/null 2>&1; then
        if _wait_service_active "botxray"; then
            local_bot_status="${TXT_GREEN}ATIVO${RESET}"
        else
            local_bot_status="${TXT_RED}FALHA${RESET}"
        fi
    fi

    # INTEGRAÇÃO SSH/DROPBEAR/SOCKS5: Re-sincronizar usuários respeitando vencimento, LOCKED_ e UID >= 1000
    echo "Sincronizando usuários locais (SSH/SOCKS5)..."
    if [ -s "${XRAYTOOLS_DIR}/users.db" ]; then
        _ensure_false_shell
        today_ts=$(date -d "$(date +%F)" +%s)

        while IFS='|' read -r nick uuid expiry pass limit _rest; do
            nick="${nick//$'\r'/}"
            expiry="${expiry//$'\r'/}"
            pass="${pass//$'\r'/}"

            [ -n "${nick:-}" ] && [ -n "${pass:-}" ] || continue
            validate_nick "$nick" || continue
            nick=$(echo "$nick" | tr '[:upper:]' '[:lower:]')

            exp_ts=$(date -d "${expiry:-2000-01-01}" +%s 2>/dev/null || echo 0)

            if getent passwd "$nick" >/dev/null 2>&1; then
                uid=$(id -u "$nick" 2>/dev/null || echo 0)
                shell=$(getent passwd "$nick" | cut -d: -f7)
                if [ "$uid" -lt 1000 ] || [ "$shell" != "/bin/false" ]; then
                    continue
                fi
            fi

            if [ "$exp_ts" -lt "$today_ts" ]; then
                if getent passwd "$nick" >/dev/null 2>&1; then
                    pkill -KILL -u "$nick" 2>/dev/null || true
                    userdel -r -f "$nick" 2>/dev/null || true
                fi
                continue
            fi

            is_locked=false
            if [ -s "$CONFIG_PATH" ] && command -v jq &>/dev/null; then
                jq -e --arg lock "LOCKED_${nick}" '
                    any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?;
                        .email == $lock)
                ' "$CONFIG_PATH" >/dev/null 2>&1 && is_locked=true
            fi

            getent passwd "$nick" >/dev/null 2>&1 || useradd -M -s /bin/false "$nick" 2>/dev/null || true
            echo "${nick}:${pass}" | chpasswd 2>/dev/null || true

            if [ "$is_locked" = true ]; then
                usermod -L "$nick" >/dev/null 2>&1 || true
                chage -E 0 "$nick" >/dev/null 2>&1 || true
                passwd -l "$nick" >/dev/null 2>&1 || true
                pkill -KILL -u "$nick" 2>/dev/null || true
            else
                usermod -U "$nick" >/dev/null 2>&1 || true
                chage -E -1 "$nick" >/dev/null 2>&1 || true
                passwd -u "$nick" >/dev/null 2>&1 || true
            fi
        done < "${XRAYTOOLS_DIR}/users.db"
        echo -e "${TXT_GREEN}✅ Contas locais Linux sincronizadas com o banco.${RESET}"
    fi

    echo -e "${TXT_GREEN}✅ Sistema restaurado!${RESET}"
    echo "-----------------------------------------"
    echo -e " Xray:    ${local_xray_status}"
    [ -n "$local_bot_status" ] && echo -e " Bot TG:  ${local_bot_status}"
    if ! systemctl is-active --quiet xray 2>/dev/null; then
        echo ""
        echo -e "${TXT_YELLOW}Últimas linhas do journal:${RESET}"
        journalctl -u xray -n 10 --no-pager 2>/dev/null || true
        if [ -n "${_SNAP_FILE:-}" ] && [ -f "$_SNAP_FILE" ]; then
            echo ""
            echo -e "${TXT_YELLOW}Snapshot disponível para recuperação manual: ${_SNAP_FILE}${RESET}"
        fi
    else
        _SNAP_REMOVE_OK=1
    fi
    echo "-----------------------------------------"
    ;;

  0) exit 0 ;;
  *) echo -e "${TXT_RED}❌ Opção inválida.${RESET}" ;;
esac

read -rp "Enter..."
