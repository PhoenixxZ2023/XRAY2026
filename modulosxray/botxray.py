"""
botxray.py - DragonCore V7.7
Baseado na versao original funcional.
Correcoes aplicadas:
- BOT_TOKEN e ADMIN_ID via os.environ (EnvironmentFile no systemd)
- load_config com try/except (nao crasha com JSON invalido)
- save_config com permissao correta (nobody:nogroup 0644)
- get_ip via HTTPS
- backup via tar sem shell=True e sem path absoluto (-P)
- core_create_user: verifica inbound antes de escrever no DB
- Validacao de dias (1-3650)
- Python 3.8+ compativel
"""

from __future__ import annotations

import os
import json
import uuid
import logging
import subprocess
import re
from datetime import datetime, timedelta
from typing import Optional

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, ContextTypes, ConversationHandler,
    MessageHandler, filters, CallbackQueryHandler
)
import io

# --- CONFIGURACAO VIA VARIAVEIS DE AMBIENTE ---
_token = os.environ.get("BOT_TOKEN", "")
_admin = os.environ.get("ADMIN_ID", "")

if not _token or not _admin:
    raise EnvironmentError(
        "BOT_TOKEN e ADMIN_ID devem estar definidos no EnvironmentFile.\n"
        "Verifique /opt/XrayTools/.bot_env"
    )

BOT_TOKEN: str = _token
try:
    ADMIN_ID: int = int(_admin)
except ValueError:
    raise EnvironmentError(f"ADMIN_ID deve ser inteiro, obtido: '{_admin}'")

CONFIG_PATH  = "/usr/local/etc/xray/config.json"
USER_DB      = "/opt/XrayTools/users.db"
XRAY_SERVICE = "xray"

MIN_DAYS = 1
MAX_DAYS = 3650

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

(
    SELECTING_ACTION,
    GET_USERNAME_CREATE,
    GET_EXPIRY_DAYS_CREATE,
    GET_USER_TO_DELETE,
    GET_USER_TO_BLOCK,
    GET_USER_TO_UNBLOCK,
) = range(6)


# ─────────────────────────────────────────────
# FUNCOES DE SISTEMA
# ─────────────────────────────────────────────

def restart_xray():
    subprocess.run(["systemctl", "restart", XRAY_SERVICE], check=False)


def load_config() -> Optional[dict]:
    if not os.path.exists(CONFIG_PATH):
        logger.warning("config.json nao encontrado: %s", CONFIG_PATH)
        return None
    try:
        with open(CONFIG_PATH, 'r', encoding='utf-8', errors='ignore') as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        logger.error("Erro ao ler config.json: %s", e)
        return None


def save_config(data: dict):
    """Salva config com permissao correta para que Xray (nobody) possa ler."""
    tmp_path = CONFIG_PATH + ".tmp"
    try:
        with open(tmp_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, CONFIG_PATH)
        # nobody:nogroup 0644 — Xray lê, outros não escrevem
        os.chmod(CONFIG_PATH, 0o644)
        try:
            import pwd, grp
            uid = pwd.getpwnam("nobody").pw_uid
            gid = grp.getgrnam("nogroup").gr_gid
            os.chown(CONFIG_PATH, uid, gid)
        except Exception:
            pass  # ignora se nao conseguir mudar dono
    except OSError as e:
        logger.error("Erro ao salvar config.json: %s", e)
        raise


def get_ip() -> str:
    """IP publico via HTTPS com fallback."""
    for url in ["https://icanhazip.com", "https://api.ipify.org"]:
        try:
            result = subprocess.check_output(
                ["curl", "-4", "-fsSL", "--max-time", "10", url],
                timeout=12
            ).decode().strip()
            if result:
                return result
        except Exception:
            continue
    return "127.0.0.1"


# ─────────────────────────────────────────────
# GERADOR DE LINKS
# ─────────────────────────────────────────────

