#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from unicodedata import normalize as unicode_normalize


BASE_DIR = Path(__file__).resolve().parent
ENV_PATH = BASE_DIR / ".env"
CONFIG_PATH = BASE_DIR / "config.json"
SITE_MESSAGE_ID_PATH = BASE_DIR / "runtime" / "discord_site_message_id.txt"
PERMANENT_ACCESS_URL_PATH = BASE_DIR / "runtime" / "permanent_access_url.txt"
DISCORD_API = "https://discord.com/api/v10"
TELEGRAM_API = "https://api.telegram.org"
DISCORD_TIMEOUT_SECONDS = 8
TELEGRAM_TIMEOUT_SECONDS = 6
GLOBAL_GTS_MARKER = re.compile(r"\bto\s+the\s+global\s+GTS\s+for\b", re.IGNORECASE)


@dataclass(frozen=True)
class GtsListing:
    item: str
    price: str
    raw_chat: str
    seller: str = ""
    amount: str = ""
    currency: str = ""
    price_type: str = ""
    fingerprint: str = ""
    detected_at: str = ""

    @property
    def pokemon(self) -> str:
        return self.item


@dataclass(frozen=True)
class FilterResult:
    allowed: bool
    reason: str = ""


def load_dotenv(path: Path) -> None:
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"Config não encontrado: {path}")
    with path.open("r", encoding="utf-8") as config_file:
        return json.load(config_file)


def env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name, str(default)).strip().casefold()
    return value in {"1", "true", "yes", "sim", "on"}


def strip_minecraft_codes(text: str) -> str:
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    text = re.sub(r"§[0-9A-FK-ORa-fk-or]", "", text)
    return text


def extract_chat_text(log_line: str) -> str:
    clean = strip_minecraft_codes(log_line).strip()
    marker = "[CHAT]"
    if marker in clean:
        return clean.split(marker, 1)[1].strip()
    return clean


