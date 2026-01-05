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
BOT_TOKEN = "SEU_TOKEN_AQUI"
ADMIN_ID = 123456789 

CONFIG_PATH = "/usr/local/etc/xray/config.json"
USER_DB = "/opt/XrayTools/users.db"
XRAY_SERVICE = "xray"

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

# Estados da Conversa
(SELECTING_ACTION, GET_USERNAME_CREATE, GET_EXPIRY_DAYS_CREATE, GET_USER_TO_DELETE, GET_USER_TO_BLOCK, GET_USER_TO_UNBLOCK) = range(6)

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
    if not os.path.exists(USER_DB): open(USER_DB, 'a').close()
    with open(USER_DB, 'r') as f:
        if nick in f.read(): return False, "Usuário já existe!"
    
    user_uuid = str(uuid.uuid4())
    expiry_date = (datetime.now() + timedelta(days=int(days))).strftime('%Y-%m-%d')
    data = load_config()
    
    inbounds = data.get('inbounds', [])
    target = next((i for i in inbounds if i.get('tag') == 'inbound-dragoncore'), None)
    if target:
        target['settings']['clients'].append({"id": user_uuid, "email": nick, "level": 0})
        save_config(data)
    
    with open(USER_DB, 'a') as f:
        f.write(f"{nick}|{user_uuid}|{expiry_date}\n")
    
    restart_xray()
    return True, f"✅ *Usuário Criado!*\n\n👤 `{nick}`\n🔑 `{user_uuid}`\n📅 `{expiry_date}`"

def core_delete_user(nick):
    data = load_config()
    if data:
        inbounds = data.get('inbounds', [])
        for inbound in inbounds:
            if inbound.get('tag') == 'inbound-dragoncore':
                clients = inbound['settings']['clients']
                inbound['settings']['clients'] = [c for c in clients if c.get('email') != nick]
        save_config(data)
    
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f: lines = f.readlines()
        with open(USER_DB, 'w') as f:
            for line in lines:
                if not line.startswith(f"{nick}|"): f.write(line)
    restart_xray()
    return "✅ Usuário removido."

def core_block_user(nick):
    # 1. Remove do Config (Derruba conexão)
    data = load_config()
    if data:
        inbounds = data.get('inbounds', [])
        for inbound in inbounds:
            if inbound.get('tag') == 'inbound-dragoncore':
                clients = inbound['settings']['clients']
                inbound['settings']['clients'] = [c for c in clients if c.get('email') != nick]
        save_config(data)
    
    # 2. Marca como BLOCKED no DB
    found = False
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f: lines = f.readlines()
        with open(USER_DB, 'w') as f:
            for line in lines:
                if line.startswith(f"{nick}|") and "BLOCKED-" not in line:
                    parts = line.strip().split('|')
                    # Formato: nick|BLOCKED-uuid|data
                    f.write(f"{parts[0]}|BLOCKED-{parts[1]}|{parts[2]}\n")
                    found = True
                else:
                    f.write(line)
    
    if not found: return "❌ Usuário não encontrado ou já bloqueado."
    restart_xray()
    return f"⛔ Usuário `{nick}` foi SUSPENSO."

def core_unblock_user(nick):
    real_uuid = ""
    # 1. Remove BLOCKED do DB e pega o UUID real
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f: lines = f.readlines()
        with open(USER_DB, 'w') as f:
            for line in lines:
                if line.startswith(f"{nick}|") and "BLOCKED-" in line:
                    parts = line.strip().split('|')
                    # Remove 'BLOCKED-' do UUID (parts[1])
                    clean_uuid = parts[1].replace("BLOCKED-", "")
                    real_uuid = clean_uuid
                    f.write(f"{parts[0]}|{clean_uuid}|{parts[2]}\n")
                else:
                    f.write(line)
    
    if not real_uuid: return "❌ Usuário não estava bloqueado."

    # 2. Adiciona de volta no Config
    data = load_config()
    inbounds = data.get('inbounds', [])
    target = next((i for i in inbounds if i.get('tag') == 'inbound-dragoncore'), None)
    if target:
        target['settings']['clients'].append({"id": real_uuid, "email": nick, "level": 0})
        save_config(data)
    
    restart_xray()
    return f"✅ Usuário `{nick}` foi REATIVADO."

