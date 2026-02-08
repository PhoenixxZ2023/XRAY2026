#!/bin/bash
# botxray.sh - Instalação do Bot Telegram (DragonCore V7.5)
# MANTIDO: Lógica original de verificação e biblioteca Async.
# MELHORADO: O código Python agora é gerado localmente com suporte a VLESS Vision.

# --- CORES ---
VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}      🤖 CONFIGURAÇÃO DO BOT TELEGRAM 🤖       ${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""

# 1. Pré-Verificação de Dependências
echo "Verificando ambiente..."
if ! command -v python3 &> /dev/null; then
    echo -e "${AMARELO}Instalando Python3...${RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y > /dev/null 2>&1
    apt-get install python3 python3-pip -y > /dev/null 2>&1
fi

# Instala a biblioteca ASYNC (python-telegram-bot) que seu código usa
pip3 install python-telegram-bot --break-system-packages > /dev/null 2>&1
pip3 install requests --break-system-packages > /dev/null 2>&1

echo -e "${VERDE}Dependências verificadas.${RESET}"
echo ""

read -rp "Deseja continuar? [s/n]: " continue_opt
if [[ "$continue_opt" != "s" ]]; then echo "Cancelado."; exit 0; fi

# --- PASSO 1: DADOS TÉCNICOS ---
echo ""
echo -e "${AMARELO}1. Digite o Token do BotFather:${RESET}"
read -rp "Token: " bot_token

echo ""
echo -e "${AMARELO}2. Digite o SEU ID Numérico (Admin):${RESET}"
echo "Exemplo: 123456789"
read -rp "ID Admin: " admin_id

if [ -z "$bot_token" ] || [ -z "$admin_id" ]; then
    echo -e "${VERMELHO}❌ Dados incompletos!${RESET}"; sleep 2; exit 1
fi

# --- VALIDAÇÃO API (SEU CÓDIGO ORIGINAL) ---
echo ""
echo "Consultando dados..."

if ! command -v jq &> /dev/null; then apt-get install jq -y > /dev/null 2>&1; fi

api_response=$(curl -s "https://api.telegram.org/bot$bot_token/getChat?chat_id=$admin_id")
is_ok=$(echo "$api_response" | jq -r '.ok')

if [ "$is_ok" != "true" ]; then
    echo -e "${VERMELHO}❌ ERRO: O Token ou ID informados são inválidos.${RESET}"
    echo "Detalhe: $(echo "$api_response" | jq -r '.description')"
    read -rp "Enter para voltar..."
    exit 1
fi

real_username=$(echo "$api_response" | jq -r '.result.username')

if [ "$real_username" == "null" ]; then
    echo -e "${AMARELO}⚠️  ERRO: O ID $admin_id não tem Username (@) definido no Telegram.${RESET}"
    echo "Configure um username no seu perfil e tente novamente."
    read -rp "Enter para voltar..."
    exit 1
fi

# --- LOOP DE VALIDAÇÃO (SEU CÓDIGO ORIGINAL) ---
while true; do
    echo ""
    echo "-------------------------------------------------------"
    echo -e "${AMARELO}3. Confirmação de Segurança:${RESET}"
    echo "Para validar que o ID $admin_id é realmente seu,"
    echo "digite o seu Username do Telegram (sem @)."
    echo "-------------------------------------------------------"
    read -rp "Username: " input_user

    if [ "$input_user" == "0" ]; then exit 0; fi

    input_user=$(echo "$input_user" | sed 's/@//g' | sed 's/ //g')

    if [[ "${real_username,,}" == "${input_user,,}" ]]; then
        echo ""
        echo -e "${VERDE}✅ IDENTIDADE CONFIRMADA!${RESET}"
        sleep 1
        break
    else
        echo ""
        echo -e "${VERMELHO}❌ INCORRETO!${RESET}"
        echo "O usuário digitado não corresponde ao dono do ID informado."
    fi
done

# --- INSTALAÇÃO DO ARQUIVO PYTHON ---
echo ""
echo "Configurando bot..."
mkdir -p /opt/XrayTools
rm -f /opt/XrayTools/botxray.py

# AQUI ESTÁ A MUDANÇA: Em vez de baixar o antigo, escrevemos o NOVO código Python
# com a função generate_link e suporte a Vision.

cat << 'END_PYTHON' > /opt/XrayTools/botxray.py
import os
import json
import uuid
import logging
import subprocess
import asyncio
import re
from datetime import datetime, timedelta
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, ContextTypes, ConversationHandler,
    MessageHandler, filters, CallbackQueryHandler
)
import io