def normalize_field(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip(" :-|()")


def fold_text(value: str) -> str:
    normalized = unicode_normalize("NFKD", value)
    ascii_value = normalized.encode("ascii", "ignore").decode("ascii")
    return ascii_value.casefold()


def list_from_config(value: Any) -> list[str]:
    if not value:
        return []
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    return [str(value).strip()]


def normalize_price_type(value: str) -> str:
    folded = fold_text(value)
    if "token" in folded:
        return "token"
    if "site" in folded or "saldo" in folded or "real" in folded:
        return "site"
    if "poke" in folded or "money" in folded or "$" in folded:
        return "money"
    if "desconhecido" in folded or "unknown" in folded:
        return "desconhecido"
    return folded


def amount_to_float(amount: str) -> float | None:
    value = re.sub(r"[^0-9,.-]", "", amount.strip())
    if not value:
        return None

    if "," in value and "." in value:
        if value.rfind(",") > value.rfind("."):
            value = value.replace(".", "").replace(",", ".")
        else:
            value = value.replace(",", "")
    elif "," in value:
        left, right = value.rsplit(",", 1)
        if value.count(",") == 1 and len(right) in {1, 2}:
            value = f"{left}.{right}"
        else:
            value = value.replace(",", "")

    try:
        return float(value)
    except ValueError:
        return None


def parse_price_details(raw_price: str) -> tuple[str, str, str, str]:
    clean = re.sub(r"\s+", " ", strip_minecraft_codes(raw_price).rstrip("!")).strip(" :-|")
    lower = clean.lower()

    amount_match = re.search(r"([0-9][0-9.,]*)", clean)
    amount = amount_match.group(1) if amount_match else clean

    if "token" in lower:
        return clean, amount, "Tokens", "token"
    if "saldo no site" in lower or "real do site" in lower:
        return clean, amount, "Saldo no Site", "site"
    if "pokécoin" in lower or "pokecoin" in lower or "$" in clean:
        return clean, amount, "PokéCoins", "money"

    currency_match = re.search(r"[0-9][0-9.,]*\s*([A-Za-zÀ-ÿ ]+)", clean)
    currency = normalize_field(currency_match.group(1)) if currency_match else "desconhecido"
    return clean, amount, currency, "desconhecido"


def parse_listing(log_line: str, patterns: list[re.Pattern[str]]) -> GtsListing | None:
    chat_text = extract_chat_text(log_line)
    if not GLOBAL_GTS_MARKER.search(chat_text):
        return None

    for pattern in patterns:
        match = pattern.search(chat_text)
        if not match:
            continue

        data = match.groupdict()
        item = normalize_field(data.get("item") or data.get("pokemon", ""))
        raw_price = data.get("price_text") or data.get("price", "")
        price, amount, currency, price_type = parse_price_details(raw_price)
        seller = normalize_field(data.get("seller", ""))

        if item and price:
            return GtsListing(
                item=item,
                price=price,
                raw_chat=chat_text,
                seller=seller,
                amount=amount,
                currency=currency,
                price_type=price_type,
                fingerprint=fingerprint_line(log_line),
                detected_at=datetime.now(timezone.utc).isoformat(),
            )

    return None


def compile_patterns(config: dict[str, Any]) -> list[re.Pattern[str]]:
    raw_patterns = config.get("patterns", [])
    if not isinstance(raw_patterns, list) or not raw_patterns:
        raise ValueError("config.json precisa ter uma lista não vazia em 'patterns'.")
    return [re.compile(pattern, re.IGNORECASE) for pattern in raw_patterns]


def discord_request(token: str, method: str, route: str, payload: dict[str, Any] | None = None) -> dict[str, Any] | list[Any]:
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {
        "Authorization": f"Bot {token}",
        "User-Agent": "pixelmon-gts-discord (local script)",
    }
    if payload is not None:
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(
        f"{DISCORD_API}{route}",
        data=body,
        method=method,
        headers=headers,
    )

    try:
        with urllib.request.urlopen(request, timeout=DISCORD_TIMEOUT_SECONDS) as response:
            response_body = response.read().decode("utf-8")
            return json.loads(response_body) if response_body else {}
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Discord HTTP {exc.code}: {error_body}") from exc


def create_dm_channel(token: str, user_id: str) -> str:
    response = discord_request(token, "POST", "/users/@me/channels", {"recipient_id": user_id})
    channel_id = response.get("id")
    if not channel_id:
        raise RuntimeError(f"Discord não retornou channel id: {response}")
    return str(channel_id)


def send_dm_payload(token: str, user_id: str, payload: dict[str, Any]) -> None:
    channel_id = create_dm_channel(token, user_id)
    discord_request(token, "POST", f"/channels/{channel_id}/messages", payload)


def upsert_pinned_site_message(token: str, channel_id: str, content: str) -> tuple[str, str | None]:
    payload = {"content": content, "allowed_mentions": {"parse": []}}
    message_id = SITE_MESSAGE_ID_PATH.read_text(encoding="utf-8").strip() if SITE_MESSAGE_ID_PATH.exists() else ""

    if message_id:
        try:
            discord_request(token, "PATCH", f"/channels/{channel_id}/messages/{message_id}", payload)
        except RuntimeError as exc:
            if "Discord HTTP 404" not in str(exc):
                raise
            message_id = ""

    if not message_id:
        response = discord_request(token, "POST", f"/channels/{channel_id}/messages", payload)
        if not isinstance(response, dict) or not response.get("id"):
            raise RuntimeError(f"Discord não retornou o ID da mensagem do site: {response}")
        message_id = str(response["id"])
        SITE_MESSAGE_ID_PATH.parent.mkdir(parents=True, exist_ok=True)
        SITE_MESSAGE_ID_PATH.write_text(message_id + "\n", encoding="utf-8")

    pin_error: str | None = None
    try:
        discord_request(token, "PUT", f"/channels/{channel_id}/pins/{message_id}")
    except RuntimeError as exc:
        pin_error = str(exc)
    return message_id, pin_error


def format_site_message(site_url: str) -> str:
    site_url = site_url.rstrip("/")
    updated_at = int(time.time())
    return (
        "📡 **PAINEL PIXELMON GTS — LINK OFICIAL**\n"
        "Esta mensagem é atualizada automaticamente quando o endereço muda.\n\n"
        f"🔗 **Acessar painel:** {site_url}\n"
        f"📝 **Criar conta:** {site_url}/register\n"
        f"🛡️ **Administração:** {site_url}/admin\n\n"
        f"🟢 Online • Atualizado <t:{updated_at}:R>"
    )


def telegram_enabled() -> bool:
    return env_bool("TELEGRAM_ENABLED", False)


def telegram_request(method: str, endpoint: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    token = get_required_env("TELEGRAM_BOT_TOKEN")
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"User-Agent": "pixelmon-gts-telegram (local script)"}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        f"{TELEGRAM_API}/bot{token}/{endpoint}",
        data=body,
        method=method,
        headers=headers,
    )

    try:
        with urllib.request.urlopen(request, timeout=TELEGRAM_TIMEOUT_SECONDS) as response:
            response_body = response.read().decode("utf-8")
            data = json.loads(response_body) if response_body else {}
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Telegram HTTP {exc.code}: {error_body}") from exc

    if not data.get("ok", False):
        raise RuntimeError(f"Telegram retornou erro: {data}")
    return data


def send_telegram_chat_text(chat_id: str, content: str) -> None:
    payload = {
        "chat_id": chat_id,
        "text": truncate(content, 4000),
        "disable_web_page_preview": False,
    }
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            telegram_request("POST", "sendMessage", payload)
            return
        except Exception as exc:
            last_error = exc
            if attempt < 2:
                time.sleep(0.25 * (attempt + 1))
    if last_error:
        raise last_error


def send_telegram_text(content: str) -> None:
    send_telegram_chat_text(get_required_env("TELEGRAM_CHAT_ID"), content)