def core_list_users():
    if not os.path.exists(USER_DB): return "Nenhum usuário."
    msg = "📋 *LISTA DE USUÁRIOS*\n_(Nome | Vencimento | Status)_\n\n"
    with open(USER_DB, 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 3:
                status = "✅ Ativo"
                if "BLOCKED-" in parts[1]: status = "⛔ SUSPENSO"
                msg += f"`{parts[0]}` | {parts[2]} | {status}\n"
    return msg

# --- FUNÇÕES DO TELEGRAM ---

def is_admin(update: Update) -> bool:
    if update.effective_user.id != ADMIN_ID: return False
    return True

def build_menu():
    keyboard = [
        [InlineKeyboardButton("👤 CRIAR", callback_data='create_start'),
         InlineKeyboardButton("🗑️ REMOVER", callback_data='delete_start')],
        [InlineKeyboardButton("⛔ SUSPENDER", callback_data='block_start'),
         InlineKeyboardButton("✅ REATIVAR", callback_data='unblock_start')],
        [InlineKeyboardButton("📋 LISTAR", callback_data='list_users'),
         InlineKeyboardButton("📥 BACKUP", callback_data='backup_start')],
        [InlineKeyboardButton("❌ SAIR", callback_data='cancel')]
    ]
    return InlineKeyboardMarkup(keyboard)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    await update.message.reply_text("🐉 *PAINEL DRAGONCORE*", reply_markup=build_menu(), parse_mode='Markdown')
    return SELECTING_ACTION

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    if query.data == 'create_start':
        await query.edit_message_text("Nome do usuário:", parse_mode='Markdown'); return GET_USERNAME_CREATE
    elif query.data == 'delete_start':
        await query.edit_message_text("Nome para remover:", parse_mode='Markdown'); return GET_USER_TO_DELETE
    elif query.data == 'block_start':
        await query.edit_message_text("Nome para ⛔ SUSPENDER:", parse_mode='Markdown'); return GET_USER_TO_BLOCK
    elif query.data == 'unblock_start':
        await query.edit_message_text("Nome para ✅ REATIVAR:", parse_mode='Markdown'); return GET_USER_TO_UNBLOCK
    elif query.data == 'list_users':
        report = core_list_users()
        if len(report) > 4000:
            f = io.BytesIO(report.encode()); f.name = "users.txt"
            await context.bot.send_document(chat_id=ADMIN_ID, document=f)
        else:
            await query.edit_message_text(report, parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION
    elif query.data == 'backup_start':
        await query.message.reply_text("📦 Gerando Backup...")
        date_str = datetime.now().strftime('%Y%m%d_%H%M')
        bkp_file = f"/tmp/backup_{date_str}.tar.gz"
        subprocess.run(f"tar -czPf {bkp_file} /opt/XrayTools /usr/local/etc/xray", shell=True)
        if os.path.exists(bkp_file):
            with open(bkp_file, 'rb') as f:
                await context.bot.send_document(chat_id=ADMIN_ID, document=f, filename=os.path.basename(bkp_file))
            os.remove(bkp_file)
            await query.message.reply_text("✅ Enviado!", reply_markup=build_menu())
        return SELECTING_ACTION
    elif query.data == 'cancel':
        await query.edit_message_text("Fim.", reply_markup=build_menu()); return SELECTING_ACTION

async def input_handler(update: Update, context: ContextTypes.DEFAULT_TYPE, mode):
    text = update.message.text.strip().split()[0] # Pega só a primeira palavra
    if mode == 'create_nick':
        context.user_data['nick'] = text
        await update.message.reply_text(f"Validade (dias) para `{text}`:", parse_mode='Markdown'); return GET_EXPIRY_DAYS_CREATE
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

# Wrappers
async def h_create_nick(u, c): return await input_handler(u, c, 'create_nick')
async def h_create_days(u, c): return await input_handler(u, c, 'create_days')
async def h_delete(u, c): return await input_handler(u, c, 'delete')
async def h_block(u, c): return await input_handler(u, c, 'block')
async def h_unblock(u, c): return await input_handler(u, c, 'unblock')
async def cancel_op(u, c): await u.message.reply_text("Cancelado.", reply_markup=build_menu()); return SELECTING_ACTION

def main():
    app = Application.builder().token(BOT_TOKEN).build()
    conv = ConversationHandler(
        entry_points=[CommandHandler('start', start), CommandHandler('menu', start)],
        states={
            SELECTING_ACTION: [CallbackQueryHandler(button_handler)],
            GET_USERNAME_CREATE: [MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_nick)],
            GET_EXPIRY_DAYS_CREATE: [MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_days)],
            GET_USER_TO_DELETE: [MessageHandler(filters.TEXT & ~filters.COMMAND, h_delete)],
            GET_USER_TO_BLOCK: [MessageHandler(filters.TEXT & ~filters.COMMAND, h_block)],
            GET_USER_TO_UNBLOCK: [MessageHandler(filters.TEXT & ~filters.COMMAND, h_unblock)],
        },
        fallbacks=[CommandHandler('cancel', cancel_op)]
    )
    app.add_handler(conv)
    print("Bot Iniciado...")
    app.run_polling()

if __name__ == '__main__':
    main()