# --- CONFIGURAÇÃO (SERÁ SUBSTITUÍDA PELO SED) ---
BOT_TOKEN = "SEU_TOKEN_AQUI"
ADMIN_ID = 123456789 

CONFIG_PATH = "/usr/local/etc/xray/config.json"
USER_DB = "/opt/XrayTools/users.db"
XRAY_SERVICE = "xray"

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

(SELECTING_ACTION, GET_USERNAME_CREATE, GET_EXPIRY_DAYS_CREATE, GET_USER_TO_DELETE, GET_USER_TO_BLOCK, GET_USER_TO_UNBLOCK) = range(6)

def restart_xray():
    subprocess.run(["systemctl", "restart", XRAY_SERVICE], check=False)

def load_config():
    if not os.path.exists(CONFIG_PATH): return None
    with open(CONFIG_PATH, 'r') as f:
        return json.load(f)

def save_config(data):
    with open(CONFIG_PATH, 'w') as f:
        json.dump(data, f, indent=2)

def get_ip():
    try:
        return subprocess.check_output("curl -s ifconfig.me", shell=True).decode().strip()
    except:
        return "127.0.0.1"

# --- GERADOR DE LINK MELHORADO ---
def generate_link(client_uuid, client_email):
    try:
        data = load_config()
        if not data: return "Erro Config"
        
        inbound = next((i for i in data['inbounds'] if i.get('tag') == 'inbound-dragoncore'), data['inbounds'][0])
        
        port = inbound['port']
        stream = inbound['streamSettings']
        network = stream['network']
        security = stream['security']
        
        host = ""
        sni = ""
        if security == 'tls':
            tls = stream.get('tlsSettings', {})
            sni = tls.get('serverName', "")
            host = sni
        
        if not host:
            host = get_ip()
            sni = "" 

        link = ""
        if network == "tcp":
            settings = inbound.get('settings', {})
            flow = settings.get('flow', "")
            if flow == "xtls-rprx-vision":
                link = f"vless://{client_uuid}@{host}:{port}?security=tls&encryption=none&type=tcp&headerType=none&flow={flow}&sni={sni}#{client_email}"
            else:
                sec_param = "security=tls" if security == "tls" else "security=none"
                link = f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=tcp&headerType=none&sni={sni}#{client_email}"
        elif network == "ws":
            path = stream['wsSettings'].get('path', '/')
            sec_param = "security=tls" if security == "tls" else "security=none"
            ws_host = sni if sni else host
            link = f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=ws&host={ws_host}&path={path}&sni={sni}#{client_email}"
        elif network == "grpc":
            service = stream['grpcSettings'].get('serviceName', 'gRPC')
            sec_param = "security=tls" if security == "tls" else "security=none"
            link = f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=grpc&serviceName={service}&sni={sni}#{client_email}"
        elif network == "xhttp":
            path = stream['xhttpSettings'].get('path', '/')
            sec_param = "security=tls" if security == "tls" else "security=none"
            link = f"vless://{client_uuid}@{host}:{port}?mode=auto&{sec_param}&encryption=none&type=xhttp&host={host}&path={path}&sni={sni}#{client_email}"
        
        return link
    except Exception as e:
        return f"Erro Link: {str(e)}"

# --- CORE FUNCTIONS ---
def core_create_user(nick, days):
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f:
            if f"{nick}|" in f.read(): return False, "❌ Usuário já existe!"
    else:
        open(USER_DB, 'a').close()
    
    user_uuid = str(uuid.uuid4())
    expiry_date = (datetime.now() + timedelta(days=int(days))).strftime('%Y-%m-%d')
    data = load_config()
    
    if not data: return False, "❌ Erro ao ler config.json"

    inbounds = data.get('inbounds', [])
    target = next((i for i in inbounds if i.get('tag') == 'inbound-dragoncore'), None)
    
    if target:
        target['settings']['clients'].append({"id": user_uuid, "email": nick, "level": 0})
        save_config(data)
        
        with open(USER_DB, 'a') as f:
            f.write(f"{nick}|{user_uuid}|{expiry_date}\n")
        
        restart_xray()
        
        # GERA O LINK
        link = generate_link(user_uuid, nick)
        
        return True, f"✅ *Usuário Criado!*\n\n👤 `{nick}`\n📅 `{expiry_date}`\n\n🔗 *Link VLESS:*\n`{link}`"
    return False, "❌ Inbound não encontrado."

