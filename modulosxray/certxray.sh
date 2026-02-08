#!/bin/bash
# certxray.sh - VERSÃO CLÁSSICA (Visual Original + Permissões SEGURAS)

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO";' ERR

# --- CORREÇÃO DE INPUT (Evita erro se digitar 'bash certxray.sh') ---
RAW_INPUT="$*"
DOMAIN="$(echo "$RAW_INPUT" | awk '{print $NF}')"

SSL_DIR="/opt/DragonCoreSSL"
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"

# --- CORES ---
YB='\033[1;33m'
RB='\033[1;31m'
BG_RED='\033[41;1;37m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

validate_domain_strict() {
  local d="${1:-}"
  # domínio básico: letras/números/ponto/hífen (sem barras, sem espaços)
  [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$d" == *.* ]] || return 1
  return 0
}

ensure_cmd() {
  local cmd="$1" pkg="$2"
  command -v "$cmd" >/dev/null 2>&1 || {
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "$pkg" >/dev/null 2>&1
  }
}

ensure_perms() {
  # Cria grupo xray se não existir (comum em instalações)
  getent group xray >/dev/null 2>&1 || groupadd --system xray >/dev/null 2>&1 || true

  mkdir -p "$SSL_DIR"
  chown root:root "$SSL_DIR"
  chmod 777 "$SSL_DIR"

  # arquivos: root:xray
  if [ -f "$SSL_DIR/fullchain.pem" ]; then
    chown root:xray "$SSL_DIR/fullchain.pem" || true
    chmod 777 "$SSL_DIR/fullchain.pem" || true
  fi
  if [ -f "$SSL_DIR/privkey.pem" ]; then
    chown root:xray "$SSL_DIR/privkey.pem" || true
    chmod 777 "$SSL_DIR/privkey.pem" || true
  fi
}

# Se não recebeu domínio por argumento, pede agora
if [ -z "${DOMAIN:-}" ]; then
  echo -e "${RB}Erro: Nenhum domínio recebido.${RESET}"
  read -rp "Digite o domínio manualmente: " DOMAIN
fi

if ! validate_domain_strict "$DOMAIN"; then
  echo -e "${RB}Domínio inválido.${RESET} Use algo como: exemplo.com"
  exit 1
fi

LE_DIR="/etc/letsencrypt/live/$DOMAIN"

clear
echo -e "${YB}====================================================${RESET}"
echo -e "${YB}            GERENCIADOR DE CERTIFICADOS SSL          ${RESET}"
echo -e "${YB}====================================================${RESET}"
echo ""
echo -e "${YB}DOMÍNIO ALVO: $DOMAIN${RESET}"
echo ""
echo -e "${YB}ESCOLHA O TIPO DE CERTIFICADO:${RESET}"
echo ""
echo -e "${YB} [1] CERTIFICADO OFICIAL LET'S ENCRYPT (Cadeado)${RESET}"
echo -e "${RB}     ⚠️  REQ 1: PORTA 80 DEVE ESTAR LIVRE NA VPS${RESET}"
echo -e "${RB}     ⚠️  REQ 2: PORTA 80 DEVE ESTAR ABERTA NO FIREWALL (ORACLE/AWS)${RESET}"
echo ""
echo -e "${YB} [2] CERTIFICADO AUTO-ASSINADO (LOCAL)${RESET}"
echo -e "${YB}     ✅  Não precisa de porta 80 / Instalação Rápida${RESET}"
echo ""
echo -e "${YB}====================================================${RESET}"
echo ""
read -rp "OPÇÃO: " cert_opt

# Limpa certificados antigos
rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem"

case "${cert_opt:-}" in
  1)
    clear
    echo -e "${BG_RED}                ⚠️  LEIA COM ATENÇÃO  ⚠️                ${RESET}"
    echo ""
    echo -e "${YB}Você escolheu LET'S ENCRYPT. Para funcionar:${RESET}"
    echo ""
    echo -e "1. ${RB}PORTA 80 LIVRE:${RESET} O script vai parar serviços temporariamente."
    echo -e "2. ${RB}PORTA 80 ABERTA:${RESET} Se usa Oracle Cloud, abra a porta 80."
    echo ""
    read -rp "Pressione [ENTER] se você confirma os requisitos..." _

    ensure_cmd certbot certbot
    ensure_cmd fuser psmisc
    ensure_cmd openssl openssl

    # Guarda status atual para restaurar
    XRAY_WAS_ACTIVE=0
    NGINX_WAS_ACTIVE=0
    systemctl is-active --quiet xray  && XRAY_WAS_ACTIVE=1 || true
    systemctl is-active --quiet nginx && NGINX_WAS_ACTIVE=1 || true

    echo "Parando serviços que usam a porta 80..."
    systemctl stop xray  >/dev/null 2>&1 || true
    systemctl stop nginx >/dev/null 2>&1 || true
    fuser -k 80/tcp >/dev/null 2>&1 || true
    sleep 2

    echo -e "${YB}>>> GERANDO CERTIFICADO (Aguarde)...${RESET}"
    certbot certonly --standalone -d "$DOMAIN" \
      --register-unsafely-without-email \
      --agree-tos --non-interactive

    if [ -s "$LE_DIR/fullchain.pem" ] && [ -s "$LE_DIR/privkey.pem" ]; then
      cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
      cp -f "$LE_DIR/privkey.pem"   "$SSL_DIR/privkey.pem"
      ensure_perms

      # Script de renovação (semanal é mais resiliente)
      cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
set -Eeuo pipefail
systemctl stop xray >/dev/null 2>&1 || true
systemctl stop nginx >/dev/null 2>&1 || true
fuser -k 80/tcp >/dev/null 2>&1 || true
certbot renew --quiet
cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
cp -f "$LE_DIR/privkey.pem"   "$SSL_DIR/privkey.pem"
chown root:root "$SSL_DIR" || true
chmod 777 "$SSL_DIR" || true
chown root:xray "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" || true
chmod 777 "$SSL_DIR/fullchain.pem" || true
chmod 777 "$SSL_DIR/privkey.pem" || true
systemctl restart xray >/dev/null 2>&1 || true
systemctl start nginx >/dev/null 2>&1 || true
EOF
      chmod 777 "$RENEW_SCRIPT"

      (crontab -l 2>/dev/null | grep -v "renew_cert.sh" || true
       echo "0 3 */7 * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -

      echo -e "${YB}✅ SUCESSO! Certificado Let's Encrypt Instalado.${RESET}"
    else
      echo ""
      echo -e "${BG_RED}  FALHA NA VALIDAÇÃO  ${RESET}"
      echo -e "${RB}Não foi possível gerar o certificado oficial.${RESET}"
      echo "Motivo provável: Porta 80 fechada ou domínio apontando errado."
      echo ""
      echo -e "${YB}>>> Instalando Auto-assinado de emergência...${RESET}"

      ensure_cmd openssl openssl
      openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1

      ensure_perms
    fi

    # Restaura serviços
    [ "$XRAY_WAS_ACTIVE" -eq 1 ] && systemctl restart xray >/dev/null 2>&1 || true
    [ "$NGINX_WAS_ACTIVE" -eq 1 ] && systemctl start nginx >/dev/null 2>&1 || true
    ;;

  *)
    echo "Gerando Auto-assinado (Local)..."
    ensure_cmd openssl openssl

    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
      -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1

    ensure_perms
    echo -e "${YB}✅ Certificado Auto-assinado criado.${RESET}"
    ;;
esac

echo ""
read -rp "Pressione Enter para voltar..."
