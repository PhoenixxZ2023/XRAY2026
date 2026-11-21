"""
botxray.py - TURBONET XRAY V1.4.3 (PRO + HÍBRIDO)
Correções V1.4.3:
- save_config() e _write_user_db_atomic() com tempfile.mkstemp + fsync + ajuste condicional de GID
- _append_user_db_line() garante quebra de linha antes de inserir novos registros no users.db
- core_delete_user() regrava config.json apenas quando há alteração efetiva no inbound
- Mantidas permissões 0o660, codificação de path (%2F) e limpeza de temporários no backup
"""

from __future__ import annotations

import grp
import hashlib
import io
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta
from typing import Optional, Tuple

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    ConversationHandler,
    MessageHandler,
    filters,
)

# --- CONFIGURAÇÃO VIA VARIÁVEIS DE AMBIENTE ---
_token = os.environ.get("BOT_TOKEN", "").strip()
_admin = os.environ.get("ADMIN_ID", "").strip()
if not _token or not _admin:
    raise EnvironmentError(
        "BOT_TOKEN e ADMIN_ID devem estar definidos.\n"
        "Verifique /opt/XrayTools/.bot_env e EnvironmentFile= no botxray.service."
    )
BOT_TOKEN = _token
try:
    ADMIN_ID = int(_admin)
except ValueError:
    raise EnvironmentError(f"ADMIN_ID deve ser inteiro, obtido: '{_admin}'")

CONFIG_PATH        = "/usr/local/etc/xray/config.json"
PRESET_PATH        = "/usr/local/etc/xray/preset.json"
USER_DB            = "/opt/XrayTools/users.db"
USAGE_DB           = "/opt/XrayTools/usage.db"
LIMITS_DB          = "/opt/XrayTools/limits.db"
ACTIVE_DOMAIN_FILE = "/opt/XrayTools/active_domain"
SSH_SYNC_WRAPPER   = "/usr/local/bin/wrap_ssh_sync"
XRAY_SERVICE       = "xray"

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

(
    SELECTING_ACTION,
    GET_USERNAME_CREATE,
    GET_EXPIRY_DAYS_CREATE,
    GET_USER_TO_DELETE,
    GET_USER_TO_BLOCK,
    GET_USER_TO_UNBLOCK,
    GET_USER_TO_RENEW,
    GET_DAYS_TO_RENEW,
) = range(8)


# =============================================================
# FUNÇÕES DE SISTEMA
# =============================================================

def _is_valid_nick(nick: str, strict_create: bool = False) -> bool:
    if not nick or nick == "root":
        return False
    if strict_create:
        return bool(re.match(r"^[a-z0-9]{5,9}$", nick))
    return bool(re.match(r"^[a-z0-9_-]{2,32}$", nick))


def _ensure_private_file(path: str, mode: int = 0o660) -> None:
    if not os.path.exists(path):
        fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY, mode)
        os.close(fd)
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def _append_user_db_line(entry: str) -> None:
    _ensure_private_file(USER_DB, 0o660)
    needs_newline = False
    try:
        if os.path.getsize(USER_DB) > 0:
            with open(USER_DB, "rb") as fb:
                fb.seek(-1, os.SEEK_END)
                if fb.read(1) != b"\n":
                    needs_newline = True
    except OSError:
        pass

    with open(USER_DB, "a", encoding="utf-8") as f:
        if needs_newline:
            f.write("\n")
        f.write(entry)
        f.flush()
        os.fsync(f.fileno())


def _write_user_db_atomic(lines: list[str]) -> None:
    db_dir = os.path.dirname(USER_DB)
    os.makedirs(db_dir, exist_ok=True)
    tmp_db = None
    try:
        fd, tmp_db = tempfile.mkstemp(prefix=".users.db.", suffix=".tmp", dir=db_dir)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(lines)
            f.flush()
            os.fsync(f.fileno())

        os.chmod(tmp_db, 0o660)
        try:
            bot_gid = grp.getgrnam("botxray").gr_gid
            if os.stat(tmp_db).st_gid != bot_gid:
                os.chown(tmp_db, -1, bot_gid)
        except (KeyError, OSError):
            pass

        os.replace(tmp_db, USER_DB)
        tmp_db = None
    finally:
        if tmp_db and os.path.exists(tmp_db):
            try:
                os.remove(tmp_db)
            except OSError:
                pass


