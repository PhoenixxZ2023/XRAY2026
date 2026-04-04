"""
botxray.py - DragonCore Telegram Bot V7.5.4
Correções: Compatibilidade de Tipagem para Python 3.8 (Ubuntu 20.04).
"""

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
        f"Variáveis de ambiente obrigatórias não definidas: {', '.join(_missing)}\n"
        "Verifique /opt/XrayTools/.bot_env e o EnvironmentFile= no botxray.service."
    )

try:
    ADMIN_ID = int(_admin)
except ValueError:
    raise EnvironmentError(f"ADMIN_ID deve ser um número inteiro, obtido: '{_admin}'")

BOT_TOKEN = _token

# --- CAMINHOS ---
CONFIG_PATH  = "/usr/local/etc/xray/config.json"
USER_DB      = "/opt/XrayTools/users.db"
XRAY_SERVICE = "xray"

# Scripts chamados via sudo
SCRIPTS = {
    "create":  "/usr/local/bin/add_user.sh",
    "delete":  "/usr/local/bin/remover_user.sh",
    "block":   "/usr/local/bin/block_user.sh",
    "unblock": "/usr/local/bin/unblock_user.sh",
    "backup":  "/usr/local/bin/backup_bot.sh",
    "restore": "/usr/local/bin/restore_bot.sh",
}

MAX_RESTORE_MB = 50
ALLOWED_EXT    = (".tar.gz",)
MIN_DAYS       = 1
MAX_DAYS       = 3650

# --- LOGGING CONFIGURÁVEL ---
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

# --- ESTADOS DO CONVERSATION HANDLER ---
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

def load_config():
    if not os.path.exists(CONFIG_PATH):
        logger.warning("config.json não encontrado: %s", CONFIG_PATH)
        return None
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8", errors="ignore") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        logger.error("config.json inválido (JSON corrompido): %s", e)
        return None
    except OSError as e:
        logger.error("Erro ao ler config.json: %s", e)
        return None

def get_ip():
    sources = [
        ["curl", "-4", "-fsSL", "--max-time", "10", "--connect-timeout", "5", "https://icanhazip.com"],
        ["curl", "-4", "-fsSL", "--max-time", "10", "--connect-timeout", "5", "https://api.ipify.org"],
    ]
    for cmd in sources:
        try:
            ip = subprocess.check_output(cmd, timeout=12).decode().strip()
            if ip:
                return ip
        except Exception:
            continue
    return "127.0.0.1"

def read_uuid_from_db(nick):
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
# EXECUÇÃO DE SCRIPTS VIA SUDO
# ─────────────────────────────────────────────

def run_script(path, input_text="", timeout=180):
    try:
        p = subprocess.run(
            ["sudo", "-n", path],
            input=input_text.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=timeout,
        )
        out = p.stdout.decode("utf-8", errors="ignore")
        return p.returncode, out
    except subprocess.TimeoutExpired:
        return 124, "⏱️ Timeout executando o script."
    except Exception as e:
        logger.exception("Erro em run_script(%s)", path)
        return 1, f"Erro ao executar script: {e}"

def run_script_args(path, args, timeout=300):
    try:
        p = subprocess.run(
            ["sudo", "-n", path] + args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=timeout,
        )
        out = p.stdout.decode("utf-8", errors="ignore")
        return p.returncode, out
    except subprocess.TimeoutExpired:
        return 124, "⏱️ Timeout executando o script."
    except Exception as e:
        logger.exception("Erro em run_script_args(%s)", path)
        return 1, f"Erro ao executar script: {e}"

# ─────────────────────────────────────────────
# GERADOR DE LINK VLESS
# ─────────────────────────────────────────────

def generate_link(client_uuid, client_email):
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
            tls = stream.get("tlsSettings", {})
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
            return "UUID não encontrado para gerar link."

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

def core_create_user(nick, days):
    code, out = run_script(SCRIPTS["create"], f"{nick}\n{days}\n\n", timeout=120)
    if code == 0:
        user_uuid = read_uuid_from_db(nick)
        link      = generate_link(user_uuid, nick)
        expiry    = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")
        return True, (
            f"✅ *Usuário Criado!*\n\n"
            f"👤 `{nick}`\n📅 `{expiry}`\n\n🔗 *Link VLESS:*\n`{link}`"
        )
    return False, f"❌ Falha ao criar usuário.\n\n
http://googleusercontent.com/immersive_entry_chip/0
http://googleusercontent.com/immersive_entry_chip/1
http://googleusercontent.com/immersive_entry_chip/2
http://googleusercontent.com/immersive_entry_chip/3
http://googleusercontent.com/immersive_entry_chip/4
http://googleusercontent.com/immersive_entry_chip/5
http://googleusercontent.com/immersive_entry_chip/6
http://googleusercontent.com/immersive_entry_chip/7
http://googleusercontent.com/immersive_entry_chip/8

A palavra **`Active: active (running)`** vai aparecer verde na sua tela. Mande um `/start` lá no Telegram do seu bot e veja o painel nascer!
