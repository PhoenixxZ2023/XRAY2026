"""
botxray.py - DragonCore Telegram Bot V7.5
Compatível com Python 3.8+ (sem X | Y syntax, usa Optional)
"""

from __future__ import annotations

import os
import json
import uuid
import logging
import logging.handlers
import subprocess
import re
import tempfile
import stat
from datetime import datetime, timedelta
from typing import Optional, Tuple, List

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, ContextTypes, ConversationHandler,
    MessageHandler, filters, CallbackQueryHandler
)
import io

# --- CONFIGURAÇÃO VIA VARIÁVEIS DE AMBIENTE ---
_missing = []
_token = os.environ.get("BOT_TOKEN", "")
_admin  = os.environ.get("ADMIN_ID", "")

if not _token:
    _missing.append("BOT_TOKEN")
if not _admin:
    _missing.append("ADMIN_ID")
if _missing:
    raise EnvironmentError(
        f"Variáveis obrigatórias não definidas: {', '.join(_missing)}\n"
        "Verifique /opt/XrayTools/.bot_env e EnvironmentFile= no botxray.service."
    )

try:
    ADMIN_ID: int = int(_admin)
except ValueError:
    raise EnvironmentError(f"ADMIN_ID deve ser inteiro, obtido: '{_admin}'")

BOT_TOKEN: str = _token

# --- CAMINHOS ---
CONFIG_PATH  = "/usr/local/etc/xray/config.json"
USER_DB      = "/opt/XrayTools/users.db"

SCRIPTS = {
    "create":  "/usr/local/bin/wrap_add_user",
    "delete":  "/usr/local/bin/wrap_remover_user",
    "block":   "/usr/local/bin/wrap_block_user",
    "unblock": "/usr/local/bin/wrap_unblock_user",
    "backup":  "/usr/local/bin/wrap_backup_bot",
    "restore": "/usr/local/bin/wrap_restore_bot",
}

MAX_RESTORE_MB = 50
ALLOWED_EXT    = (".tar.gz",)
MIN_DAYS       = 1
MAX_DAYS       = 3650

# --- LOGGING ---
_log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    level=getattr(logging, _log_level, logging.INFO),
)
logger = logging.getLogger(__name__)

_log_file = os.environ.get("LOG_FILE", "")
if _log_file:
    try:
        rh = logging.handlers.RotatingFileHandler(
            _log_file, maxBytes=5 * 1024 * 1024, backupCount=3
        )
        rh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s"))
        logging.getLogger().addHandler(rh)
    except Exception as e:
        logger.warning(f"Não foi possível abrir log file '{_log_file}': {e}")

# --- ESTADOS ---
(
    SELECTING_ACTION,
    GET_USERNAME_CREATE,
    GET_EXPIRY_DAYS_CREATE,
    GET_USER_TO_DELETE,
    GET_USER_TO_BLOCK,
    GET_USER_TO_UNBLOCK,
    WAIT_RESTORE_FILE,
) = range(7)


# ─────────────────────────────────────────────
# FUNÇÕES DE SISTEMA
# ─────────────────────────────────────────────

def load_config() -> Optional[dict]:
    if not os.path.exists(CONFIG_PATH):
        logger.warning("config.json não encontrado: %s", CONFIG_PATH)
        return None
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8", errors="ignore") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        logger.error("config.json inválido: %s", e)
        return None
    except OSError as e:
        logger.error("Erro ao ler config.json: %s", e)
        return None


def get_ip() -> str:
    sources = [
        ["curl", "-4", "-fsSL", "--max-time", "10", "--connect-timeout", "5",
         "https://icanhazip.com"],
        ["curl", "-4", "-fsSL", "--max-time", "10", "--connect-timeout", "5",
         "https://api.ipify.org"],
    ]
    for cmd in sources:
        try:
            ip = subprocess.check_output(cmd, timeout=12).decode().strip()
            if ip:
                return ip
        except Exception:
            continue
    return "127.0.0.1"