def send_telegram_text_optional(content: str) -> None:
    if not telegram_enabled():
        return
    try:
        send_telegram_text(content)
    except Exception as exc:
        print(f"[ERRO TELEGRAM] {exc}", file=sys.stderr, flush=True)
        return
    print("Enviado no Telegram.", flush=True)


def format_telegram_listing(listing: GtsListing) -> str:
    marker = currency_marker(listing)
    price_display = f"{listing.amount} {listing.currency}".strip() or listing.price
    return (
        f"{marker} GTS Global | {friendly_price_type(listing)}\n"
        f"💎 Item/Pokémon: {listing.item}\n"
        f"💰 Preço: {price_display}\n"
        f"👤 Vendedor: {listing.seller or 'desconhecido'}\n"
        f"🧾 Original: {listing.price}"
    )


def format_telegram_site(site_url: str, permanent_access_url: str) -> str:
    site_url = site_url.rstrip("/")
    return (
        "📡 Painel Pixelmon GTS online\n\n"
        f"🔗 Acessar: {site_url}\n"
        f"📌 Link fixo no Discord: {permanent_access_url}\n"
        f"📝 Registro: {site_url}/register\n"
        f"🛡️ Admin: {site_url}/admin"
    )


def print_telegram_updates() -> None:
    data = telegram_request("GET", "getUpdates")
    updates = data.get("result", [])
    if not updates:
        print("Nenhuma conversa encontrada. Abra o Telegram, mande /start para o bot e rode de novo.")
        return

    seen: set[str] = set()
    for update in updates[-20:]:
        message = update.get("message") or update.get("channel_post") or {}
        chat = message.get("chat") or {}
        chat_id = str(chat.get("id", ""))
        if not chat_id or chat_id in seen:
            continue
        seen.add(chat_id)
        chat_type = chat.get("type", "")
        title = chat.get("title") or " ".join(
            part for part in [chat.get("first_name", ""), chat.get("last_name", "")] if part
        )
        username = chat.get("username", "")
        suffix = f" @{username}" if username else ""
        print(f"{chat_id}\t{chat_type}\t{title}{suffix}")


def format_message(template: str, listing: GtsListing) -> str:
    return template.format(
        item=listing.item,
        pokemon=listing.item,
        price=listing.price,
        amount=listing.amount,
        currency=listing.currency,
        price_type=listing.price_type,
        raw_chat=listing.raw_chat,
        seller=listing.seller,
    )


def truncate(value: str, limit: int) -> str:
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 3)] + "..."


def parse_embed_color(raw_color: Any) -> int:
    if isinstance(raw_color, int):
        return raw_color
    if isinstance(raw_color, str):
        color = raw_color.strip()
        if color.startswith("#"):
            color = color[1:]
        if color.startswith("0x"):
            color = color[2:]
        return int(color, 16)
    return 0x5865F2


def embed_color_for_listing(config: dict[str, Any], listing: GtsListing) -> int:
    colors = config.get("embed_colors", {})
    if not isinstance(colors, dict):
        return 0x5865F2

    raw_color = colors.get(listing.price_type) or colors.get("default") or 0x5865F2
    try:
        return parse_embed_color(raw_color)
    except ValueError:
        return 0x5865F2


def currency_marker(listing: GtsListing) -> str:
    if listing.price_type == "money":
        return "🟡"
    if listing.price_type == "token":
        return "🟣"
    if listing.price_type == "site":
        return "🟢"
    return "🔵"


def friendly_price_type(listing: GtsListing) -> str:
    if listing.price_type == "money":
        return "PokéCoins"
    if listing.price_type == "token":
        return "Tokens"
    if listing.price_type == "site":
        return "Saldo no Site"
    return listing.currency or "Desconhecido"


def code_block(value: str, language: str = "text", limit: int = 980) -> str:
    return f"```{language}\n{truncate(value, limit)}\n```"