def core_delete_user(nick):
    data = load_config()
    found = False
    if data:
        inbounds = data.get('inbounds', [])
        for inbound in inbounds:
            if inbound.get('tag') == 'inbound-dragoncore':
                clients = inbound['settings']['clients']
                new_clients = [c for c in clients if c.get('email') != nick and c.get('email') != f"LOCKED_{nick}"]
                if len(clients) != len(new_clients): found = True
                inbound['settings']['clients'] = new_clients
        save_config(data)
    
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f: lines = f.readlines()
        with open(USER_DB, 'w') as f:
            for line in lines:
                if not line.startswith(f"{nick}|"): f.write(line)
                else: found = True
    if not found: return "❌ Usuário não encontrado."
    restart_xray()
    return "✅ Usuário removido."

def core_block_user(nick):
    data = load_config()
    if not data: return "❌ Erro config."
    found = False
    inbounds = data.get('inbounds', [])
    for inbound in inbounds:
        if inbound.get('tag') == 'inbound-dragoncore':
            for client in inbound['settings']['clients']:
                if client.get('email') == f"LOCKED_{nick}": return "⚠️ Já bloqueado."
                if client.get('email') == nick:
                    client['email'] = f"LOCKED_{nick}"
                    client['id'] = str(uuid.uuid4())
                    found = True
                    break
    if found:
        save_config(data)
        restart_xray()
        return f"⛔ Usuário `{nick}` SUSPENSO."
    else: return "❌ Não encontrado."

def core_unblock_user(nick):
    real_uuid = None
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f:
            for line in f:
                if line.startswith(f"{nick}|"):
                    real_uuid = line.strip().split('|')[1]; break
    if not real_uuid: return "❌ Erro: UUID original não achado."
    
    data = load_config()
    found = False
    inbounds = data.get('inbounds', [])
    for inbound in inbounds:
        if inbound.get('tag') == 'inbound-dragoncore':
            for client in inbound['settings']['clients']:
                if client.get('email') == f"LOCKED_{nick}":
                    client['email'] = nick
                    client['id'] = real_uuid
                    found = True
                    break
    if found:
        save_config(data)
        restart_xray()
        return f"✅ Usuário `{nick}` REATIVADO."
    else: return "❌ Não estava bloqueado."