def read_uuid_from_db(nick: str) -> Optional[str]:
    try:
        if not os.path.exists(USER_DB):
            return None
        with open(USER_DB, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith(f"{nick}|"):
                    parts = line.strip().split("|")
                    if len(parts) >= 2:
                        return parts[1]
    except OSError as e:
        logger.error("Erro ao ler users.db: %s", e)
    return None


# ─────────────────────────────────────────────
# EXECUÇÃO DIRETA via wrappers setuid (sem sudo)
# ─────────────────────────────────────────────

def run_script(path: str, input_text: str = "", timeout: int = 180) -> Tuple[int, str]:
    try:
        p = subprocess.run(
            [path],
            input=input_text.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=timeout,
        )
        return p.returncode, p.stdout.decode("utf-8", errors="ignore")
    except subprocess.TimeoutExpired:
        return 124, "⏱️ Timeout executando o script."
    except Exception as e:
        logger.exception("Erro em run_script(%s)", path)
        return 1, f"Erro: {e}"


def run_script_args(path: str, args: List[str], timeout: int = 300) -> Tuple[int, str]:
    try:
        p = subprocess.run(
            [path] + args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=timeout,
        )
        return p.returncode, p.stdout.decode("utf-8", errors="ignore")
    except subprocess.TimeoutExpired:
        return 124, "⏱️ Timeout executando o script."
    except Exception as e:
        logger.exception("Erro em run_script_args(%s)", path)
        return 1, f"Erro: {e}"


# ─────────────────────────────────────────────
# GERADOR DE LINK VLESS
# ─────────────────────────────────────────────

def generate_link(client_uuid: Optional[str], client_email: str) -> str:
    try:
        data = load_config()
        if not data:
            return "Erro ao ler config."

        inbound = next(
            (i for i in data.get("inbounds", []) if i.get("tag") == "inbound-dragoncore"),
            None,
        )
        if not inbound:
            return "Erro: inbound-dragoncore não encontrado."

        port     = inbound.get("port")
        stream   = inbound.get("streamSettings", {})
        network  = stream.get("network", "tcp")
        security = stream.get("security", "none")

        sni = ""
        host = ""
        if security == "tls":
            tls  = stream.get("tlsSettings", {})
            sni  = tls.get("serverName", "") or ""
            host = sni

        if not host:
            host = get_ip()
            sni  = ""

        if not client_uuid:
            clients = inbound.get("settings", {}).get("clients", [])
            for c in clients:
                if c.get("email") == client_email:
                    client_uuid = c.get("id")
                    break

        if not client_uuid:
            return "UUID não encontrado."

        sec_param = "security=tls" if security == "tls" else "security=none"

        if network == "tcp":
            clients = inbound.get("settings", {}).get("clients", [])
            flow = next((c.get("flow", "") for c in clients if c.get("email") == client_email), "")
            if flow == "xtls-rprx-vision":
                return (f"vless://{client_uuid}@{host}:{port}"
                        f"?security=tls&encryption=none&type=tcp&headerType=none"
                        f"&flow={flow}&sni={sni}#{client_email}")
            return (f"vless://{client_uuid}@{host}:{port}"
                    f"?{sec_param}&encryption=none&type=tcp&headerType=none&sni={sni}#{client_email}")

        if network == "ws":
            ws   = stream.get("wsSettings", {})
            path = ws.get("path", "/")
            ws_host = sni if sni else host
            return (f"vless://{client_uuid}@{host}:{port}"
                    f"?{sec_param}&encryption=none&type=ws&host={ws_host}&path={path}&sni={sni}#{client_email}")

        if network == "grpc":
            grpc    = stream.get("grpcSettings", {})
            service = grpc.get("serviceName", "gRPC")
            return (f"vless://{client_uuid}@{host}:{port}"
                    f"?{sec_param}&encryption=none&type=grpc&serviceName={service}&sni={sni}#{client_email}")

        if network == "xhttp":
            xh   = stream.get("xhttpSettings", {})
            path = xh.get("path", "/")
            return (f"vless://{client_uuid}@{host}:{port}"
                    f"?mode=auto&{sec_param}&encryption=none&type=xhttp"
                    f"&host={host}&path={path}&sni={sni}#{client_email}")

        return (f"vless://{client_uuid}@{host}:{port}"
                f"?{sec_param}&encryption=none&type={network}&sni={sni}#{client_email}")

    except Exception as e:
        logger.exception("Erro em generate_link")
        return f"Erro Link: {e}"


# ─────────────────────────────────────────────
# FUNÇÕES CORE
# ─────────────────────────────────────────────

def core_create_user(nick: str, days: str) -> Tuple[bool, str]:
    code, out = run_script(SCRIPTS["create"], f"{nick}\n{days}\n\n", timeout=120)
    if code == 0:
        user_uuid = read_uuid_from_db(nick)
        link      = generate_link(user_uuid, nick)
        expiry    = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")
        return True, (
            f"✅ *Usuário Criado!*\n\n"
            f"👤 `{nick}`\n📅 `{expiry}`\n\n🔗 *Link VLESS:*\n`{link}`"
        )
    return False, f"❌ Falha ao criar.\n\n```\n{out[-1500:]}\n```"


def core_delete_user(nick: str) -> str:
    code, out = run_script(SCRIPTS["delete"], f"{nick}\ns\n", timeout=60)
    if code == 0:
        return f"✅ Usuário `{nick}` removido.\n\n```\n{out[-1200:]}\n```"
    return f"❌ Falha ao remover.\n\n```\n{out[-1200:]}\n```"


def core_block_user(nick: str) -> str:
    code, out = run_script(SCRIPTS["block"], f"{nick}\ns\n", timeout=60)
    if code == 0:
        return f"⛔ Usuário `{nick}` SUSPENSO.\n\n```\n{out[-1200:]}\n```"
    return f"❌ Falha ao suspender.\n\n```\n{out[-1200:]}\n```"


def core_unblock_user(nick: str) -> str:
    code, out = run_script(SCRIPTS["unblock"], f"{nick}\ns\n", timeout=60)
    if code == 0:
        return f"✅ Usuário `{nick}` REATIVADO.\n\n```\n{out[-1200:]}\n```"
    return f"❌ Falha ao reativar.\n\n```\n{out[-1200:]}\n```"


def core_list_users_text() -> str:
    if not os.path.exists(USER_DB):
        return "Nenhum usuário cadastrado."

    locked_users: set = set()
    data = load_config()
    if data:
        target = next((i for i in data.get("inbounds", []) if i.get("tag") == "inbound-dragoncore"), None)
        if target:
            for c in target.get("settings", {}).get("clients", []):
                email = c.get("email", "")
                if isinstance(email, str) and email.startswith("LOCKED_"):
                    locked_users.add(email.replace("LOCKED_", "", 1))

    lines  = ["LISTA DE USUÁRIOS - DRAGONCORE"]
    lines += ["=" * 65]
    lines += [f"{'NOME':<14} | {'VENCIMENTO':<11} | {'UUID (resumido)':<18} | STATUS"]
    lines += ["=" * 65]
    lines += ["(UUIDs completos em /opt/XrayTools/users/<nick>.txt no servidor)"]
    lines += ["-" * 65]

    try:
        with open(USER_DB, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.strip().split("|")
                if len(parts) >= 3:
                    nick       = parts[0]
                    uuid_full  = parts[1]
                    expiry     = parts[2]
                    uuid_short = f"{uuid_full[:8]}...{uuid_full[-4:]}" if len(uuid_full) >= 12 else uuid_full
                    status     = "⛔" if nick in locked_users else "✅"
                    lines.append(f"{nick:<14} | {expiry:<11} | {uuid_short:<18} | {status}")
    except OSError as e:
        lines.append(f"Erro ao ler users.db: {e}")

    return "\n".join(lines)


# ─────────────────────────────────────────────
# HELPERS TELEGRAM
# ─────────────────────────────────────────────

def is_admin(update: Update) -> bool:
    return bool(update.effective_user and update.effective_user.id == ADMIN_ID)


def build_menu() -> InlineKeyboardMarkup:
    keyboard = [
        [InlineKeyboardButton("👤 CRIAR",     callback_data="create_start"),
         InlineKeyboardButton("🗑️ REMOVER",  callback_data="delete_start")],
        [InlineKeyboardButton("⛔ SUSPENDER", callback_data="block_start"),
         InlineKeyboardButton("✅ REATIVAR",  callback_data="unblock_start")],
        [InlineKeyboardButton("📋 LISTAR",    callback_data="list_users"),
         InlineKeyboardButton("📥 BACKUP",    callback_data="backup_start")],
        [InlineKeyboardButton("♻️ RESTORE",   callback_data="restore_start"),
         InlineKeyboardButton("❌ SAIR",       callback_data="cancel")],
    ]
    return InlineKeyboardMarkup(keyboard)


# ─────────────────────────────────────────────
# HANDLERS
# ─────────────────────────────────────────────

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    context.user_data.clear()
    await update.message.reply_text(
        "🐉 *PAINEL DRAGONCORE V7.5*",
        reply_markup=build_menu(),
        parse_mode="Markdown",
    )
    return SELECTING_ACTION


async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return

    query = update.callback_query
    await query.answer()

    if query.data == "close_file":
        try:
            await query.message.delete()
        except Exception:
            pass
        return SELECTING_ACTION

    if query.data == "cancel":
        await query.edit_message_text("Painel Fechado.", reply_markup=None)
        return ConversationHandler.END

    if query.data == "create_start":
        await query.edit_message_text("Nome do usuário (5-9 letras/números):")
        return GET_USERNAME_CREATE

    if query.data == "delete_start":
        await query.edit_message_text("Nome para remover:")
        return GET_USER_TO_DELETE

    if query.data == "block_start":
        await query.edit_message_text("Nome para ⛔ SUSPENDER:")
        return GET_USER_TO_BLOCK

    if query.data == "unblock_start":
        await query.edit_message_text("Nome para ✅ REATIVAR:")
        return GET_USER_TO_UNBLOCK

    if query.data == "list_users":
        report = core_list_users_text()
        f = io.BytesIO(report.encode("utf-8"))
        f.name = "usuarios.txt"
        close_btn = InlineKeyboardMarkup(
            [[InlineKeyboardButton("🗑 Fechar Lista", callback_data="close_file")]]
        )
        await context.bot.send_document(
            chat_id=update.effective_chat.id,
            document=f,
            caption="📂 *Lista gerada* (UUIDs truncados por segurança)",
            parse_mode="Markdown",
            reply_markup=close_btn,
        )
        await query.edit_message_text("✅ *Lista enviada!*", parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    if query.data == "backup_start":
        await query.edit_message_text("📦 Gerando Backup...")
        code, out = run_script(SCRIPTS["backup"], "", timeout=180)
        if code != 0:
            await query.edit_message_text(
                f"❌ Falha ao criar backup.\n\n```\n{out[-1200:]}\n```",
                reply_markup=build_menu(), parse_mode="Markdown",
            )
            return SELECTING_ACTION

        bkp_file = out.strip().splitlines()[-1].strip()
        if not os.path.exists(bkp_file):
            await query.edit_message_text("❌ Arquivo de backup não encontrado.", reply_markup=build_menu())
            return SELECTING_ACTION

        close_btn = InlineKeyboardMarkup(
            [[InlineKeyboardButton("🗑 Fechar Backup", callback_data="close_file")]]
        )
        send_ok = False
        try:
            with open(bkp_file, "rb") as fobj:
                await context.bot.send_document(
                    chat_id=update.effective_chat.id,
                    document=fobj,
                    filename=os.path.basename(bkp_file),
                    caption="🔐 *Backup do Sistema*",
                    parse_mode="Markdown",
                    reply_markup=close_btn,
                )
            send_ok = True
        except Exception as e:
            logger.error("Falha ao enviar backup: %s", e)
            await query.edit_message_text(f"❌ Backup criado mas falhou ao enviar: {e}", reply_markup=build_menu())

        if send_ok:
            try:
                os.remove(bkp_file)
            except Exception:
                pass
            await query.edit_message_text("✅ *Backup enviado!*", parse_mode="Markdown", reply_markup=build_menu())

        return SELECTING_ACTION

    if query.data == "restore_start":
        warn = (
            "♻️ *RESTORE*\n\n"
            f"Envie o arquivo `backup_dragoncore_XXXX.tar.gz`.\n"
            f"• Somente `.tar.gz`  •  Máx: {MAX_RESTORE_MB} MB\n\n"
            "_Atenção: restaura config/usuários/SSL e reinicia serviços._"
        )
        await query.edit_message_text(warn, parse_mode="Markdown")
        return WAIT_RESTORE_FILE

    await query.edit_message_text("OK.", reply_markup=build_menu())
    return SELECTING_ACTION


async def unexpected_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    return await button_handler(update, context)


async def restore_file_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return SELECTING_ACTION
    if not update.message:
        return WAIT_RESTORE_FILE

    doc = update.message.document
    if not doc:
        await update.message.reply_text("Envie um arquivo `.tar.gz`.", reply_markup=build_menu())
        return SELECTING_ACTION

    filename = (doc.file_name or "").strip()
    if not filename.endswith(ALLOWED_EXT):
        await update.message.reply_text("❌ Apenas `.tar.gz`.", reply_markup=build_menu())
        return SELECTING_ACTION

    if doc.file_size and doc.file_size > (MAX_RESTORE_MB * 1024 * 1024):
        await update.message.reply_text(f"❌ Muito grande (máx {MAX_RESTORE_MB} MB).", reply_markup=build_menu())
        return SELECTING_ACTION

    await update.message.reply_text("⬇️ Baixando backup...")

    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".tar.gz", prefix="restore_")
    os.close(tmp_fd)
    os.chmod(tmp_path, stat.S_IRUSR | stat.S_IWUSR)

    try:
        tg_file = await doc.get_file()
        await tg_file.download_to_drive(custom_path=tmp_path)

        await update.message.reply_text("⚙️ Restaurando...")
        code, out = run_script_args(SCRIPTS["restore"], [tmp_path], timeout=300)

        if code == 0 and "OK" in out:
            await update.message.reply_text("✅ RESTORE concluído.", reply_markup=build_menu())
        else:
            await update.message.reply_text(
                f"❌ Falha no RESTORE.\n\n```\n{out[-1500:]}\n```",
                parse_mode="Markdown", reply_markup=build_menu(),
            )
    except Exception as e:
        logger.exception("Erro no restore_file_handler")
        await update.message.reply_text(f"❌ Erro: {e}", reply_markup=build_menu())
    finally:
        try:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
        except Exception:
            pass

    return SELECTING_ACTION


async def input_handler(update: Update, context: ContextTypes.DEFAULT_TYPE, mode: str):
    if not is_admin(update):
        return
    if not update.message or not update.message.text:
        return

    text = update.message.text.strip().split()[0]

    if mode == "create_nick":
        if not re.match(r"^[a-zA-Z0-9]{5,9}$", text):
            await update.message.reply_text(
                "❌ *Nome inválido!*\n\n• 5-9 caracteres\n• Letras e números\n\nTente novamente:",
                parse_mode="Markdown",
            )
            return GET_USERNAME_CREATE
        context.user_data["nick"] = text
        await update.message.reply_text(f"Validade (dias) para `{text}` [{MIN_DAYS}-{MAX_DAYS}]:", parse_mode="Markdown")
        return GET_EXPIRY_DAYS_CREATE

    if mode == "create_days":
        if not text.isdigit():
            await update.message.reply_text(f"Apenas números ({MIN_DAYS}-{MAX_DAYS}).")
            return GET_EXPIRY_DAYS_CREATE
        days_int = int(text)
        if not (MIN_DAYS <= days_int <= MAX_DAYS):
            await update.message.reply_text(f"❌ Entre {MIN_DAYS} e {MAX_DAYS} dias.")
            return GET_EXPIRY_DAYS_CREATE
        res, msg = core_create_user(context.user_data["nick"], text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "delete":
        msg = core_delete_user(text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "block":
        msg = core_block_user(text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "unblock":
        msg = core_unblock_user(text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION


async def h_create_nick(u, c): return await input_handler(u, c, "create_nick")
async def h_create_days(u, c): return await input_handler(u, c, "create_days")
async def h_delete(u, c):      return await input_handler(u, c, "delete")
async def h_block(u, c):       return await input_handler(u, c, "block")
async def h_unblock(u, c):     return await input_handler(u, c, "unblock")


async def cancel_op(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message:
        await update.message.reply_text("Cancelado.", reply_markup=build_menu())
    return SELECTING_ACTION


# ─────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────

def main():
    app = Application.builder().token(BOT_TOKEN).build()

    conv = ConversationHandler(
        entry_points=[
            CommandHandler("start", start),
            CommandHandler("menu",  start),
        ],
        states={
            SELECTING_ACTION: [CallbackQueryHandler(button_handler)],
            GET_USERNAME_CREATE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_nick),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_EXPIRY_DAYS_CREATE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_days),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_DELETE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_delete),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_BLOCK: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_block),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_UNBLOCK: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_unblock),
                CallbackQueryHandler(unexpected_button),
            ],
            WAIT_RESTORE_FILE: [
                MessageHandler(filters.Document.ALL, restore_file_handler),
                CallbackQueryHandler(unexpected_button),
                MessageHandler(
                    filters.TEXT & ~filters.COMMAND,
                    lambda u, c: u.message.reply_text("Envie um arquivo `.tar.gz`.", reply_markup=build_menu()),
                ),
            ],
        },
        fallbacks=[CommandHandler("cancel", cancel_op)],
        allow_reentry=True,
    )

    app.add_handler(conv)
    logger.info("DragonCore Bot V7.5 iniciado. Admin ID: %d", ADMIN_ID)
    app.run_polling()


if __name__ == "__main__":
    main()