def build_discord_payload(config: dict[str, Any], listing: GtsListing, fallback_message: str) -> dict[str, Any]:
    if not bool(config.get("use_embeds", True)):
        return {"content": fallback_message}

    marker = currency_marker(listing)
    price_display = f"{listing.amount} {listing.currency}".strip()
    if not price_display:
        price_display = listing.price

    fields = [
        {"name": f"{marker} Preço", "value": f"**{truncate(price_display, 1000)}**", "inline": True},
        {"name": "🟪 Vendedor", "value": f"`{truncate(listing.seller or 'desconhecido', 1000)}`", "inline": True},
        {"name": "🧾 Tipo", "value": f"**{truncate(friendly_price_type(listing), 1000)}**", "inline": True},
    ]
    if bool(config.get("show_original_price", True)):
        fields.append({"name": f"{marker} Preço original", "value": f"`{truncate(listing.price, 1000)}`", "inline": False})
    if bool(config.get("show_raw_log", False)):
        fields.append({"name": "📜 Linha da log", "value": code_block(listing.raw_chat), "inline": False})

    payload: dict[str, Any] = {
        "embeds": [
            {
                "author": {"name": "Pixelmon Brasil • GTS Global"},
                "title": truncate(f"{marker} GTS Global | {friendly_price_type(listing)}", 256),
                "description": f"💎 **{truncate(listing.item, 3800)}**",
                "color": embed_color_for_listing(config, listing),
                "fields": fields,
                "footer": {"text": f"{marker} Detectado automaticamente • {listing.price_type or 'desconhecido'}"},
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
        ]
    }
    return payload


def contains_any(text: str, terms: list[str]) -> bool:
    folded_text = fold_text(text)
    return any(fold_text(term) in folded_text for term in terms)


def should_send_listing(config: dict[str, Any], listing: GtsListing) -> FilterResult:
    filters = config.get("filters", {})
    if not isinstance(filters, dict) or not bool(filters.get("enabled", True)):
        return FilterResult(True)

    listing_type = normalize_price_type(listing.price_type or listing.currency)
    allowed_types = [normalize_price_type(item) for item in list_from_config(filters.get("allowed_price_types"))]
    blocked_types = [normalize_price_type(item) for item in list_from_config(filters.get("blocked_price_types"))]

    if allowed_types and listing_type not in allowed_types:
        return FilterResult(False, f"tipo fora da lista permitida: {listing_type}")
    if blocked_types and listing_type in blocked_types:
        return FilterResult(False, f"tipo bloqueado: {listing_type}")

    seller = fold_text(listing.seller)
    allowed_sellers = [fold_text(item) for item in list_from_config(filters.get("allowed_sellers"))]
    blocked_sellers = [fold_text(item) for item in list_from_config(filters.get("blocked_sellers"))]
    if allowed_sellers and seller not in allowed_sellers:
        return FilterResult(False, f"vendedor fora da lista permitida: {listing.seller}")
    if blocked_sellers and seller in blocked_sellers:
        return FilterResult(False, f"vendedor bloqueado: {listing.seller}")

    searchable = f"{listing.item} {listing.seller} {listing.price} {listing.raw_chat}"
    required_keywords = list_from_config(filters.get("required_keywords"))
    ignored_keywords = list_from_config(filters.get("ignored_keywords"))
    if required_keywords and not contains_any(searchable, required_keywords):
        return FilterResult(False, "não contém palavra-chave exigida")
    if ignored_keywords and contains_any(searchable, ignored_keywords):
        return FilterResult(False, "contém palavra-chave ignorada")

    limits = filters.get("price_limits", {})
    if isinstance(limits, dict):
        raw_limit = limits.get(listing_type)
        if isinstance(raw_limit, dict):
            amount = amount_to_float(listing.amount)
            if amount is None:
                return FilterResult(False, "preço sem quantidade numérica")

            minimum = raw_limit.get("min")
            maximum = raw_limit.get("max")
            if minimum is not None and amount < float(minimum):
                return FilterResult(False, f"preço abaixo do mínimo: {listing.amount}")
            if maximum is not None and amount > float(maximum):
                return FilterResult(False, f"preço acima do máximo: {listing.amount}")

    return FilterResult(True)


def config_path(config: dict[str, Any], value: str, default_name: str) -> Path:
    raw_path = str(value or default_name).strip() or default_name
    path = Path(raw_path).expanduser()
    if path.is_absolute():
        return path
    return BASE_DIR / path


def history_config(config: dict[str, Any]) -> dict[str, Any]:
    history = config.get("history", {})
    return history if isinstance(history, dict) else {}


def database_path(config: dict[str, Any]) -> Path:
    configured = os.environ.get("PANEL_DB_PATH", "").strip()
    if not configured:
        configured = str(history_config(config).get("database", "access_panel.db"))
    return config_path(config, configured, "access_panel.db")


def database_connection(config: dict[str, Any]) -> sqlite3.Connection:
    path = database_path(config)
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path, timeout=5)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode = WAL")
    connection.execute("PRAGMA foreign_keys = ON")
    return connection