def sync_ssh_user(action: str, nick: str, password: str = "") -> bool:
    """Sincroniza conta Linux (SSH/SOCKS5) via wrapper setuid quando não-root."""
    if not _is_valid_nick(nick):
        return False

    try:
        if os.geteuid() != 0 and os.path.exists(SSH_SYNC_WRAPPER):
            stdin_bytes = f"{password}\n".encode("utf-8") if action == "create" else None
            res = subprocess.run(
                [SSH_SYNC_WRAPPER, action, nick],
                input=stdin_bytes,
                check=False,
                capture_output=True,
                timeout=10,
            )
            if res.returncode != 0:
                logger.warning(
                    "sync_ssh_user (%s %s) retornou %d: %s",
                    action,
                    nick,
                    res.returncode,
                    res.stderr.decode(errors="replace").strip(),
                )
                return False
            return True

        if action == "create":
            pwd = password or nick
            subprocess.run(["useradd", "-M", "-s", "/bin/false", nick], check=False, stderr=subprocess.DEVNULL)
            subprocess.run(["chpasswd"], input=f"{nick}:{pwd}\n".encode("utf-8"), check=False, stderr=subprocess.DEVNULL)
        elif action == "delete":
            subprocess.run(["pkill", "-9", "-u", nick], check=False, stderr=subprocess.DEVNULL)
            subprocess.run(["userdel", "-r", "-f", nick], check=False, stderr=subprocess.DEVNULL)
        elif action == "block":
            subprocess.run(["usermod", "-L", nick], check=False, stderr=subprocess.DEVNULL)
            subprocess.run(["chage", "-E", "0", nick], check=False, stderr=subprocess.DEVNULL)
            subprocess.run(["pkill", "-9", "-u", nick], check=False, stderr=subprocess.DEVNULL)
        elif action in ("unblock", "renew"):
            subprocess.run(["usermod", "-U", nick], check=False, stderr=subprocess.DEVNULL)
            subprocess.run(["chage", "-E", "-1", nick], check=False, stderr=subprocess.DEVNULL)
            subprocess.run(["passwd", "-u", nick], check=False, stderr=subprocess.DEVNULL)
        return True
    except Exception as e:
        logger.error("sync_ssh_user erro (%s %s): %s", action, nick, e)
        return False


def _get_inbound_profile(data: dict) -> Tuple[str, str]:
    """Retorna (protocol, network) do inbound-turbonet."""
    inbound = next(
        (i for i in data.get("inbounds", []) if i.get("tag") == "inbound-turbonet"),
        None,
    )
    if not inbound:
        return "vless", "xhttp"
    proto = inbound.get("protocol", "vless")
    net = inbound.get("streamSettings", {}).get("network", "tcp")
    return proto, net


def _build_client_obj(nick: str, cred: str, proto: str, net: str, data: Optional[dict] = None) -> dict:
    if proto == "trojan":
        return {"password": cred, "email": nick, "level": 0}
    if net == "tcp":
        cfg = data if data is not None else load_config()
        if cfg:
            inb = next((i for i in cfg.get("inbounds", []) if i.get("tag") == "inbound-turbonet"), {})
            existing = inb.get("settings", {}).get("clients", [])
            if any(c.get("flow") == "xtls-rprx-vision" for c in existing):
                return {"id": cred, "email": nick, "level": 0, "flow": "xtls-rprx-vision"}
    return {"id": cred, "email": nick, "level": 0}


def reload_xray_user(action: str, nick: str, user_cred: str, inbound_tag: str = "inbound-turbonet") -> bool:
    try:
        data = load_config()
        if not data:
            return False
        api_port = None
        for inb in data.get("inbounds", []):
            if inb.get("tag") == "api":
                api_port = str(inb.get("port", ""))
                break
        if not api_port:
            logger.warning("reload_xray_user: inbound api não encontrado")
            return False

        xray_bin = "/usr/local/bin/xray"
        if not os.path.exists(xray_bin):
            logger.warning("reload_xray_user: xray binário não encontrado")
            return False

        if action == "add":
            proto, net = _get_inbound_profile(data)
            user_json = json.dumps(_build_client_obj(nick, user_cred, proto, net, data))
            cmd = [
                xray_bin, "api", "adduser",
                f"-server=127.0.0.1:{api_port}",
                f"-inboundTag={inbound_tag}",
                f"-user={user_json}",
            ]
        elif action == "remove":
            cmd = [
                xray_bin, "api", "removeuser",
                f"-server=127.0.0.1:{api_port}",
                f"-inboundTag={inbound_tag}",
                f"-email={nick}",
            ]
        else:
            return False

        result = subprocess.run(cmd, check=False, capture_output=True, timeout=5)
        if result.returncode == 0:
            logger.info("reload_xray_user: %s '%s' via API OK", action, nick)
            return True
        logger.warning(
            "reload_xray_user %s falhou: %s",
            action,
            result.stderr.decode(errors="replace").strip(),
        )
        return False
    except Exception as e:
        logger.error("reload_xray_user erro: %s", e)
        return False