def generate_link(client_uuid: str, client_email: str) -> str:
    try:
        data = load_config()
        if not data:
            return "Erro ao ler config."

        inbound = next(
            (i for i in data.get('inbounds', []) if i.get('tag') == 'inbound-dragoncore'),
            None
        )
        if not inbound:
            return "Erro: inbound-dragoncore nao encontrado."

        port     = inbound['port']
        stream   = inbound.get('streamSettings', {})
        network  = stream.get('network', 'tcp')
        security = stream.get('security', 'none')

        sni = host = ""
        if security == 'tls':
            sni  = stream.get('tlsSettings', {}).get('serverName', '') or ''
            host = sni
        if not host:
            host = get_ip()
            sni  = ""

        sec_param = "security=tls" if security == "tls" else "security=none"

        if network == "tcp":
            clients = inbound.get('settings', {}).get('clients', [])
            flow = next((c.get('flow', '') for c in clients if c.get('email') == client_email), '')
            if flow == "xtls-rprx-vision":
                return f"vless://{client_uuid}@{host}:{port}?security=tls&encryption=none&type=tcp&headerType=none&flow={flow}&sni={sni}#{client_email}"
            return f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=tcp&headerType=none&sni={sni}#{client_email}"

        if network == "ws":
            path    = stream.get('wsSettings', {}).get('path', '/')
            ws_host = sni if sni else host
            return f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=ws&host={ws_host}&path={path}&sni={sni}#{client_email}"

        if network == "grpc":
            service = stream.get('grpcSettings', {}).get('serviceName', 'gRPC')
            return f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=grpc&serviceName={service}&sni={sni}#{client_email}"

        if network == "xhttp":
            path = stream.get('xhttpSettings', {}).get('path', '/')
            return f"vless://{client_uuid}@{host}:{port}?mode=auto&{sec_param}&encryption=none&type=xhttp&host={host}&path={path}&sni={sni}#{client_email}"

        return f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type={network}&sni={sni}#{client_email}"

    except Exception as e:
        logger.exception("Erro em generate_link")
        return f"Erro Link: {e}"


# ─────────────────────────────────────────────
# FUNCOES CORE
# ─────────────────────────────────────────────

def core_create_user(nick: str, days: str):
    # Verifica duplicidade no DB
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r', encoding='utf-8', errors='ignore') as f:
            if f"{nick}|" in f.read():
                return False, "Usuario ja existe!"
    else:
        open(USER_DB, 'a').close()

    # Valida dias
    try:
        days_int = int(days)
        if not (MIN_DAYS <= days_int <= MAX_DAYS):
            return False, f"Dias deve ser entre {MIN_DAYS} e {MAX_DAYS}."
    except ValueError:
        return False, "Dias invalido."

    data = load_config()
    if not data:
        return False, "Erro ao ler config.json."

    target = next(
        (i for i in data.get('inbounds', []) if i.get('tag') == 'inbound-dragoncore'),
        None
    )
    if not target:
        return False, "Inbound nao encontrado."

    user_uuid    = str(uuid.uuid4())
    expiry_date  = (datetime.now() + timedelta(days=days_int)).strftime('%Y-%m-%d')

    # Garante que clients e uma lista
    if not isinstance(target['settings'].get('clients'), list):
        target['settings']['clients'] = []

    target['settings']['clients'].append({"id": user_uuid, "email": nick, "level": 0})

    try:
        save_config(data)
    except Exception as e:
        return False, f"Erro ao salvar config: {e}"

    # Grava no DB apenas apos config salvo
    with open(USER_DB, 'a', encoding='utf-8') as f:
        f.write(f"{nick}|{user_uuid}|{expiry_date}\n")

    restart_xray()

    link = generate_link(user_uuid, nick)
    return True, (
        f"*Usuario Criado!*\n\n"
        f"Nome: `{nick}`\nExpira: `{expiry_date}`\n\n"
        f"*Link VLESS:*\n`{link}`"
    )


