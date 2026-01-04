import os
import json
import uuid
import logging
import subprocess
import asyncio
from datetime import datetime, timedelta
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, ContextTypes, ConversationHandler,
    MessageHandler, filters, CallbackQueryHandler
)
import io

# --- CONFIGURAÇÃO ---
# (O instalador vai preencher isso automaticamente, ou você edita aqui)
BOT_TOKEN = "SEU_TOKEN_AQUI"
ADMIN_ID = 123456789  # Seu ID numérico

# Caminhos do DragonCore
CONFIG_PATH = "/usr/local/etc/xray/config.json"
USER_DB = "/opt/XrayTools/users.db"
XRAY_SERVICE = "xray"

# Configuração de Log
logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

# Estados da Conversa
(SELECTING_ACTION, GET_USERNAME_CREATE, GET_EXPIRY_DAYS_CREATE, GET_USER_TO_DELETE) = range(4)

# --- FUNÇÕES DE SISTEMA (BACKEND) ---

def restart_xray():
    subprocess.run(["systemctl", "restart", XRAY_SERVICE], check=False)

def load_config():
    if not os.path.exists(CONFIG_PATH): return None
    with open(CONFIG_PATH, 'r') as f:
        return json.load(f)

def save_config(data):
    with open(CONFIG_PATH, 'w') as f:
        json.dump(data, f, indent=2)

def core_create_user(nick, days):
    # 1. Validações
    if not os.path.exists(USER_DB): open(USER_DB, 'a').close()
    
    # Verifica se já existe no DB
    with open(USER_DB, 'r') as f:
        if nick in f.read():
            return False, "Usuário já existe!"

    # 2. Gera UUID e Data
    user_uuid = str(uuid.uuid4())
    expiry_date = (datetime.now() + timedelta(days=int(days))).strftime('%Y-%m-%d')

    # 3. Adiciona no config.json
    data = load_config()
    if not data: return False, "Erro ao ler config.json"

    # Encontra a inbound correta
    inbounds = data.get('inbounds', [])
    target_inbound = next((i for i in inbounds if i.get('tag') == 'inbound-dragoncore'), None)
    
    if target_inbound:
        clients = target_inbound['settings']['clients']
        clients.append({"id": user_uuid, "email": nick, "level": 0})
        save_config(data)
    else:
        return False, "Inbound DragonCore não encontrada."

    # 4. Adiciona no users.db
    with open(USER_DB, 'a') as f:
        f.write(f"{nick}|{user_uuid}|{expiry_date}\n")

    restart_xray()
    return True, f"✅ *Usuário Criado!*\n\n👤 User: `{nick}`\n🔑 UUID: `{user_uuid}`\n📅 Expira: `{expiry_date}`"

def core_delete_user(nick):
    # 1. Remove do config.json
    data = load_config()
    if data:
        inbounds = data.get('inbounds', [])
        for inbound in inbounds:
            if inbound.get('tag') == 'inbound-dragoncore':
                clients = inbound['settings']['clients']
                # Filtra removendo o usuário (por email ou id)
                inbound['settings']['clients'] = [c for c in clients if c.get('email') != nick and c.get('id') != nick]
        save_config(data)

    # 2. Remove do users.db
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f:
            lines = f.readlines()
        with open(USER_DB, 'w') as f:
            found = False
            for line in lines:
                if line.startswith(f"{nick}|"):
                    found = True
                else:
                    f.write(line)
    
    restart_xray()
    return "✅ Usuário removido com sucesso."