def core_list_users_text():
    if not os.path.exists(USER_DB): return "Vazio."
    data = load_config()
    locked_users = []
    if data:
        inbounds = data.get('inbounds', [])
        target = next((i for i in inbounds if i.get('tag') == 'inbound-dragoncore'), None)
        if target:
            for c in target['settings']['clients']:
                email = c.get('email', '')
                if email.startswith("LOCKED_"): locked_users.append(email.replace("LOCKED_", ""))
    msg = "LISTA DE USUÁRIOS\n=========================\n"
    with open(USER_DB, 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 3:
                status = "✅"
                if parts[0] in locked_users: status = "⛔️"
                msg += f"{parts[0]:<10} | {parts[2]:<10} | {status}\n"
    return msg

# --- TELEGRAM HANDLERS ---
def is_admin(update: Update) -> bool:
    return update.effective_user.id == ADMIN_ID

def build_menu():
    keyboard = [
        [InlineKeyboardButton("👤 CRIAR", callback_data='create_start'), InlineKeyboardButton("🗑️ REMOVER", callback_data='delete_start')],
        [InlineKeyboardButton("⛔ SUSPENDER", callback_data='block_start'), InlineKeyboardButton("✅ REATIVAR", callback_data='unblock_start')],
        [InlineKeyboardButton("📋 LISTAR (TXT)", callback_data='list_users'), InlineKeyboardButton("❌ SAIR", callback_data='cancel')]
    ]
    return InlineKeyboardMarkup(keyboard)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    context.user_data.clear()
    await update.message.reply_text("🐉 *PAINEL V7.6*", reply_markup=build_menu(), parse_mode='Markdown')
    return SELECTING_ACTION

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    query = update.callback_query
    await query.answer()
    if query.data == 'close_file': await query.message.delete(); return SELECTING_ACTION
    if query.data == 'cancel': await query.edit_message_text("Fechado.", reply_markup=None); return ConversationHandler.END
    
    if query.data == 'create_start': await query.edit_message_text("Nome:", parse_mode='Markdown'); return GET_USERNAME_CREATE
    elif query.data == 'delete_start': await query.edit_message_text("Nome para remover:", parse_mode='Markdown'); return GET_USER_TO_DELETE
    elif query.data == 'block_start': await query.edit_message_text("Nome p/ suspender:", parse_mode='Markdown'); return GET_USER_TO_BLOCK
    elif query.data == 'unblock_start': await query.edit_message_text("Nome p/ reativar:", parse_mode='Markdown'); return GET_USER_TO_UNBLOCK
    elif query.data == 'list_users':
        report = core_list_users_text()
        f = io.BytesIO(report.encode('utf-8')); f.name = "users.txt"
        await context.bot.send_document(chat_id=update.effective_chat.id, document=f, caption="📂 Lista", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🗑 Fechar", callback_data='close_file')]]))
        await query.edit_message_text("✅ Enviado.", reply_markup=build_menu()); return SELECTING_ACTION
    return SELECTING_ACTION

async def input_handler(update: Update, context: ContextTypes.DEFAULT_TYPE, mode):
    if not is_admin(update): return
    if not update.message or not update.message.text: return
    text = update.message.text.strip().split()[0]

    if mode == 'create_nick':
        if not re.match(r'^[a-zA-Z0-9]{3,15}$', text):
            await update.message.reply_text("❌ Inválido (Use letras/números). Tente outro:"); return GET_USERNAME_CREATE
        context.user_data['nick'] = text
        await update.message.reply_text(f"Dias para `{text}`:", parse_mode='Markdown'); return GET_EXPIRY_DAYS_CREATE
    elif mode == 'create_days':
        if not text.isdigit(): await update.message.reply_text("Só números."); return GET_EXPIRY_DAYS_CREATE
        res, msg = core_create_user(context.user_data['nick'], text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu()); return SELECTING_ACTION
    elif mode == 'delete':
        msg = core_delete_user(text)
        await update.message.reply_text(msg, reply_markup=build_menu()); return SELECTING_ACTION
    elif mode == 'block':
        msg = core_block_user(text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu()); return SELECTING_ACTION
    elif mode == 'unblock':
        msg = core_unblock_user(text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu()); return SELECTING_ACTION

async def h_unexpected(u, c): q = u.callback_query; await q.answer(); return await button_handler(u, c)

def main():
    app = Application.builder().token(BOT_TOKEN).build()
    conv = ConversationHandler(
        entry_points=[CommandHandler('start', start), CommandHandler('menu', start)],
        states={
            SELECTING_ACTION: [CallbackQueryHandler(button_handler)],
            GET_USERNAME_CREATE: [MessageHandler(filters.TEXT & ~filters.COMMAND, lambda u,c: input_handler(u,c,'create_nick')), CallbackQueryHandler(h_unexpected)],
            GET_EXPIRY_DAYS_CREATE: [MessageHandler(filters.TEXT & ~filters.COMMAND, lambda u,c: input_handler(u,c,'create_days')), CallbackQueryHandler(h_unexpected)],
            GET_USER_TO_DELETE: [MessageHandler(filters.TEXT & ~filters.COMMAND, lambda u,c: input_handler(u,c,'delete')), CallbackQueryHandler(h_unexpected)],
            GET_USER_TO_BLOCK: [MessageHandler(filters.TEXT & ~filters.COMMAND, lambda u,c: input_handler(u,c,'block')), CallbackQueryHandler(h_unexpected)],
            GET_USER_TO_UNBLOCK: [MessageHandler(filters.TEXT & ~filters.COMMAND, lambda u,c: input_handler(u,c,'unblock')), CallbackQueryHandler(h_unexpected)],
        },
        fallbacks=[CommandHandler('cancel', lambda u,c: input_handler(u,c,'cancel'))] # Simplificado
    )
    app.add_handler(conv)
    print("Bot Iniciado...")
    app.run_polling()

if __name__ == '__main__':
    main()
END_PYTHON

# --- SUBSTITUIÇÃO DE TOKEN (SEU CÓDIGO ORIGINAL) ---
sed -i "s|SEU_TOKEN_AQUI|$bot_token|g" /opt/XrayTools/botxray.py
sed -i "s|123456789|$admin_id|g" /opt/XrayTools/botxray.py

# --- CRIAÇÃO DO SERVIÇO ---
cat <<EOF > /etc/systemd/system/botxray.service
[Unit]
Description=DragonCore Telegram Bot
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/XrayTools
ExecStart=/usr/bin/python3 /opt/XrayTools/botxray.py
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable botxray
systemctl restart botxray

echo ""
echo -e "${VERDE}🤖 BOT ATIVADO COM SUCESSO!${RESET}"
echo "Vá no Telegram e digite /menu ou /start."
echo ""
read -rp "Pressione ENTER para voltar..."