def core_delete_user(nick: str) -> str:
    data    = load_config()
    found   = False

    if data:
        for inbound in data.get('inbounds', []):
            if inbound.get('tag') == 'inbound-dragoncore':
                clients     = inbound['settings']['clients']
                new_clients = [c for c in clients
                               if c.get('email') != nick and c.get('email') != f"LOCKED_{nick}"]
                if len(clients) != len(new_clients):
                    found = True
                inbound['settings']['clients'] = new_clients
        try:
            save_config(data)
        except Exception as e:
            return f"Erro ao salvar config: {e}"

    if os.path.exists(USER_DB):
        with open(USER_DB, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
        with open(USER_DB, 'w', encoding='utf-8') as f:
            for line in lines:
                if not line.startswith(f"{nick}|"):
                    f.write(line)
                else:
                    found = True

    if not found:
        return "Usuario nao encontrado."

    restart_xray()
    return f"Usuario `{nick}` removido com sucesso."


def core_block_user(nick: str) -> str:
    data = load_config()
    if not data:
        return "Erro config."

    for inbound in data.get('inbounds', []):
        if inbound.get('tag') == 'inbound-dragoncore':
            for client in inbound['settings']['clients']:
                if client.get('email') == f"LOCKED_{nick}":
                    return "Usuario ja esta bloqueado."
                if client.get('email') == nick:
                    client['email'] = f"LOCKED_{nick}"
                    client['id']    = str(uuid.uuid4())
                    try:
                        save_config(data)
                    except Exception as e:
                        return f"Erro ao salvar config: {e}"
                    restart_xray()
                    return f"Usuario `{nick}` SUSPENSO."

    return "Usuario nao encontrado no Config."


def core_unblock_user(nick: str) -> str:
    real_uuid = None
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                if line.startswith(f"{nick}|"):
                    parts = line.strip().split('|')
                    if len(parts) >= 2:
                        real_uuid = parts[1]
                    break

    if not real_uuid:
        return "Erro: UUID original nao encontrado no DB."

    data = load_config()
    if not data:
        return "Erro config."

    for inbound in data.get('inbounds', []):
        if inbound.get('tag') == 'inbound-dragoncore':
            for client in inbound['settings']['clients']:
                if client.get('email') == f"LOCKED_{nick}":
                    client['email'] = nick
                    client['id']    = real_uuid
                    try:
                        save_config(data)
                    except Exception as e:
                        return f"Erro ao salvar config: {e}"
                    restart_xray()
                    return f"Usuario `{nick}` REATIVADO com sucesso."

    return "Usuario nao estava bloqueado."


def core_list_users_text() -> str:
    if not os.path.exists(USER_DB):
        return "Nenhum usuario cadastrado."

    locked: set = set()
    data = load_config()
    if data:
        target = next(
            (i for i in data.get('inbounds', []) if i.get('tag') == 'inbound-dragoncore'),
            None
        )
        if target:
            for c in target['settings'].get('clients', []):
                email = c.get('email', '')
                if email.startswith("LOCKED_"):
                    locked.add(email.replace("LOCKED_", "", 1))

    msg  = "LISTA DE USUARIOS - DRAGONCORE\n"
    msg += "=" * 75 + "\n"
    msg += f"{'NOME':<15} | {'VENCIMENTO':<11} | {'UUID':<36} | STATUS\n"
    msg += "=" * 75 + "\n"

    try:
        with open(USER_DB, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                parts = line.strip().split('|')
                if len(parts) >= 3:
                    nick      = parts[0]
                    uuid_real = parts[1]
                    expiry    = parts[2]
                    status    = "BLOQUEADO" if nick in locked else "ATIVO"
                    msg += f"{nick:<15} | {expiry:<11} | {uuid_real:<36} | {status}\n"
    except OSError as e:
        msg += f"Erro ao ler DB: {e}\n"

    return msg


# ─────────────────────────────────────────────
# TELEGRAM
# ─────────────────────────────────────────────

def is_admin(update: Update) -> bool:
    return bool(update.effective_user and update.effective_user.id == ADMIN_ID)


def build_menu() -> InlineKeyboardMarkup:
    keyboard = [
        [InlineKeyboardButton("CRIAR",     callback_data='create_start'),
         InlineKeyboardButton("REMOVER",   callback_data='delete_start')],
        [InlineKeyboardButton("SUSPENDER", callback_data='block_start'),
         InlineKeyboardButton("REATIVAR",  callback_data='unblock_start')],
        [InlineKeyboardButton("LISTAR",    callback_data='list_users'),
         InlineKeyboardButton("BACKUP",    callback_data='backup_start')],
        [InlineKeyboardButton("SAIR",      callback_data='cancel')],
    ]
    return InlineKeyboardMarkup(keyboard)


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    context.user_data.clear()
    await update.message.reply_text(
        "*PAINEL DRAGONCORE V7.7*",
        reply_markup=build_menu(),
        parse_mode='Markdown'
    )
    return SELECTING_ACTION


async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    query = update.callback_query
    await query.answer()

    if query.data == 'close_file':
        try: await query.message.delete()
        except Exception: pass
        return SELECTING_ACTION

    if query.data == 'cancel':
        await query.edit_message_text("Painel Fechado.", reply_markup=None)
        return ConversationHandler.END

    if query.data == 'create_start':
        await query.edit_message_text("Nome do usuario (5-9 letras/numeros):")
        return GET_USERNAME_CREATE
    if query.data == 'delete_start':
        await query.edit_message_text("Nome para remover:")
        return GET_USER_TO_DELETE
    if query.data == 'block_start':
        await query.edit_message_text("Nome para SUSPENDER:")
        return GET_USER_TO_BLOCK
    if query.data == 'unblock_start':
        await query.edit_message_text("Nome para REATIVAR:")
        return GET_USER_TO_UNBLOCK

    if query.data == 'list_users':
        report = core_list_users_text()
        f = io.BytesIO(report.encode('utf-8'))
        f.name = "usuarios.txt"
        close_btn = InlineKeyboardMarkup([[InlineKeyboardButton("Fechar Lista", callback_data='close_file')]])
        await context.bot.send_document(
            chat_id=update.effective_chat.id,
            document=f,
            caption="Lista gerada",
            parse_mode='Markdown',
            reply_markup=close_btn
        )
        await query.edit_message_text(
            "Lista enviada! Escolha outra opcao:",
            parse_mode='Markdown',
            reply_markup=build_menu()
        )
        return SELECTING_ACTION

    if query.data == 'backup_start':
        await query.edit_message_text("Gerando Backup...")
        date_str = datetime.now().strftime('%Y%m%d_%H%M')
        bkp_file = f"/tmp/backup_{date_str}.tar.gz"
        # sem -P (sem paths absolutos) e sem shell=True
        result = subprocess.run(
            ["tar", "-czf", bkp_file,
             "-C", "/", "opt/XrayTools", "usr/local/etc/xray"],
            check=False, capture_output=True
        )
        if os.path.exists(bkp_file) and os.path.getsize(bkp_file) > 0:
            close_btn = InlineKeyboardMarkup([[InlineKeyboardButton("Fechar Backup", callback_data='close_file')]])
            with open(bkp_file, 'rb') as f:
                await context.bot.send_document(
                    chat_id=update.effective_chat.id,
                    document=f,
                    filename=os.path.basename(bkp_file),
                    caption="Backup do Sistema",
                    parse_mode='Markdown',
                    reply_markup=close_btn
                )
            os.remove(bkp_file)
            await query.edit_message_text("Backup enviado!", parse_mode='Markdown', reply_markup=build_menu())
        else:
            await query.edit_message_text("Falha ao criar backup.", reply_markup=build_menu())
        return SELECTING_ACTION

    await query.edit_message_text("OK.", reply_markup=build_menu())
    return SELECTING_ACTION


async def unexpected_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    return await button_handler(update, context)


async def input_handler(update: Update, context: ContextTypes.DEFAULT_TYPE, mode: str):
    if not is_admin(update): return
    if not update.message or not update.message.text: return
    text = update.message.text.strip().split()[0]

    if mode == 'create_nick':
        if not re.match(r'^[a-zA-Z0-9]{5,9}$', text):
            await update.message.reply_text(
                "*Nome Invalido!*\n\n5 a 9 caracteres, apenas letras e numeros.\n\nTente outro:",
                parse_mode='Markdown'
            )
            return GET_USERNAME_CREATE
        context.user_data['nick'] = text
        await update.message.reply_text(
            f"Validade (dias) para `{text}` [{MIN_DAYS}-{MAX_DAYS}]:",
            parse_mode='Markdown'
        )
        return GET_EXPIRY_DAYS_CREATE

    if mode == 'create_days':
        if not text.isdigit():
            await update.message.reply_text(f"Apenas numeros ({MIN_DAYS}-{MAX_DAYS}).")
            return GET_EXPIRY_DAYS_CREATE
        days_int = int(text)
        if not (MIN_DAYS <= days_int <= MAX_DAYS):
            await update.message.reply_text(f"Entre {MIN_DAYS} e {MAX_DAYS} dias.")
            return GET_EXPIRY_DAYS_CREATE
        res, msg = core_create_user(context.user_data['nick'], text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == 'delete':
        msg = core_delete_user(text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == 'block':
        msg = core_block_user(text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == 'unblock':
        msg = core_unblock_user(text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION


async def h_create_nick(u, c): return await input_handler(u, c, 'create_nick')
async def h_create_days(u, c): return await input_handler(u, c, 'create_days')
async def h_delete(u, c):      return await input_handler(u, c, 'delete')
async def h_block(u, c):       return await input_handler(u, c, 'block')
async def h_unblock(u, c):     return await input_handler(u, c, 'unblock')


async def cancel_op(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message:
        await update.message.reply_text("Cancelado.", reply_markup=build_menu())
    return SELECTING_ACTION


def main():
    app = Application.builder().token(BOT_TOKEN).build()

    conv = ConversationHandler(
        entry_points=[CommandHandler('start', start), CommandHandler('menu', start)],
        states={
            SELECTING_ACTION:       [CallbackQueryHandler(button_handler)],
            GET_USERNAME_CREATE:    [MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_nick),
                                     CallbackQueryHandler(unexpected_button)],
            GET_EXPIRY_DAYS_CREATE: [MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_days),
                                     CallbackQueryHandler(unexpected_button)],
            GET_USER_TO_DELETE:     [MessageHandler(filters.TEXT & ~filters.COMMAND, h_delete),
                                     CallbackQueryHandler(unexpected_button)],
            GET_USER_TO_BLOCK:      [MessageHandler(filters.TEXT & ~filters.COMMAND, h_block),
                                     CallbackQueryHandler(unexpected_button)],
            GET_USER_TO_UNBLOCK:    [MessageHandler(filters.TEXT & ~filters.COMMAND, h_unblock),
                                     CallbackQueryHandler(unexpected_button)],
        },
        fallbacks=[CommandHandler('cancel', cancel_op)],
        allow_reentry=True,
    )

    app.add_handler(conv)
    logger.info("DragonCore Bot V7.7 iniciado. Admin ID: %d", ADMIN_ID)
    app.run_polling()


if __name__ == '__main__':
    main()