def load_config() -> Optional[dict]:
    if not os.path.exists(CONFIG_PATH):
        return None
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        logger.error("JSON corrompido em %s: %s", CONFIG_PATH, e)
        return None
    except OSError as e:
        logger.error("Erro de leitura em %s: %s", CONFIG_PATH, e)
        return None


def save_config(data: dict) -> bool:
    cfg_dir = os.path.dirname(CONFIG_PATH)
    tmp_path = None

    target_gid = -1
    try:
        target_gid = os.stat(cfg_dir).st_gid
    except OSError:
        try:
            target_gid = grp.getgrnam("nogroup").gr_gid
        except KeyError:
            target_gid = -1

    try:
        fd, tmp_path = tempfile.mkstemp(prefix=".config.json.", suffix=".tmp", dir=cfg_dir)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())

        os.chmod(tmp_path, 0o660)
        if target_gid != -1:
            try:
                if os.stat(tmp_path).st_gid != target_gid:
                    os.chown(tmp_path, -1, target_gid)
            except OSError as e:
                logger.warning("save_config: não foi possível ajustar grupo %s: %s", target_gid, e)

        os.replace(tmp_path, CONFIG_PATH)
        tmp_path = None
        return True
    except PermissionError as e:
        logger.error("save_config: sem permissão em %s: %s", cfg_dir, e)
        return False
    except Exception as e:
        logger.error("Erro ao salvar config: %s", e)
        return False
    finally:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


def get_ip() -> str:
    for url in ("https://icanhazip.com", "https://api.ipify.org"):
        try:
            with urllib.request.urlopen(url, timeout=8) as resp:
                return resp.read().decode("utf-8").strip()
        except Exception as e:
            logger.warning("get_ip falhou em %s: %s", url, e)
    return "127.0.0.1"


def _get_active_domain() -> str:
    if os.path.exists(ACTIVE_DOMAIN_FILE):
        try:
            with open(ACTIVE_DOMAIN_FILE, "r", encoding="utf-8") as f:
                dom = f.read().strip()
                if dom:
                    return dom
        except OSError:
            pass

    if os.path.exists(PRESET_PATH):
        try:
            with open(PRESET_PATH, "r", encoding="utf-8") as f:
                preset = json.load(f)
                dom = (preset.get("domain") or "").strip()
                if dom:
                    return dom
        except Exception:
            pass

    return get_ip()


def bytes_to_human(b: int) -> str:
    if b >= 1073741824:
        return f"{b / 1073741824:.2f} GB"
    if b >= 1048576:
        return f"{b / 1048576:.2f} MB"
    return f"{b / 1024:.2f} KB"


# =============================================================
# GERADOR DE LINKS E RELATÓRIOS
# =============================================================

def generate_link(client_cred: str, client_email: str) -> str:
    try:
        data = load_config()
        if not data:
            return "❌ Erro ao ler config."

        inbound = next(
            (i for i in data.get("inbounds", []) if i.get("tag") == "inbound-turbonet"),
            None,
        )
        if not inbound:
            return "❌ inbound-turbonet não encontrado no config."

        port     = inbound["port"]
        protocol = inbound.get("protocol", "vless")
        stream   = inbound["streamSettings"]
        network  = stream["network"]
        security = stream["security"]

        sni  = ""
        host = ""
        if security == "tls":
            tls = stream.get("tlsSettings", {})
            sni = (tls.get("serverName") or "").strip()
            if not sni:
                sni = _get_active_domain()
            host = sni
            if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", host):
                sni = ""
        else:
            host = _get_active_domain()
            sni  = ""

        sec_param = "security=tls" if security == "tls" else "security=none"

        if protocol == "trojan":
            return (
                f"trojan://{client_cred}@{host}:{port}"
                f"?{sec_param}&sni={sni}&type=tcp#{client_email}"
            )

        if network == "tcp":
            clients = inbound.get("settings", {}).get("clients", [])
            client  = next((c for c in clients if c.get("id") == client_cred), {})
            flow    = client.get("flow", "")
            if flow == "xtls-rprx-vision":
                return (
                    f"vless://{client_cred}@{host}:{port}"
                    f"?security=tls&encryption=none&type=tcp"
                    f"&headerType=none&flow={flow}&sni={sni}#{client_email}"
                )
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=tcp&headerType=none&sni={sni}#{client_email}"
            )

        if network == "ws":
            raw_path = stream.get("wsSettings", {}).get("path", "/")
            enc_path = urllib.parse.quote(raw_path, safe="")
            ws_host  = sni if sni else host
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=ws"
                f"&host={ws_host}&path={enc_path}&sni={sni}#{client_email}"
            )

        if network == "grpc":
            service = stream.get("grpcSettings", {}).get("serviceName", "gRPC")
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=grpc"
                f"&serviceName={service}&sni={sni}#{client_email}"
            )

        if network == "xhttp":
            xhttp_cfg  = stream.get("xhttpSettings", {})
            raw_path   = xhttp_cfg.get("path", "/")
            enc_path   = urllib.parse.quote(raw_path, safe="")
            xhttp_host = (xhttp_cfg.get("host") or "").strip() or host
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?mode=auto&{sec_param}&encryption=none&type=xhttp"
                f"&host={xhttp_host}&path={enc_path}&sni={sni}#{client_email}"
            )

        if network == "httpupgrade":
            raw_path = stream.get("httpupgradeSettings", {}).get("path", "/")
            enc_path = urllib.parse.quote(raw_path, safe="")
            hu_host  = sni if sni else host
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=httpupgrade"
                f"&host={hu_host}&path={enc_path}&sni={sni}#{client_email}"
            )

        if network == "h2":
            raw_path = stream.get("httpSettings", {}).get("path", "/")
            enc_path = urllib.parse.quote(raw_path, safe="")
            h2_host  = sni if sni else host
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?security=tls&encryption=none&type=h2"
                f"&host={h2_host}&path={enc_path}&sni={sni}#{client_email}"
            )

        return "❌ Protocolo não suportado para geração de link."

    except Exception as e:
        return f"Erro Link: {e}"