def ensure_storage(config: dict[str, Any]) -> None:
    with database_connection(config) as connection:
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
              id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
              password_hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'user', status TEXT NOT NULL DEFAULT 'pending',
              invite_code TEXT, approval_token TEXT UNIQUE, created_at INTEGER NOT NULL,
              approved_at INTEGER, last_login_at INTEGER
            );
            CREATE TABLE IF NOT EXISTS listings (
              id INTEGER PRIMARY KEY AUTOINCREMENT, fingerprint TEXT NOT NULL UNIQUE,
              detected_at TEXT NOT NULL, detected_at_epoch INTEGER NOT NULL, status TEXT, reason TEXT,
              item TEXT NOT NULL, item_key TEXT NOT NULL, seller TEXT, amount TEXT, amount_value REAL,
              currency TEXT, price_type TEXT, price TEXT, raw_chat TEXT, created_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_listings_detected ON listings(detected_at_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_listings_type_detected ON listings(price_type, detected_at_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_listings_item ON listings(item_key, price_type, detected_at_epoch DESC);
            CREATE TABLE IF NOT EXISTS alerts (
              id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, query TEXT NOT NULL,
              price_type TEXT NOT NULL DEFAULT 'all', min_amount REAL, max_amount REAL,
              channels TEXT NOT NULL DEFAULT 'site', active INTEGER NOT NULL DEFAULT 1,
              created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS alert_matches (
              id INTEGER PRIMARY KEY AUTOINCREMENT, alert_id INTEGER NOT NULL, listing_id INTEGER NOT NULL,
              user_id INTEGER NOT NULL, created_at INTEGER NOT NULL, seen_at INTEGER,
              UNIQUE(alert_id, listing_id)
            );
            CREATE INDEX IF NOT EXISTS idx_alert_matches_user ON alert_matches(user_id, seen_at, created_at DESC);
            CREATE TABLE IF NOT EXISTS notification_queue (
              id INTEGER PRIMARY KEY AUTOINCREMENT, listing_id INTEGER NOT NULL, alert_id INTEGER NOT NULL DEFAULT 0,
              channel TEXT NOT NULL, destination TEXT NOT NULL, payload TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
              next_attempt_at INTEGER NOT NULL, last_error TEXT, created_at INTEGER NOT NULL, sent_at INTEGER,
              UNIQUE(listing_id, alert_id, channel, destination)
            );
            CREATE INDEX IF NOT EXISTS idx_notification_queue_ready ON notification_queue(status, next_attempt_at);
            CREATE TABLE IF NOT EXISTS service_status (
              name TEXT PRIMARY KEY, status TEXT NOT NULL, detail TEXT, updated_at INTEGER NOT NULL
            );
            """
        )
        user_columns = {row[1] for row in connection.execute("PRAGMA table_info(users)")}
        for name, definition in {
            "discord_user_id": "TEXT",
            "telegram_chat_id": "TEXT",
            "notifications_enabled": "INTEGER NOT NULL DEFAULT 1",
        }.items():
            if name not in user_columns:
                connection.execute(f"ALTER TABLE users ADD COLUMN {name} {definition}")


def update_service_status(config: dict[str, Any], name: str, status: str, detail: str = "") -> None:
    try:
        with database_connection(config) as connection:
            connection.execute(
                """
                INSERT INTO service_status(name, status, detail, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET status=excluded.status, detail=excluded.detail, updated_at=excluded.updated_at
                """,
                (name, status, truncate(detail, 500), int(time.time())),
            )
    except sqlite3.Error as exc:
        print(f"[ERRO STATUS] {exc}", file=sys.stderr, flush=True)


def listing_matches_alert(listing: GtsListing, alert: sqlite3.Row) -> bool:
    searchable = fold_text(f"{listing.item} {listing.seller}")
    if fold_text(str(alert["query"])) not in searchable:
        return False
    if alert["price_type"] not in {"", "all", listing.price_type}:
        return False
    amount = amount_to_float(listing.amount)
    if alert["min_amount"] is not None and (amount is None or amount < float(alert["min_amount"])):
        return False
    if alert["max_amount"] is not None and (amount is None or amount > float(alert["max_amount"])):
        return False
    return True


def enqueue_notification(
    connection: sqlite3.Connection,
    listing_id: int,
    alert_id: int,
    channel: str,
    destination: str,
    payload: dict[str, Any],
) -> None:
    if not destination:
        return
    timestamp = int(time.time())
    connection.execute(
        """
        INSERT OR IGNORE INTO notification_queue
          (listing_id, alert_id, channel, destination, payload, status, next_attempt_at, created_at)
        VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)
        """,
        (listing_id, alert_id, channel, destination, json.dumps(payload, ensure_ascii=False), timestamp, timestamp),
    )


def enqueue_listing_notifications(
    connection: sqlite3.Connection,
    listing_id: int,
    listing: GtsListing,
    message: str,
) -> None:
    base_payload = {"listing": asdict(listing), "message": message, "alert": ""}
    enqueue_notification(connection, listing_id, 0, "discord", os.environ.get("DISCORD_USER_ID", "").strip(), base_payload)
    if telegram_enabled():
        enqueue_notification(connection, listing_id, 0, "telegram", os.environ.get("TELEGRAM_CHAT_ID", "").strip(), base_payload)

    alerts = connection.execute(
        """
        SELECT alerts.*, users.discord_user_id, users.telegram_chat_id
        FROM alerts JOIN users ON users.id = alerts.user_id
        WHERE alerts.active = 1 AND users.status = 'approved' AND users.notifications_enabled = 1
        """
    ).fetchall()
    for alert in alerts:
        if not listing_matches_alert(listing, alert):
            continue
        connection.execute(
            "INSERT OR IGNORE INTO alert_matches(alert_id, listing_id, user_id, created_at) VALUES (?, ?, ?, ?)",
            (alert["id"], listing_id, alert["user_id"], int(time.time())),
        )
        payload = {**base_payload, "alert": str(alert["query"])}
        channels = {value.strip() for value in str(alert["channels"]).split(",")}
        if "discord" in channels:
            enqueue_notification(connection, listing_id, int(alert["id"]), "discord", str(alert["discord_user_id"] or ""), payload)
        if "telegram" in channels:
            enqueue_notification(connection, listing_id, int(alert["id"]), "telegram", str(alert["telegram_chat_id"] or ""), payload)


def append_history(
    config: dict[str, Any],
    listing: GtsListing,
    status: str,
    reason: str = "",
    dry_run: bool = False,
) -> int | None:
    history = history_config(config)
    if not bool(history.get("enabled", True)):
        return None
    if dry_run and not bool(history.get("write_dry_run", False)):
        return None
    if status == "filtered" and not bool(history.get("write_filtered", True)):
        return None

    detected_at = listing.detected_at or datetime.now(timezone.utc).isoformat()
    fingerprint = listing.fingerprint or hashlib.sha256(f"{detected_at}\0{listing.raw_chat}".encode()).hexdigest()
    try:
        detected_epoch = int(datetime.fromisoformat(detected_at.replace("Z", "+00:00")).timestamp())
    except ValueError:
        detected_epoch = int(time.time())

    with database_connection(config) as connection:
        cursor = connection.execute(
            """
            INSERT OR IGNORE INTO listings
              (fingerprint, detected_at, detected_at_epoch, status, reason, item, item_key, seller,
               amount, amount_value, currency, price_type, price, raw_chat, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                fingerprint, detected_at, detected_epoch, status, reason, listing.item, fold_text(listing.item),
                listing.seller, listing.amount, amount_to_float(listing.amount), listing.currency,
                listing.price_type, listing.price, listing.raw_chat, int(time.time()),
            ),
        )
        if cursor.rowcount == 0:
            row = connection.execute("SELECT id FROM listings WHERE fingerprint = ?", (fingerprint,)).fetchone()
            return int(row["id"]) if row else None
        listing_id = int(cursor.lastrowid)
        if status == "sent":
            message = format_message(str(config.get("message_template", "GTS: {pokemon} por {price}")), listing)
            enqueue_listing_notifications(connection, listing_id, listing, message)
        connection.execute(
            """
            INSERT INTO service_status(name, status, detail, updated_at) VALUES ('last_listing', 'online', ?, ?)
            ON CONFLICT(name) DO UPDATE SET status='online', detail=excluded.detail, updated_at=excluded.updated_at
            """,
            (f"{listing.item} | {listing.price}", int(time.time())),
        )
        return listing_id


class NotificationQueueWorker:
    def __init__(self, config: dict[str, Any], discord_token: str):
        self.config = config
        self.discord_token = discord_token
        self.stop_event = threading.Event()
        self.wake_event = threading.Event()
        self.thread = threading.Thread(target=self._run, name="gts-notification-queue", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def wake(self) -> None:
        self.wake_event.set()

    def stop(self) -> None:
        self.stop_event.set()
        self.wake_event.set()
        self.thread.join(timeout=15)

    def _claim(self) -> sqlite3.Row | None:
        with database_connection(self.config) as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                """
                SELECT * FROM notification_queue
                WHERE status IN ('pending', 'retry') AND next_attempt_at <= ? AND attempts < 5
                ORDER BY created_at, id LIMIT 1
                """,
                (int(time.time()),),
            ).fetchone()
            if not row:
                return None
            connection.execute(
                "UPDATE notification_queue SET status = 'processing', attempts = attempts + 1 WHERE id = ?",
                (row["id"],),
            )
            return connection.execute("SELECT * FROM notification_queue WHERE id = ?", (row["id"],)).fetchone()

    def _deliver(self, job: sqlite3.Row) -> None:
        payload = json.loads(str(job["payload"]))
        listing = GtsListing(**payload["listing"])
        alert = str(payload.get("alert", "")).strip()
        if job["channel"] == "discord":
            discord_payload = build_discord_payload(self.config, listing, str(payload["message"]))
            if alert:
                discord_payload["content"] = f"🔔 **Alerta encontrado:** `{truncate(alert, 120)}`"
                discord_payload["allowed_mentions"] = {"parse": []}
            send_dm_payload(self.discord_token, str(job["destination"]), discord_payload)
        elif job["channel"] == "telegram":
            text = format_telegram_listing(listing)
            if alert:
                text = f"🔔 Alerta encontrado: {alert}\n\n{text}"
            send_telegram_chat_text(str(job["destination"]), text)
        else:
            raise RuntimeError(f"Canal de notificação desconhecido: {job['channel']}")

    def _finish(self, job: sqlite3.Row, error: Exception | None = None) -> None:
        timestamp = int(time.time())
        with database_connection(self.config) as connection:
            if error is None:
                connection.execute(
                    "UPDATE notification_queue SET status='sent', sent_at=?, last_error=NULL WHERE id=?",
                    (timestamp, job["id"]),
                )
                status, detail = "online", "última entrega concluída"
            else:
                attempts = int(job["attempts"])
                next_status = "failed" if attempts >= 5 else "retry"
                retry_at = timestamp + min(300, 2 ** attempts)
                connection.execute(
                    "UPDATE notification_queue SET status=?, next_attempt_at=?, last_error=? WHERE id=?",
                    (next_status, retry_at, truncate(str(error), 500), job["id"]),
                )
                status, detail = "error", truncate(str(error), 300)
            connection.execute(
                """
                INSERT INTO service_status(name, status, detail, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET status=excluded.status, detail=excluded.detail, updated_at=excluded.updated_at
                """,
                (str(job["channel"]), status, detail, timestamp),
            )

    def _run(self) -> None:
        with database_connection(self.config) as connection:
            connection.execute("UPDATE notification_queue SET status='retry' WHERE status='processing'")
        while not self.stop_event.is_set():
            job = self._claim()
            if not job:
                self.wake_event.wait(1.0)
                self.wake_event.clear()
                continue
            try:
                self._deliver(job)
            except Exception as exc:
                self._finish(job, exc)
                print(f"[ERRO {str(job['channel']).upper()}] {exc}", file=sys.stderr, flush=True)
            else:
                self._finish(job)
                print(f"Enviado no {job['channel']}: fila #{job['id']}", flush=True)


def fingerprint_line(line: str) -> str:
    return hashlib.sha256(line.encode("utf-8", errors="replace")).hexdigest()


def resolve_log_path(path: Path) -> Path:
    if path.is_dir():
        return path / "latest.log"
    return path


def open_log_file(log_path: Path, seek_to_end: bool):
    log_file = log_path.open("r", encoding="utf-8", errors="replace")
    if seek_to_end:
        log_file.seek(0, os.SEEK_END)
    return log_file


def should_reopen_log(log_path: Path, log_file: Any) -> bool:
    try:
        path_stat = log_path.stat()
    except FileNotFoundError:
        return False

    file_stat = os.fstat(log_file.fileno())
    if (path_stat.st_dev, path_stat.st_ino) != (file_stat.st_dev, file_stat.st_ino):
        return True
    return path_stat.st_size < log_file.tell()


def follow_log(
    log_path: Path,
    patterns: list[re.Pattern[str]],
    config: dict[str, Any],
    token: str,
    dry_run: bool,
) -> None:
    log_path = resolve_log_path(log_path)
    if not log_path.exists():
        raise FileNotFoundError(f"Log não encontrado: {log_path}")

    poll_interval = float(config.get("poll_interval_seconds", 0.5))
    template = str(config.get("message_template", "GTS: {pokemon} por {price}"))
    print_filtered = bool(config.get("print_filtered", False))
    seen: set[str] = set()
    max_seen = int(config.get("max_seen_lines", 2000))
    ensure_storage(config)

    log_file = open_log_file(log_path, seek_to_end=not bool(config.get("read_from_start", False)))
    notifications = None if dry_run else NotificationQueueWorker(config, token)
    if notifications:
        notifications.start()
    last_heartbeat = 0.0
    try:
        print(f"Lendo log: {log_path}", flush=True)
        print("Aguardando anúncios do GTS. Ctrl+C para sair.", flush=True)
        update_service_status(config, "log_watcher", "online", str(log_path))

        while True:
            if time.monotonic() - last_heartbeat >= 5:
                update_service_status(config, "log_watcher", "online", f"monitorando {log_path.name}")
                last_heartbeat = time.monotonic()
            if should_reopen_log(log_path, log_file):
                log_file.close()
                log_file = open_log_file(log_path, seek_to_end=False)
                print("latest.log foi recriado/truncado; leitura reaberta.")

            line = log_file.readline()
            if not line:
                time.sleep(poll_interval)
                continue

            line_id = fingerprint_line(line)
            if line_id in seen:
                continue
            seen.add(line_id)
            if len(seen) > max_seen:
                seen.clear()

            listing = parse_listing(line, patterns)
            if not listing:
                continue

            filter_result = should_send_listing(config, listing)
            if not filter_result.allowed:
                append_history(config, listing, "filtered", filter_result.reason, dry_run=dry_run)
                if dry_run or print_filtered:
                    print(f"[FILTRADO] {filter_result.reason}: {listing.item} por {listing.price}")
                continue

            message = format_message(template, listing)
            if dry_run:
                append_history(config, listing, "dry_run", dry_run=True)
                print(f"[DRY RUN] {message}")
            else:
                append_history(config, listing, "sent")
                notifications.wake() if notifications else None
                print(f"Detectado e enfileirado: {listing.item} por {listing.price}", flush=True)
    finally:
        update_service_status(config, "log_watcher", "offline", "processo encerrado")
        log_file.close()
        notifications.stop() if notifications else None


def get_required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Variável obrigatória ausente: {name}")
    return value


def sample_listing(test_type: str) -> GtsListing:
    if test_type == "money":
        return GtsListing(
            item="[Assombroso] » Marshadow",
            price="$ 18,000,000.00 PokéCoins",
            raw_chat="[GTS Global] ARKIO added a [Assombroso] » Marshadow to the global GTS for $ 18,000,000.00 PokéCoins!",
            seller="ARKIO",
            amount="18,000,000.00",
            currency="PokéCoins",
            price_type="money",
        )
    if test_type == "site":
        return GtsListing(
            item="[Mistico] » Togepi/Togetic/Togekiss",
            price="$3.00 (Saldo no Site)",
            raw_chat="[GTS Global] seSHADOW00757 added a [Mistico] » Togepi/Togetic/Togekiss to the global GTS for $3.00 (Saldo no Site)!",
            seller="seSHADOW00757",
            amount="3.00",
            currency="Saldo no Site",
            price_type="site",
        )
    return GtsListing(
        item="Chave de Shiny Aleatório",
        price="Token 4.00 Tokens",
        raw_chat="[GTS Global] grey_xzfx added a Chave de Shiny Aleatório to the global GTS for Token 4.00 Tokens!",
        seller="grey_xzfx",
        amount="4.00",
        currency="Tokens",
        price_type="token",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Envia anúncios do Pixelmon GTS para DM no Discord.")
    parser.add_argument("--dry-run", action="store_true", help="Detecta anúncios sem enviar mensagem no Discord.")
    parser.add_argument("--test-line", help="Testa o parser com uma linha de log e sai.")
    parser.add_argument("--test-discord", action="store_true", help="Envia uma DM de teste e sai.")
    parser.add_argument("--test-telegram", action="store_true", help="Envia uma mensagem de teste no Telegram e sai.")
    parser.add_argument("--telegram-updates", action="store_true", help="Lista chats recentes do bot para descobrir TELEGRAM_CHAT_ID.")
    parser.add_argument("--announce-site", help="Envia o link público do painel para um canal do Discord e sai.")
    parser.add_argument(
        "--test-type",
        choices=["token", "money", "site"],
        default="token",
        help="Tipo usado com --test-discord.",
    )
    args = parser.parse_args()

    load_dotenv(ENV_PATH)
    config = load_config(CONFIG_PATH)
    patterns = compile_patterns(config)

    if args.test_line:
        listing = parse_listing(args.test_line, patterns)
        if not listing:
            print("Não detectou anúncio GTS nessa linha.")
            return 1
        print(json.dumps(listing.__dict__, ensure_ascii=False, indent=2))
        return 0

    if args.telegram_updates:
        print_telegram_updates()
        return 0

    if args.test_telegram:
        listing = sample_listing(args.test_type)
        send_telegram_text(format_telegram_listing(listing))
        print("Mensagem de teste enviada no Telegram.")
        return 0

    token = get_required_env("DISCORD_BOT_TOKEN")

    if args.announce_site:
        guild_id = get_required_env("DISCORD_GUILD_ID")
        channel_id = get_required_env("DISCORD_ANNOUNCE_CHANNEL_ID")
        site_url = args.announce_site.rstrip("/")
        message_id, pin_error = upsert_pinned_site_message(token, channel_id, format_site_message(site_url))
        permanent_access_url = f"https://discord.com/channels/{guild_id}/{channel_id}/{message_id}"
        PERMANENT_ACCESS_URL_PATH.write_text(permanent_access_url + "\n", encoding="utf-8")
        print(f"Mensagem oficial do site atualizada no Discord: {message_id}")
        print(f"Link fixo de acesso: {permanent_access_url}")
        if pin_error:
            print(f"[AVISO PIN DISCORD] {pin_error}", file=sys.stderr)
        else:
            print("Mensagem oficial fixada no canal do Discord.")
        send_telegram_text_optional(format_telegram_site(site_url, permanent_access_url))
        return 0

    user_id = get_required_env("DISCORD_USER_ID")

    if args.test_discord:
        listing = sample_listing(args.test_type)
        message = format_message(str(config.get("message_template", "GTS: {item} por {price}")), listing)
        send_dm_payload(token, user_id, build_discord_payload(config, listing, message))
        print("DM de teste enviada.")
        return 0

    log_path = Path(get_required_env("MINECRAFT_LOG_PATH")).expanduser()

    follow_log(
        log_path=log_path,
        patterns=patterns,
        config=config,
        token=token,
        dry_run=args.dry_run,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nEncerrado.")
        raise SystemExit(0)
    except Exception as exc:
        print(f"Erro: {exc}", file=sys.stderr)
        raise SystemExit(1)