def core_list_users():
    if not os.path.exists(USER_DB): return "Nenhum usuário."
    msg = "📋 *LISTA DE USUÁRIOS*\n\n"
    with open(USER_DB, 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 3:
                msg += f"👤 `{parts[0]}` | 📅 {parts[2]}\n"
    return msg

# --- FUNÇÕES DO TELEGRAM ---

def is_admin(update: Update) -> bool:
    user = update.effective_user
    if user.id != ADMIN_ID:
        return False
    return True

def build_menu():
    keyboard = [
        [InlineKeyboardButton("👤 CRIAR USUÁRIO", callback_data='create_start'),
         InlineKeyboardButton("🗑️ REMOVER USUÁRIO", callback_data='delete_start')],
        [InlineKeyboardButton("📋 LISTAR TODOS", callback_data='list_users'),
         InlineKeyboardButton("❌ CANCELAR", callback_data='cancel')]
    ]
    return InlineKeyboardMarkup(keyboard)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    await update.message.reply_text("🐉 *DRAGONCORE BOT*\nBem-vindo ao gerenciador via Telegram.", reply_markup=build_menu(), parse_mode='Markdown')
    return SELECTING_ACTION

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    if query.data == 'create_start':
        await query.edit_message_text("Digite o *NOME* do novo usuário:", parse_mode='Markdown')
        return GET_USERNAME_CREATE
    
    elif query.data == 'delete_start':
        await query.edit_message_text("Digite o *NOME* ou *UUID* para remover:", parse_mode='Markdown')
        return GET_USER_TO_DELETE
    
    elif query.data == 'list_users':
        report = core_list_users()
        # Se for muito grande, envia arquivo, senão envia texto
        if len(report) > 4000:
            file_obj = io.BytesIO(report.encode())
            file_obj.name = "usuarios.txt"
            await context.bot.send_document(chat_id=ADMIN_ID, document=file_obj)
        else:
            await query.edit_message_text(report, parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION

    elif query.data == 'cancel':
        await query.edit_message_text("Operação cancelada.", reply_markup=build_menu())
        return SELECTING_ACTION

async def get_username_create(update: Update, context: ContextTypes.DEFAULT_TYPE):
    nick = update.message.text.strip()
    # Validação simples
    nick = ''.join(e for e in nick if e.isalnum())
    context.user_data['new_nick'] = nick
    await update.message.reply_text(f"Nome: `{nick}`\nAgora digite a *VALIDADE* em dias (Ex: 30):", parse_mode='Markdown')
    return GET_EXPIRY_DAYS_CREATE

async def get_expiry_days_create(update: Update, context: ContextTypes.DEFAULT_TYPE):
    days = update.message.text.strip()
    if not days.isdigit():
        await update.message.reply_text("Por favor, digite apenas números.")
        return GET_EXPIRY_DAYS_CREATE
    
    nick = context.user_data['new_nick']
    await update.message.reply_text("⏳ Criando usuário...")
    
    success, msg = core_create_user(nick, days)
    
    await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu())
    return SELECTING_ACTION

async def get_user_to_delete(update: Update, context: ContextTypes.DEFAULT_TYPE):
    target = update.message.text.strip()
    await update.message.reply_text("⏳ Removendo...")
    msg = core_delete_user(target)
    await update.message.reply_text(msg, reply_markup=build_menu())
    return SELECTING_ACTION

async def cancel_op(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Cancelado.", reply_markup=build_menu())
    return SELECTING_ACTION

def main():
    # Cria a aplicação
    application = Application.builder().token(BOT_TOKEN).build()

    conv_handler = ConversationHandler(
        entry_points=[CommandHandler('start', start), CommandHandler('menu', start)],
        states={
            SELECTING_ACTION: [CallbackQueryHandler(button_handler)],
            GET_USERNAME_CREATE: [MessageHandler(filters.TEXT & ~filters.COMMAND, get_username_create)],
            GET_EXPIRY_DAYS_CREATE: [MessageHandler(filters.TEXT & ~filters.COMMAND, get_expiry_days_create)],
            GET_USER_TO_DELETE: [MessageHandler(filters.TEXT & ~filters.COMMAND, get_user_to_delete)],
        },
        fallbacks=[CommandHandler('cancel', cancel_op)]
    )

    application.add_handler(conv_handler)
    print("Bot Iniciado...")
    application.run_polling()

if __name__ == '__main__':
    main()