def core_list_usage_text() -> str:
    """Lê os bancos de dados do limiterxray.sh e formata o consumo."""
    usages = {}
    if os.path.exists(USAGE_DB):
        with open(USAGE_DB, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split("|")
                if len(parts) >= 2 and parts[1].isdigit():
                    usages[parts[0]] = int(parts[1])

    limits = {}
    if os.path.exists(LIMITS_DB):
        with open(LIMITS_DB, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split("|")
                if len(parts) >= 2 and parts[1].isdigit():
                    limits[parts[0]] = int(parts[1])

    all_nicks = set(usages.keys()).union(set(limits.keys()))
    if os.path.exists(USER_DB):
        with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split("|")
                if parts[0]:
                    all_nicks.add(parts[0])

    if not all_nicks:
        return "Nenhum dado de consumo ou usuário registrado."

    sep = "-" * 60
    header = (
        "📊 RELATÓRIO DE CONSUMO DE DADOS\n"
        + sep + "\n"
        + f"{'USUÁRIO':<14} | {'USADO':<12} | {'LIMITE':<12} | STATUS\n"
        + sep + "\n"
    )
    rows = []

    for nick in sorted(all_nicks):
        use_bytes = usages.get(nick, 0)
        lim_bytes = limits.get(nick, None)

        use_str = bytes_to_human(use_bytes)

        if lim_bytes is None or lim_bytes <= 0:
            lim_str = "Sem limite"
            status  = "Livre"
        else:
            lim_str = bytes_to_human(lim_bytes)
            if use_bytes >= lim_bytes:
                status = "EXCEDIDO"
            else:
                pct    = int((use_bytes * 100) / lim_bytes)
                status = f"{pct}%"

        rows.append(f"{nick:<14} | {use_str:<12} | {lim_str:<12} | {status}")

    return header + "\n".join(rows) + "\n" + sep


def core_list_users_text() -> str:
    if not os.path.exists(USER_DB):
        return "Nenhum usuário cadastrado."

    data         = load_config()
    locked_users = set()
    if data:
        for inbound in data.get("inbounds", []):
            if inbound.get("tag") == "inbound-turbonet":
                for c in inbound.get("settings", {}).get("clients", []):
                    email = c.get("email", "")
                    if email.startswith("LOCKED_"):
                        locked_users.add(email.replace("LOCKED_", "", 1))

    sep = "-" * 65
    header = (
        "📋 LISTA DE USUÁRIOS - TURBONET XRAY\n"
        + sep + "\n"
        + f"{'NOME':<12} | {'VENCIMENTO':<11} | {'CREDENCIAL':<20} | STATUS\n"
        + sep + "\n"
    )
    rows = []
    with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) >= 3:
                nick_r, cred_r, expiry_r = parts[0], parts[1], parts[2]
                status     = "⛔" if nick_r in locked_users else "✅"
                cred_short = cred_r[:8] + "..." + cred_r[-4:] if len(cred_r) >= 12 else cred_r
                rows.append(f"{nick_r:<12} | {expiry_r:<11} | {cred_short:<20} | {status}")

    footer = "\n" + sep + f"\nTotal: {len(rows)} usuário(s)"
    return header + "\n".join(rows) + footer if rows else header + "(vazio)"


# =============================================================
# FUNÇÕES CORE DE GERENCIAMENTO (CRIAR, BLOQUEAR, RESTAURAR)
# =============================================================

def core_create_user(nick: str, days: str) -> Tuple[bool, str]:
    if not _is_valid_nick(nick, strict_create=True):
        return False, "❌ Nome de usuário inválido."

    _ensure_private_file(USER_DB, 0o660)
    with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
        if any(line.startswith(f"{nick}|") for line in f):
            return False, "❌ Usuário já existe!"

    data = load_config()
    if not data:
        return False, "❌ Erro ao ler config.json"

    inbound = next(
        (i for i in data.get("inbounds", []) if i.get("tag") == "inbound-turbonet"),
        None,
    )
    if not inbound:
        return False, "❌ inbound-turbonet não encontrado."

    existing_emails = {
        c.get("email", "") for c in inbound.get("settings", {}).get("clients", [])
    }
    if nick in existing_emails or f"LOCKED_{nick}" in existing_emails:
        return False, "❌ Usuário já cadastrado no config.json."

    proto, net  = _get_inbound_profile(data)
    user_cred   = uuid.uuid4().hex if proto == "trojan" else str(uuid.uuid4())
    expiry_date = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")

    inbound["settings"]["clients"].append(_build_client_obj(nick, user_cred, proto, net, data))

    if not save_config(data):
        return False, "❌ Falha ao salvar config.json."

    _append_user_db_line(f"{nick}|{user_cred}|{expiry_date}|{nick}|0\n")

    sync_ssh_user("create", nick, nick)
    reload_xray_user("add", nick, user_cred)
    link = generate_link(user_cred, nick)

    cred_label = "Senha Trojan" if proto == "trojan" else "UUID"
    return True, (
        f"✅ *Usuário Criado!*\n\n"
        f"👤 Nome:    `{nick}`\n"
        f"🔑 {cred_label}: `{user_cred}`\n"
        f"📅 Expira: `{expiry_date}`\n"
        f"🔐 Senha App: `{nick}`\n\n"
        f"🔗 *Link:*\n`{link}`"
    )


def core_delete_user(nick: str) -> str:
    if not _is_valid_nick(nick):
        return "❌ Nome de usuário inválido."

    data        = load_config()
    found       = False
    cfg_changed = False

    if data:
        for inbound in data.get("inbounds", []):
            if inbound.get("tag") == "inbound-turbonet":
                clients     = inbound["settings"]["clients"]
                new_clients = [
                    c for c in clients
                    if c.get("email") not in (nick, f"LOCKED_{nick}")
                ]
                if len(clients) != len(new_clients):
                    found       = True
                    cfg_changed = True
                    inbound["settings"]["clients"] = new_clients
        if cfg_changed and not save_config(data):
            return "❌ Falha ao salvar config.json."

    if os.path.exists(USER_DB):
        with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        new_lines = []
        for line in lines:
            if line.startswith(f"{nick}|"):
                found = True
            else:
                new_lines.append(line)
        _write_user_db_atomic(new_lines)

    if not found:
        return "❌ Usuário não encontrado no sistema."

    sync_ssh_user("delete", nick)
    reload_xray_user("remove", nick, "")
    reload_xray_user("remove", f"LOCKED_{nick}", "")
    return "✅ Usuário removido do sistema."


def core_block_user(nick: str) -> str:
    if not _is_valid_nick(nick):
        return "❌ Nome de usuário inválido."

    data = load_config()
    if not data:
        return "❌ Erro config."

    proto, _ = _get_inbound_profile(data)
    found = False
    for inbound in data.get("inbounds", []):
        if inbound.get("tag") == "inbound-turbonet":
            for client in inbound["settings"]["clients"]:
                if client.get("email") == f"LOCKED_{nick}":
                    return "⚠️ Usuário já está bloqueado."
                if client.get("email") == nick:
                    client["email"] = f"LOCKED_{nick}"
                    if proto == "trojan":
                        client["password"] = uuid.uuid4().hex
                    else:
                        client["id"] = str(uuid.uuid4())
                    found = True
                    break

    if not found:
        return "❌ Usuário não encontrado no Config."

    if not save_config(data):
        return "❌ Falha ao salvar config.json."

    sync_ssh_user("block", nick)
    reload_xray_user("remove", nick, "")
    locked_nick   = f"LOCKED_{nick}"
    fake_cred_str = uuid.uuid4().hex if proto == "trojan" else str(uuid.uuid4())
    reload_xray_user("add", locked_nick, fake_cred_str)
    return f"⛔ Usuário `{nick}` foi SUSPENSO e desconectado."


def core_unblock_user(nick: str) -> str:
    if not _is_valid_nick(nick):
        return "❌ Nome de usuário inválido."

    real_cred = None
    if os.path.exists(USER_DB):
        with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith(f"{nick}|"):
                    parts = line.strip().split("|")
                    if len(parts) >= 2:
                        real_cred = parts[1]
                    break

    if not real_cred:
        return "❌ Erro: Credencial original não encontrada no DB."

    data = load_config()
    if not data:
        return "❌ Erro ao ler config."

    proto, _ = _get_inbound_profile(data)
    found = False
    for inbound in data.get("inbounds", []):
        if inbound.get("tag") == "inbound-turbonet":
            for client in inbound["settings"]["clients"]:
                if client.get("email") == f"LOCKED_{nick}":
                    client["email"] = nick
                    if proto == "trojan":
                        client["password"] = real_cred
                    else:
                        client["id"] = real_cred
                    found = True
                    break

    if not found:
        return "❌ Usuário não estava bloqueado no sistema."

    if not save_config(data):
        return "❌ Falha ao salvar config.json."

    sync_ssh_user("unblock", nick)
    reload_xray_user("remove", f"LOCKED_{nick}", "")
    reload_xray_user("add", nick, real_cred)
    return f"✅ Usuário `{nick}` REATIVADO com sucesso."


def core_renew_user(nick: str, days_to_add: str) -> str:
    if not _is_valid_nick(nick):
        return "❌ Nome de usuário inválido."

    real_cred      = None
    current_expiry = None
    new_expiry     = ""
    found          = False
    lines          = []

    if os.path.exists(USER_DB):
        with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()

    for i, line in enumerate(lines):
        if line.startswith(f"{nick}|"):
            parts = line.strip().split("|")
            if len(parts) >= 3:
                real_cred      = parts[1]
                current_expiry = parts[2]
                try:
                    exp_date = datetime.strptime(current_expiry, "%Y-%m-%d")
                    if exp_date < datetime.now():
                        exp_date = datetime.now()
                    new_expiry = (exp_date + timedelta(days=int(days_to_add))).strftime("%Y-%m-%d")
                except ValueError:
                    new_expiry = (datetime.now() + timedelta(days=int(days_to_add))).strftime("%Y-%m-%d")

                parts[2] = new_expiry
                lines[i] = "|".join(parts) + "\n"
                found    = True
            break

    if not found:
        return "❌ Usuário não encontrado no banco de dados."

    _write_user_db_atomic(lines)
    sync_ssh_user("renew", nick)

    data = load_config()
    was_locked = False
    if data and real_cred:
        proto, _ = _get_inbound_profile(data)
        for inbound in data.get("inbounds", []):
            if inbound.get("tag") == "inbound-turbonet":
                for client in inbound["settings"]["clients"]:
                    if client.get("email") == f"LOCKED_{nick}":
                        client["email"] = nick
                        if proto == "trojan":
                            client["password"] = real_cred
                        else:
                            client["id"] = real_cred
                        was_locked = True
                        break
    if was_locked and data and real_cred:
        if save_config(data):
            reload_xray_user("remove", f"LOCKED_{nick}", "")
            reload_xray_user("add", nick, real_cred)
        else:
            logger.error("core_renew_user: falha ao salvar desbloqueio de %s", nick)

    return f"🔄 Usuário `{nick}` RENOVADO com sucesso!\nNova data: {new_expiry}"


# =============================================================
# FUNÇÕES DO TELEGRAM
# =============================================================

def is_admin(update: Update) -> bool:
    return update.effective_user is not None and update.effective_user.id == ADMIN_ID


def build_menu() -> InlineKeyboardMarkup:
    keyboard = [
        [
            InlineKeyboardButton("👤 CRIAR",        callback_data="create_start"),
            InlineKeyboardButton("🗑️ REMOVER",      callback_data="delete_start"),
        ],
        [
            InlineKeyboardButton("⛔ SUSPENDER",    callback_data="block_start"),
            InlineKeyboardButton("✅ REATIVAR",     callback_data="unblock_start"),
        ],
        [
            InlineKeyboardButton("🔄 RENOVAR",      callback_data="renew_start"),
            InlineKeyboardButton("📋 LISTAR (TXT)", callback_data="list_users"),
        ],
        [
            InlineKeyboardButton("📊 VER CONSUMO",  callback_data="usage_list"),
            InlineKeyboardButton("📥 BACKUP",       callback_data="backup_start"),
        ],
        [
            InlineKeyboardButton("❌ SAIR",         callback_data="cancel"),
        ],
    ]
    return InlineKeyboardMarkup(keyboard)


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    context.user_data.clear()
    await update.message.reply_text(
        "🐉 *PAINEL TURBONET XRAY V1.4.3 (PRO)*\n_Integração Híbrida SSH Ativa_",
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
        await query.message.delete()
        return SELECTING_ACTION

    if query.data == "cancel":
        await query.edit_message_text("Painel Fechado.", reply_markup=None)
        return ConversationHandler.END

    if query.data == "create_start":
        await query.edit_message_text(
            "Nome do usuário (5-9 letras/num):", parse_mode="Markdown"
        )
        return GET_USERNAME_CREATE

    if query.data == "delete_start":
        await query.edit_message_text("Nome para remover:", parse_mode="Markdown")
        return GET_USER_TO_DELETE

    if query.data == "block_start":
        await query.edit_message_text(
            "Nome para ⛔ SUSPENDER:", parse_mode="Markdown"
        )
        return GET_USER_TO_BLOCK

    if query.data == "unblock_start":
        await query.edit_message_text(
            "Nome para ✅ REATIVAR:", parse_mode="Markdown"
        )
        return GET_USER_TO_UNBLOCK

    if query.data == "renew_start":
        await query.edit_message_text(
            "Nome para 🔄 RENOVAR:", parse_mode="Markdown"
        )
        return GET_USER_TO_RENEW

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
            caption="📂 *Lista gerada*",
            parse_mode="Markdown",
            reply_markup=close_btn,
        )
        await query.edit_message_text(
            "✅ *Lista enviada abaixo!*\nEscolha outra opção:",
            parse_mode="Markdown",
            reply_markup=build_menu(),
        )
        return SELECTING_ACTION

    if query.data == "usage_list":
        report = core_list_usage_text()
        f = io.BytesIO(report.encode("utf-8"))
        f.name = "consumo.txt"
        close_btn = InlineKeyboardMarkup(
            [[InlineKeyboardButton("🗑 Fechar Relatório", callback_data="close_file")]]
        )
        await context.bot.send_document(
            chat_id=update.effective_chat.id,
            document=f,
            caption="📊 *Relatório de Consumo de Dados gerado*",
            parse_mode="Markdown",
            reply_markup=close_btn,
        )
        await query.edit_message_text(
            "✅ *Relatório de consumo enviado!*",
            parse_mode="Markdown",
            reply_markup=build_menu(),
        )
        return SELECTING_ACTION

    if query.data == "backup_start":
        await query.edit_message_text("📦 Gerando Backup...", parse_mode="Markdown")

        date_str = datetime.now().strftime("%Y%m%d_%H%M")
        bkp_file = f"/tmp/backup_{date_str}_{os.getpid()}.tar.gz"
        sha_file = bkp_file + ".sha256"

        tmpdir = tempfile.mkdtemp()
        try:
            os.makedirs(f"{tmpdir}/opt/XrayTools", exist_ok=True)
            for fname in ["users.db", "limits.db", "usage.db", "session.db", "active_domain", "connection_info.txt"]:
                src = f"/opt/XrayTools/{fname}"
                if os.path.exists(src):
                    shutil.copy2(src, f"{tmpdir}/opt/XrayTools/{fname}")
            if os.path.isdir("/usr/local/etc/xray"):
                shutil.copytree(
                    "/usr/local/etc/xray",
                    f"{tmpdir}/usr/local/etc/xray",
                    dirs_exist_ok=True,
                )
            if os.path.isdir("/opt/TurbonetCoreSSL"):
                shutil.copytree(
                    "/opt/TurbonetCoreSSL",
                    f"{tmpdir}/opt/TurbonetCoreSSL",
                    dirs_exist_ok=True,
                )
            subprocess.run(
                ["tar", "-czf", bkp_file, "-C", tmpdir, "."],
                check=False,
                capture_output=True,
            )
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

        try:
            if os.path.exists(bkp_file) and os.path.getsize(bkp_file) > 0:
                sha256_hash = hashlib.sha256()
                with open(bkp_file, "rb") as f_hash:
                    for byte_block in iter(lambda: f_hash.read(4096), b""):
                        sha256_hash.update(byte_block)
                digest = sha256_hash.hexdigest()

                with open(sha_file, "w", encoding="utf-8") as sf:
                    sf.write(f"{digest}  backup_{date_str}.tar.gz\n")

                close_btn = InlineKeyboardMarkup(
                    [[InlineKeyboardButton("🗑 Fechar Backup", callback_data="close_file")]]
                )
                with open(bkp_file, "rb") as f:
                    await context.bot.send_document(
                        chat_id=update.effective_chat.id,
                        document=f,
                        filename=f"backup_{date_str}.tar.gz",
                        caption=(
                            "🔐 *Backup do Sistema*\n\n"
                            "_Inclui Xray, Banco de Dados e SSL_\n"
                            f"SHA256: `{digest[:16]}...`"
                        ),
                        parse_mode="Markdown",
                        reply_markup=close_btn,
                    )
                with open(sha_file, "rb") as f:
                    await context.bot.send_document(
                        chat_id=update.effective_chat.id,
                        document=f,
                        filename=f"backup_{date_str}.tar.gz.sha256",
                        caption="🔑 Hash SHA256 do backup acima",
                    )
                await query.edit_message_text(
                    "✅ *Backup enviado abaixo!*",
                    parse_mode="Markdown",
                    reply_markup=build_menu(),
                )
            else:
                await query.edit_message_text(
                    "❌ Falha ao criar backup. Verifique os logs.",
                    reply_markup=build_menu(),
                )
        finally:
            for tmpf in (bkp_file, sha_file):
                if os.path.exists(tmpf):
                    try:
                        os.remove(tmpf)
                    except OSError:
                        pass
        return SELECTING_ACTION

    await query.edit_message_text("Reiniciando...", reply_markup=build_menu())
    return SELECTING_ACTION


async def unexpected_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    return await button_handler(update, context)


async def input_handler(
    update: Update, context: ContextTypes.DEFAULT_TYPE, mode: str
):
    if not is_admin(update):
        return SELECTING_ACTION
    if not update.message or not update.message.text:
        return SELECTING_ACTION

    text = update.message.text.strip().split()[0].lower()

    if mode == "create_nick":
        if not _is_valid_nick(text, strict_create=True):
            await update.message.reply_text(
                "❌ *Nome Inválido!*\n\nRegras:\n• Entre 5 e 9 caracteres\n"
                "• Apenas letras e números\n\nTente outro:",
                parse_mode="Markdown",
            )
            return GET_USERNAME_CREATE
        context.user_data["nick"] = text
        await update.message.reply_text(
            f"Validade (dias) para `{text}`:", parse_mode="Markdown"
        )
        return GET_EXPIRY_DAYS_CREATE

    if mode == "create_days":
        if not text.isdigit() or not (1 <= int(text) <= 3650):
            await update.message.reply_text("❌ Informe um número de dias entre 1 e 3650.")
            return GET_EXPIRY_DAYS_CREATE
        _ok, msg = core_create_user(context.user_data["nick"], text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "delete":
        if not _is_valid_nick(text):
            await update.message.reply_text("❌ Nome de usuário inválido.", reply_markup=build_menu())
            return SELECTING_ACTION
        msg = core_delete_user(text)
        await update.message.reply_text(msg, reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "block":
        if not _is_valid_nick(text):
            await update.message.reply_text("❌ Nome de usuário inválido.", reply_markup=build_menu())
            return SELECTING_ACTION
        msg = core_block_user(text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "unblock":
        if not _is_valid_nick(text):
            await update.message.reply_text("❌ Nome de usuário inválido.", reply_markup=build_menu())
            return SELECTING_ACTION
        msg = core_unblock_user(text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "renew_nick":
        if not _is_valid_nick(text):
            await update.message.reply_text("❌ Nome de usuário inválido.", reply_markup=build_menu())
            return SELECTING_ACTION
        context.user_data["renew_nick"] = text
        await update.message.reply_text(
            f"Quantos dias deseja adicionar para `{text}`?", parse_mode="Markdown"
        )
        return GET_DAYS_TO_RENEW

    if mode == "renew_days":
        if not text.isdigit() or not (1 <= int(text) <= 3650):
            await update.message.reply_text("❌ Informe um número de dias entre 1 e 3650.")
            return GET_DAYS_TO_RENEW
        msg = core_renew_user(context.user_data["renew_nick"], text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    logger.warning("input_handler: modo desconhecido '%s'", mode)
    await update.message.reply_text("❌ Operação inválida.", reply_markup=build_menu())
    return SELECTING_ACTION


# Wrappers assíncronos
async def h_create_nick(u, c): return await input_handler(u, c, "create_nick")
async def h_create_days(u, c): return await input_handler(u, c, "create_days")
async def h_delete(u, c):      return await input_handler(u, c, "delete")
async def h_block(u, c):       return await input_handler(u, c, "block")
async def h_unblock(u, c):     return await input_handler(u, c, "unblock")
async def h_renew_nick(u, c):  return await input_handler(u, c, "renew_nick")
async def h_renew_days(u, c):  return await input_handler(u, c, "renew_days")


async def cancel_op(u, c):
    await u.message.reply_text("Cancelado.", reply_markup=build_menu())
    return SELECTING_ACTION


# =============================================================
# MAIN
# =============================================================

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
            GET_USER_TO_RENEW: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_renew_nick),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_DAYS_TO_RENEW: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_renew_days),
                CallbackQueryHandler(unexpected_button),
            ],
        },
        fallbacks=[CommandHandler("cancel", cancel_op)],
        allow_reentry=True,
    )
    app.add_handler(conv)
    logger.info("TURBONET XRAY Bot V1.4.3 iniciado. Admin ID: %d", ADMIN_ID)
    app.run_polling()


if __name__ == "__main__":
    main()
