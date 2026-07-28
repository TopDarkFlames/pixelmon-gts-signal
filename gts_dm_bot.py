#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import base64
import random
import re
import sqlite3
import socket
import ssl
import struct
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, replace
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
DISCORD_GATEWAY_HOST = "gateway.discord.gg"
DISCORD_GATEWAY_PATH = "/?v=10&encoding=json"
TELEGRAM_API = "https://api.telegram.org"
DISCORD_TIMEOUT_SECONDS = 8
TELEGRAM_TIMEOUT_SECONDS = 6
GLOBAL_GTS_MARKER = re.compile(r"\bto\s+the\s+global\s+GTS\s+for\b", re.IGNORECASE)
POKEMON_HOVER_MARKERS = ("ability:", "nature:", "ivs:", "evs:", "moves:")
STAT_NAMES = {
    "hp": "hp",
    "atk": "attack",
    "def": "defense",
    "spa": "sp_attack",
    "spd": "sp_defense",
    "spe": "speed",
}


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
    source: str = "log"
    hover_action: str = ""
    hover_payload: str = ""
    is_pokemon: bool = False
    ability: str = ""
    hidden_ability: bool = False
    nature: str = ""
    gender: str = ""
    size: str = ""
    texture: str = ""
    unbreedable: str = ""
    iv_total: int | None = None
    iv_max: int | None = None
    iv_percent: float | None = None
    iv_hp: int | None = None
    iv_attack: int | None = None
    iv_defense: int | None = None
    iv_sp_attack: int | None = None
    iv_sp_defense: int | None = None
    iv_speed: int | None = None
    ev_total: int | None = None
    ev_max: int | None = None
    ev_percent: float | None = None
    ev_hp: int | None = None
    ev_attack: int | None = None
    ev_defense: int | None = None
    ev_sp_attack: int | None = None
    ev_sp_defense: int | None = None
    ev_speed: int | None = None
    moves: tuple[str, ...] = ()

    @property
    def pokemon(self) -> str:
        return self.item


@dataclass(frozen=True)
class FilterResult:
    allowed: bool
    reason: str = ""


LISTING_DETAIL_COLUMNS = {
    "source": "TEXT NOT NULL DEFAULT 'log'",
    "hover_action": "TEXT",
    "hover_payload": "TEXT",
    "is_pokemon": "INTEGER NOT NULL DEFAULT 0",
    "ability": "TEXT",
    "hidden_ability": "INTEGER NOT NULL DEFAULT 0",
    "nature": "TEXT",
    "gender": "TEXT",
    "pokemon_size": "TEXT",
    "texture": "TEXT",
    "unbreedable": "TEXT",
    "iv_total": "INTEGER",
    "iv_max": "INTEGER",
    "iv_percent": "REAL",
    "iv_hp": "INTEGER",
    "iv_attack": "INTEGER",
    "iv_defense": "INTEGER",
    "iv_sp_attack": "INTEGER",
    "iv_sp_defense": "INTEGER",
    "iv_speed": "INTEGER",
    "ev_total": "INTEGER",
    "ev_max": "INTEGER",
    "ev_percent": "REAL",
    "ev_hp": "INTEGER",
    "ev_attack": "INTEGER",
    "ev_defense": "INTEGER",
    "ev_sp_attack": "INTEGER",
    "ev_sp_defense": "INTEGER",
    "ev_speed": "INTEGER",
    "moves_json": "TEXT",
}

ALERT_DETAIL_COLUMNS = {
    "match_mode": "TEXT NOT NULL DEFAULT 'text'",
    "texture_query": "TEXT",
    "min_iv_percent": "REAL",
    "hidden_ability_only": "INTEGER NOT NULL DEFAULT 0",
}


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
    if "[gtsbridge]" in strip_minecraft_codes(log_line).casefold():
        return None

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


def parse_stat_values(section: str) -> dict[str, int]:
    values: dict[str, int] = {}
    clean = strip_minecraft_codes(section)
    pattern = re.compile(r"\b(HP|Atk|Def|SpA|SpD|Spe):\s*(\d+)(?:\s*->\s*(\d+))?", re.IGNORECASE)
    for match in pattern.finditer(clean):
        key = STAT_NAMES[match.group(1).casefold()]
        values[key] = int(match.group(3) or match.group(2))
    return values


def parse_pokemon_hover(hover_text: str) -> dict[str, Any] | None:
    clean = strip_minecraft_codes(hover_text).replace("\r\n", "\n").replace("\r", "\n")
    folded = clean.casefold()
    if not all(marker in folded for marker in POKEMON_HOVER_MARKERS):
        return None

    details: dict[str, Any] = {}
    for label, key in {
        "Nature": "nature",
        "Gender": "gender",
        "Size": "size",
        "Texture": "texture",
        "Unbreedable": "unbreedable",
    }.items():
        match = re.search(rf"(?im)^\s*{label}:\s*(.+?)\s*$", clean)
        details[key] = normalize_field(match.group(1)) if match else ""

    ability_match = re.search(r"(?im)^\s*Ability:\s*(.+?)\s*$", clean)
    raw_ability = re.sub(r"\s+", " ", ability_match.group(1)).strip() if ability_match else ""
    details["hidden_ability"] = bool(
        re.search(r"\(\s*HA\s*\)|\bHidden Ability\b", raw_ability, re.IGNORECASE)
    )
    details["ability"] = normalize_field(
        re.sub(r"\(\s*HA\s*\)|\bHidden Ability\b", "", raw_ability, flags=re.IGNORECASE)
    )

    for prefix, next_prefix in (("iv", "EVs:"), ("ev", "Moves:")):
        heading = "IVs:" if prefix == "iv" else "EVs:"
        match = re.search(
            rf"(?is){heading}\s*(\d+)\s*/\s*(\d+)\s*\(([0-9.]+)%\)(.*?)(?=^\s*{next_prefix}|\Z)",
            clean,
            re.MULTILINE,
        )
        if not match:
            continue
        details[f"{prefix}_total"] = int(match.group(1))
        details[f"{prefix}_max"] = int(match.group(2))
        details[f"{prefix}_percent"] = float(match.group(3))
        for stat, value in parse_stat_values(match.group(4)).items():
            details[f"{prefix}_{stat}"] = value

    moves_match = re.search(r"(?is)^\s*Moves:\s*\n\s*(.+?)\s*$", clean, re.MULTILINE)
    details["moves"] = tuple(
        normalize_field(move) for move in (moves_match.group(1).split("|") if moves_match else [])
        if normalize_field(move) and fold_text(normalize_field(move)) != "none"
    )
    return details


def parse_bridge_capture(raw_line: str, patterns: list[re.Pattern[str]]) -> GtsListing | None:
    try:
        capture = json.loads(raw_line)
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(capture, dict):
        return None

    raw_chat = str(capture.get("unformatted", ""))
    listing = parse_listing(raw_chat, patterns)
    if not listing:
        return None

    hover_events = capture.get("hoverEvents", [])
    hover_events = hover_events if isinstance(hover_events, list) else []
    selected_hover: dict[str, Any] = {}
    pokemon_details: dict[str, Any] | None = None
    texture_token = ""

    for candidate in hover_events:
        if not isinstance(candidate, dict):
            continue
        value = str(candidate.get("valueUnformatted", ""))
        details = parse_pokemon_hover(value)
        if details:
            selected_hover = candidate
            pokemon_details = details
            break
        if not selected_hover:
            selected_hover = candidate
        token_match = re.search(r'(?:TextureTokenID|CustomTexture)\s*:\s*"([^"\\]+)"', value)
        if token_match:
            texture_token = token_match.group(1)
            selected_hover = candidate

    captured_at = str(capture.get("capturedAt", "")) or datetime.now(timezone.utc).isoformat()
    fingerprint = hashlib.sha256(
        f"bridge\0{captured_at}\0{raw_chat}".encode("utf-8", errors="replace")
    ).hexdigest()
    hover_payload = str(selected_hover.get("valueUnformatted", ""))
    base_changes: dict[str, Any] = {
        "detected_at": captured_at,
        "fingerprint": fingerprint,
        "source": "bridge",
        "hover_action": str(selected_hover.get("action", "")),
        "hover_payload": hover_payload,
        "texture": texture_token,
    }
    if pokemon_details:
        base_changes.update(pokemon_details)
        base_changes["is_pokemon"] = True
    return replace(listing, **base_changes)


def listing_signature(listing: GtsListing) -> str:
    normalized = re.sub(r"\s+", " ", strip_minecraft_codes(listing.raw_chat)).strip().casefold()
    return hashlib.sha256(normalized.encode("utf-8", errors="replace")).hexdigest()


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


def format_site_unavailable_message(reason: str) -> str:
    reason = reason.strip() or "aguardando a Cloudflare liberar um novo endereço"
    updated_at = int(time.time())
    return (
        "📡 **PAINEL PIXELMON GTS — LINK OFICIAL**\n"
        "Esta mensagem é atualizada automaticamente quando o endereço muda.\n\n"
        "🔄 **Status:** reconectando o túnel público\n"
        f"🧭 **Motivo:** {reason}\n"
        "🏠 **Painel local:** http://127.0.0.1:8080\n\n"
        f"🟡 Reconectando • Atualizado <t:{updated_at}:R>"
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
    message = (
        f"{marker} GTS Global | {friendly_price_type(listing)}\n"
        f"💎 Item/Pokémon: {listing.item}\n"
        f"💰 Preço: {price_display}\n"
        f"👤 Vendedor: {listing.seller or 'desconhecido'}\n"
        f"🧾 Original: {listing.price}"
    )
    if listing.is_pokemon:
        message += (
            f"\n\n🧬 Nature: {listing.nature or 'desconhecida'}"
            f"\n⚡ Ability: {listing.ability or 'desconhecida'}"
            f"\n🎨 Textura: {listing.texture or 'desconhecida'}"
            f"\n📊 IVs: {format_iv_summary(listing)}{' • HA' if listing.hidden_ability else ''}"
        )
        if listing.moves:
            message += f"\n🥊 Golpes: {' | '.join(listing.moves)}"
    elif listing.texture:
        message += f"\n🎨 Textura detectada: {listing.texture}"
    return message


def format_telegram_site(site_url: str, permanent_access_url: str) -> str:
    site_url = site_url.rstrip("/")
    return (
        "📡 Painel Pixelmon GTS online\n\n"
        f"🔗 Acessar: {site_url}\n"
        f"📌 Link fixo no Discord: {permanent_access_url}\n"
        f"📝 Registro: {site_url}/register\n"
        f"🛡️ Admin: {site_url}/admin"
    )


def format_telegram_site_unavailable(reason: str, permanent_access_url: str) -> str:
    reason = reason.strip() or "aguardando a Cloudflare liberar um novo endereço"
    return (
        "📡 Painel Pixelmon GTS\n\n"
        "🔄 Link público reconectando\n"
        f"🧭 Motivo: {reason}\n"
        f"📌 Mensagem fixa no Discord: {permanent_access_url}"
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


def format_iv_summary(listing: GtsListing) -> str:
    if listing.iv_total is None or listing.iv_max is None:
        return "não informado"
    percentage = f" ({listing.iv_percent:.2f}%)" if listing.iv_percent is not None else ""
    return f"{listing.iv_total}/{listing.iv_max}{percentage}"


def format_stat_line(listing: GtsListing, prefix: str) -> str:
    labels = (
        ("HP", "hp"), ("Atk", "attack"), ("Def", "defense"),
        ("SpA", "sp_attack"), ("SpD", "sp_defense"), ("Spe", "speed"),
    )
    parts = []
    for label, name in labels:
        value = getattr(listing, f"{prefix}_{name}")
        parts.append(f"{label} {value if value is not None else '—'}")
    return " • ".join(parts)


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
    if listing.is_pokemon:
        fields.extend([
            {
                "name": "🧬 Nature / Ability",
                "value": f"**{truncate(listing.nature or 'desconhecida', 100)}** • {truncate(listing.ability or 'desconhecida', 180)}{' • **HA**' if listing.hidden_ability else ''}",
                "inline": True,
            },
            {
                "name": "🎨 Textura",
                "value": f"**{truncate(listing.texture or 'desconhecida', 240)}**",
                "inline": True,
            },
            {
                "name": f"📊 IVs{' • HA' if listing.hidden_ability else ''}",
                "value": f"**{format_iv_summary(listing)}**\n{truncate(format_stat_line(listing, 'iv'), 900)}",
                "inline": False,
            },
        ])
        if listing.moves:
            fields.append({"name": "🥊 Golpes", "value": truncate(" • ".join(listing.moves), 1000), "inline": False})
    elif listing.texture:
        fields.append({"name": "🎨 Textura detectada", "value": f"`{truncate(listing.texture, 900)}`", "inline": False})
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
              currency TEXT, price_type TEXT, price TEXT, raw_chat TEXT, created_at INTEGER NOT NULL,
              source TEXT NOT NULL DEFAULT 'log', hover_action TEXT, hover_payload TEXT,
              is_pokemon INTEGER NOT NULL DEFAULT 0, ability TEXT,
              hidden_ability INTEGER NOT NULL DEFAULT 0, nature TEXT, gender TEXT,
              pokemon_size TEXT, texture TEXT, unbreedable TEXT,
              iv_total INTEGER, iv_max INTEGER, iv_percent REAL, iv_hp INTEGER, iv_attack INTEGER,
              iv_defense INTEGER, iv_sp_attack INTEGER, iv_sp_defense INTEGER, iv_speed INTEGER,
              ev_total INTEGER, ev_max INTEGER, ev_percent REAL, ev_hp INTEGER, ev_attack INTEGER,
              ev_defense INTEGER, ev_sp_attack INTEGER, ev_sp_defense INTEGER, ev_speed INTEGER,
              moves_json TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_listings_detected ON listings(detected_at_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_listings_type_detected ON listings(price_type, detected_at_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_listings_item ON listings(item_key, price_type, detected_at_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_listings_seller_lower ON listings(lower(seller), detected_at_epoch DESC);
            CREATE TABLE IF NOT EXISTS alerts (
              id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, query TEXT NOT NULL,
              price_type TEXT NOT NULL DEFAULT 'all', min_amount REAL, max_amount REAL,
              match_mode TEXT NOT NULL DEFAULT 'text', texture_query TEXT, min_iv_percent REAL,
              hidden_ability_only INTEGER NOT NULL DEFAULT 0,
              channels TEXT NOT NULL DEFAULT 'site', active INTEGER NOT NULL DEFAULT 1,
              created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS alert_matches (
              id INTEGER PRIMARY KEY AUTOINCREMENT, alert_id INTEGER NOT NULL, listing_id INTEGER NOT NULL,
              user_id INTEGER NOT NULL, created_at INTEGER NOT NULL, seen_at INTEGER,
              UNIQUE(alert_id, listing_id)
            );
            CREATE INDEX IF NOT EXISTS idx_alert_matches_user ON alert_matches(user_id, seen_at, created_at DESC);
            CREATE TABLE IF NOT EXISTS favorites (
              id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL,
              kind TEXT NOT NULL, value TEXT NOT NULL, value_key TEXT NOT NULL, created_at INTEGER NOT NULL,
              UNIQUE(user_id, kind, value_key)
            );
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
            CREATE TABLE IF NOT EXISTS item_stats (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              item_key TEXT NOT NULL, texture_key TEXT NOT NULL, price_type TEXT NOT NULL,
              sample_item TEXT NOT NULL, sample_texture TEXT, sample_currency TEXT,
              last_seller TEXT, last_amount TEXT, last_price TEXT,
              is_pokemon INTEGER NOT NULL DEFAULT 0, hidden_ability INTEGER NOT NULL DEFAULT 0, iv_percent REAL,
              appearances INTEGER NOT NULL DEFAULT 0, first_seen_epoch INTEGER NOT NULL, last_seen_epoch INTEGER NOT NULL,
              last_listing_id INTEGER NOT NULL, min_amount REAL, median_amount REAL, max_amount REAL,
              amount_sum REAL NOT NULL DEFAULT 0, amount_count INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              UNIQUE(item_key, texture_key, price_type)
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
        listing_columns = {row[1] for row in connection.execute("PRAGMA table_info(listings)")}
        for name, definition in LISTING_DETAIL_COLUMNS.items():
            if name not in listing_columns:
                connection.execute(f"ALTER TABLE listings ADD COLUMN {name} {definition}")
        alert_columns = {row[1] for row in connection.execute("PRAGMA table_info(alerts)")}
        for name, definition in ALERT_DETAIL_COLUMNS.items():
            if name not in alert_columns:
                connection.execute(f"ALTER TABLE alerts ADD COLUMN {name} {definition}")
        connection.executescript(
            """
            CREATE INDEX IF NOT EXISTS idx_listings_texture_detected ON listings(texture, detected_at_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_listings_sent_texture ON listings(status, item_key, price_type, texture, detected_at_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_listings_sent_iv ON listings(status, is_pokemon, iv_percent DESC, detected_at_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_alerts_texture ON alerts(active, texture_query, min_iv_percent, hidden_ability_only);
            CREATE INDEX IF NOT EXISTS idx_item_stats_last_seen ON item_stats(last_seen_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_item_stats_texture ON item_stats(texture_key, appearances, last_seen_epoch DESC);
            CREATE INDEX IF NOT EXISTS idx_item_stats_item ON item_stats(item_key, price_type, last_seen_epoch DESC);
            """
        )
        connection.execute(
            "UPDATE listings SET hidden_ability=1 "
            "WHERE lower(COALESCE(ability, '')) LIKE '%(ha%'"
        )
        duplicate_ids = connection.execute(
            "SELECT id FROM listings WHERE lower(raw_chat) LIKE '%[gtsbridge]%' AND status != 'invalid'"
        ).fetchall()
        duplicated_bridge_rows = bool(duplicate_ids)
        if duplicate_ids:
            placeholders = ",".join("?" for _ in duplicate_ids)
            ids = [row[0] for row in duplicate_ids]
            connection.execute(
                f"UPDATE notification_queue SET status='cancelled', last_error='duplicate_bridge_logger' "
                f"WHERE listing_id IN ({placeholders}) AND status IN ('pending','retry','processing')",
                ids,
            )
            connection.execute(
                f"UPDATE listings SET status='invalid', reason='duplicate_bridge_logger' "
                f"WHERE id IN ({placeholders})",
                ids,
            )
        if duplicated_bridge_rows or connection.execute("SELECT COUNT(*) FROM item_stats").fetchone()[0] == 0:
            rebuild_item_stats(connection)


def row_value(row: sqlite3.Row, key: str, default: Any = None) -> Any:
    try:
        return row[key]
    except (IndexError, KeyError):
        return default


def texture_key(value: str) -> str:
    key = re.sub(r"[^a-z0-9]+", "", fold_text(str(value or "")))
    return key or "original"


def percentile(sorted_values: list[float], fraction: float) -> float | None:
    if not sorted_values:
        return None
    position = (len(sorted_values) - 1) * fraction
    lower = sorted_values[int(position)]
    upper = sorted_values[min(int(position) + (0 if position.is_integer() else 1), len(sorted_values) - 1)]
    return lower + ((upper - lower) * (position - int(position)))


def upsert_item_stats(
    connection: sqlite3.Connection,
    item_key: str,
    texture_key_value: str,
    price_type: str,
    rows: list[sqlite3.Row],
) -> None:
    if not rows:
        return
    latest = max(rows, key=lambda row: int(row["detected_at_epoch"] or 0))
    first = min(rows, key=lambda row: int(row["detected_at_epoch"] or 0))
    amounts = sorted(
        float(row["amount_value"]) for row in rows
        if row["amount_value"] is not None and float(row["amount_value"]) > 0
    )
    timestamp = int(time.time())
    connection.execute(
        """
        INSERT INTO item_stats(
          item_key, texture_key, price_type, sample_item, sample_texture, sample_currency,
          last_seller, last_amount, last_price, is_pokemon, hidden_ability, iv_percent,
          appearances, first_seen_epoch, last_seen_epoch, last_listing_id,
          min_amount, median_amount, max_amount, amount_sum, amount_count, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(item_key, texture_key, price_type) DO UPDATE SET
          sample_item=excluded.sample_item, sample_texture=excluded.sample_texture,
          sample_currency=excluded.sample_currency, last_seller=excluded.last_seller,
          last_amount=excluded.last_amount, last_price=excluded.last_price,
          is_pokemon=excluded.is_pokemon, hidden_ability=excluded.hidden_ability,
          iv_percent=excluded.iv_percent, appearances=excluded.appearances,
          first_seen_epoch=excluded.first_seen_epoch, last_seen_epoch=excluded.last_seen_epoch,
          last_listing_id=excluded.last_listing_id, min_amount=excluded.min_amount,
          median_amount=excluded.median_amount, max_amount=excluded.max_amount,
          amount_sum=excluded.amount_sum, amount_count=excluded.amount_count,
          updated_at=excluded.updated_at
        """,
        (
            item_key, texture_key_value, price_type, latest["item"], latest["texture"], latest["currency"],
            latest["seller"], latest["amount"], latest["price"], int(latest["is_pokemon"] or 0),
            int(latest["hidden_ability"] or 0), latest["iv_percent"], len(rows),
            int(first["detected_at_epoch"] or 0), int(latest["detected_at_epoch"] or 0),
            int(latest["id"]), min(amounts) if amounts else None, percentile(amounts, 0.5),
            max(amounts) if amounts else None, sum(amounts), len(amounts), timestamp, timestamp,
        ),
    )


def rebuild_item_stats(connection: sqlite3.Connection) -> None:
    connection.execute("DELETE FROM item_stats")
    grouped: dict[tuple[str, str, str], list[sqlite3.Row]] = {}
    for row in connection.execute("SELECT * FROM listings WHERE status='sent'"):
        key = (
            str(row["item_key"] or ""),
            texture_key(str(row["texture"] or "")),
            str(row["price_type"] or "unknown") or "unknown",
        )
        grouped.setdefault(key, []).append(row)
    for (item_key, texture_key_value, price_type), rows in grouped.items():
        upsert_item_stats(connection, item_key, texture_key_value, price_type, rows)


def update_item_stats(connection: sqlite3.Connection, listing_id: int) -> None:
    row = connection.execute("SELECT * FROM listings WHERE id=? AND status='sent'", (listing_id,)).fetchone()
    if not row:
        return
    item_key = str(row["item_key"] or "")
    raw_price_type = str(row["price_type"] or "")
    price_type = raw_price_type or "unknown"
    texture_key_value = texture_key(str(row["texture"] or ""))
    rows = [
        candidate
        for candidate in connection.execute(
            "SELECT * FROM listings WHERE status='sent' AND item_key=? AND COALESCE(price_type,'')=?",
            (item_key, raw_price_type),
        ).fetchall()
        if texture_key(str(candidate["texture"] or "")) == texture_key_value
    ]
    upsert_item_stats(connection, item_key, texture_key_value, price_type, rows)


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


def read_exact(sock: ssl.SSLSocket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("conexão WebSocket encerrada")
        data.extend(chunk)
    return bytes(data)


def websocket_accept_value(key: str) -> str:
    digest = hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def websocket_connect(host: str, path: str) -> ssl.SSLSocket:
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    raw = socket.create_connection((host, 443), timeout=15)
    sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "User-Agent: pixelmon-gts-discord (local script)\r\n"
        "\r\n"
    )
    sock.sendall(request.encode("ascii"))
    response = bytearray()
    while b"\r\n\r\n" not in response:
        response.extend(sock.recv(4096))
        if len(response) > 16_384:
            raise ConnectionError("resposta WebSocket grande demais")

    headers = response.decode("iso-8859-1", errors="replace")
    if " 101 " not in headers.split("\r\n", 1)[0]:
        raise ConnectionError(f"Discord Gateway recusou WebSocket: {headers.splitlines()[0]}")
    expected = websocket_accept_value(key).casefold()
    if f"sec-websocket-accept: {expected}" not in headers.casefold():
        raise ConnectionError("Discord Gateway retornou handshake WebSocket inválido")
    sock.settimeout(1)
    return sock


def websocket_send(sock: ssl.SSLSocket, payload: bytes, opcode: int = 1) -> None:
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65_536:
        header.extend([0x80 | 126])
        header.extend(struct.pack("!H", length))
    else:
        header.extend([0x80 | 127])
        header.extend(struct.pack("!Q", length))
    mask = os.urandom(4)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(bytes(header) + mask + masked)


def websocket_send_json(sock: ssl.SSLSocket, payload: dict[str, Any]) -> None:
    websocket_send(sock, json.dumps(payload, separators=(",", ":")).encode("utf-8"))


def websocket_read(sock: ssl.SSLSocket) -> tuple[int, bytes]:
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(sock, 8))[0]
    mask = read_exact(sock, 4) if masked else b""
    payload = read_exact(sock, length) if length else b""
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload


class DiscordGatewayPresence:
    def __init__(self, config: dict[str, Any], token: str) -> None:
        self.config = config
        self.token = token
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.run, name="discord-gateway-presence", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=3)

    def run(self) -> None:
        backoff = 2.0
        while not self.stop_event.is_set():
            try:
                self.connect_once()
                backoff = 2.0
            except Exception as exc:
                update_service_status(self.config, "discord_gateway", "offline", str(exc))
                print(f"[DISCORD GATEWAY] {exc}", file=sys.stderr, flush=True)
                self.stop_event.wait(backoff)
                backoff = min(backoff * 1.8, 60)

    def connect_once(self) -> None:
        update_service_status(self.config, "discord_gateway", "connecting", "abrindo Gateway")
        sock = websocket_connect(DISCORD_GATEWAY_HOST, DISCORD_GATEWAY_PATH)
        sequence: int | None = None
        heartbeat_interval = 45.0
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                opcode, payload = websocket_read(sock)
                if opcode == 8:
                    raise ConnectionError("Discord fechou o Gateway antes do hello")
                if opcode == 9:
                    websocket_send(sock, payload, opcode=10)
                    continue
                if opcode != 1:
                    continue
                message = json.loads(payload.decode("utf-8"))
                if message.get("op") == 10:
                    heartbeat_interval = max(float(message["d"]["heartbeat_interval"]) / 1000.0, 5.0)
                    break
            else:
                raise TimeoutError("Discord Gateway não enviou hello")

            websocket_send_json(sock, {
                "op": 2,
                "d": {
                    "token": self.token,
                    "intents": 0,
                    "properties": {
                        "os": sys.platform,
                        "browser": "pixelmon-gts",
                        "device": "pixelmon-gts",
                    },
                    "presence": {
                        "status": "online",
                        "since": None,
                        "activities": [{"name": "GTS Global", "type": 3}],
                        "afk": False,
                    },
                },
            })
            next_heartbeat = time.monotonic() + random.uniform(0.2, min(heartbeat_interval, 5.0))
            update_service_status(self.config, "discord_gateway", "online", "presence online")

            while not self.stop_event.is_set():
                if time.monotonic() >= next_heartbeat:
                    websocket_send_json(sock, {"op": 1, "d": sequence})
                    next_heartbeat = time.monotonic() + heartbeat_interval
                try:
                    opcode, payload = websocket_read(sock)
                except socket.timeout:
                    continue
                if opcode == 8:
                    raise ConnectionError("Discord fechou o Gateway")
                if opcode == 9:
                    websocket_send(sock, payload, opcode=10)
                    continue
                if opcode != 1:
                    continue
                message = json.loads(payload.decode("utf-8"))
                if message.get("s") is not None:
                    sequence = int(message["s"])
                op = message.get("op")
                if op == 0 and message.get("t") == "READY":
                    update_service_status(self.config, "discord_gateway", "online", "READY")
                elif op == 7:
                    raise ConnectionError("Discord pediu reconexão")
                elif op == 9:
                    raise ConnectionError("sessão Gateway inválida")
                elif op == 10:
                    heartbeat_interval = max(float(message["d"]["heartbeat_interval"]) / 1000.0, 5.0)
        finally:
            try:
                websocket_send(sock, b"", opcode=8)
            except Exception:
                pass
            sock.close()


def listing_matches_alert(listing: GtsListing, alert: sqlite3.Row) -> bool:
    query = fold_text(str(row_value(alert, "query", ""))).strip()
    mode = str(row_value(alert, "match_mode", "text") or "text")
    if mode == "seller":
        searchable = fold_text(listing.seller)
    elif mode in {"item", "pokemon"}:
        searchable = fold_text(listing.item)
    elif mode == "texture":
        searchable = fold_text(listing.texture)
    else:
        searchable = fold_text(
            f"{listing.item} {listing.seller} {listing.texture} {listing.ability} "
            f"{listing.nature} {listing.raw_chat}"
        )
    if query and query not in searchable:
        return False
    if row_value(alert, "price_type") not in {"", "all", listing.price_type}:
        return False
    amount = amount_to_float(listing.amount)
    if row_value(alert, "min_amount") is not None and (amount is None or amount < float(alert["min_amount"])):
        return False
    if row_value(alert, "max_amount") is not None and (amount is None or amount > float(alert["max_amount"])):
        return False

    texture_query = fold_text(str(row_value(alert, "texture_query", "") or "")).strip()
    listing_texture = fold_text(listing.texture).strip()
    if texture_query:
        if texture_query in {"custom", "txt", "textura", "textura custom", "customizada", "qualquer txt"}:
            if not listing_texture or listing_texture == "original":
                return False
        elif texture_query == "original":
            if listing_texture != "original":
                return False
        elif texture_query not in listing_texture:
            return False

    if int(row_value(alert, "hidden_ability_only", 0) or 0) == 1 and not listing.hidden_ability:
        return False
    min_iv = row_value(alert, "min_iv_percent")
    if min_iv is not None and (listing.iv_percent is None or listing.iv_percent < float(min_iv)):
        return False
    return True


def alert_label(alert: sqlite3.Row) -> str:
    pieces = [str(row_value(alert, "query", "")).strip()]
    texture_query = str(row_value(alert, "texture_query", "") or "").strip()
    if texture_query:
        pieces.append("TXT custom" if fold_text(texture_query) in {"custom", "txt", "textura", "customizada", "qualquer txt"} else f"TXT {texture_query}")
    min_iv = row_value(alert, "min_iv_percent")
    if min_iv is not None:
        pieces.append(f"IV >= {float(min_iv):.0f}%")
    if int(row_value(alert, "hidden_ability_only", 0) or 0) == 1:
        pieces.append("HA")
    return " · ".join(piece for piece in pieces if piece) or "Alerta"


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
        payload = {**base_payload, "alert": alert_label(alert)}
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
               amount, amount_value, currency, price_type, price, raw_chat, created_at,
               source, hover_action, hover_payload, is_pokemon, ability, hidden_ability, nature, gender, pokemon_size,
               texture, unbreedable, iv_total, iv_max, iv_percent, iv_hp, iv_attack, iv_defense,
               iv_sp_attack, iv_sp_defense, iv_speed, ev_total, ev_max, ev_percent, ev_hp, ev_attack,
               ev_defense, ev_sp_attack, ev_sp_defense, ev_speed, moves_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                fingerprint, detected_at, detected_epoch, status, reason, listing.item, fold_text(listing.item),
                listing.seller, listing.amount, amount_to_float(listing.amount), listing.currency,
                listing.price_type, listing.price, listing.raw_chat, int(time.time()), listing.source,
                listing.hover_action, listing.hover_payload, int(listing.is_pokemon), listing.ability,
                int(listing.hidden_ability), listing.nature, listing.gender, listing.size, listing.texture, listing.unbreedable,
                listing.iv_total, listing.iv_max, listing.iv_percent, listing.iv_hp, listing.iv_attack,
                listing.iv_defense, listing.iv_sp_attack, listing.iv_sp_defense, listing.iv_speed,
                listing.ev_total, listing.ev_max, listing.ev_percent, listing.ev_hp, listing.ev_attack,
                listing.ev_defense, listing.ev_sp_attack, listing.ev_sp_defense, listing.ev_speed,
                json.dumps(listing.moves, ensure_ascii=False),
            ),
        )
        if cursor.rowcount == 0:
            row = connection.execute("SELECT id FROM listings WHERE fingerprint = ?", (fingerprint,)).fetchone()
            return int(row["id"]) if row else None
        listing_id = int(cursor.lastrowid)
        if status == "sent":
            update_item_stats(connection, listing_id)
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


def resolve_bridge_capture_path(log_path: Path, config: dict[str, Any]) -> Path:
    bridge = config.get("gts_bridge", {})
    bridge = bridge if isinstance(bridge, dict) else {}
    configured = os.environ.get("GTS_BRIDGE_PATH", "").strip() or str(bridge.get("path", "")).strip()
    if configured:
        path = Path(configured).expanduser()
        return path if path.is_absolute() else BASE_DIR / path

    resolved_log = resolve_log_path(log_path)
    minecraft_directory = resolved_log.parent.parent if resolved_log.parent.name == "logs" else resolved_log.parent
    return minecraft_directory / "gts-bridge" / "captures.jsonl"


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


def process_detected_listing(
    listing: GtsListing,
    config: dict[str, Any],
    template: str,
    print_filtered: bool,
    dry_run: bool,
    notifications: NotificationQueueWorker | None,
) -> None:
    filter_result = should_send_listing(config, listing)
    if not filter_result.allowed:
        append_history(config, listing, "filtered", filter_result.reason, dry_run=dry_run)
        if dry_run or print_filtered:
            print(f"[FILTRADO] {filter_result.reason}: {listing.item} por {listing.price}")
        return

    message = format_message(template, listing)
    if dry_run:
        append_history(config, listing, "dry_run", dry_run=True)
        print(f"[DRY RUN] {message}")
        return

    append_history(config, listing, "sent")
    notifications.wake() if notifications else None
    detail = " com dados do Pokémon" if listing.is_pokemon else ""
    print(f"Detectado e enfileirado{detail}: {listing.item} por {listing.price}", flush=True)


def follow_log(
    log_path: Path,
    patterns: list[re.Pattern[str]],
    config: dict[str, Any],
    token: str,
    dry_run: bool,
) -> None:
    log_path = resolve_log_path(log_path)
    poll_interval = float(config.get("poll_interval_seconds", 0.5))
    template = str(config.get("message_template", "GTS: {pokemon} por {price}"))
    print_filtered = bool(config.get("print_filtered", False))
    seen: set[str] = set()
    max_seen = int(config.get("max_seen_lines", 2000))
    ensure_storage(config)

    bridge_config = config.get("gts_bridge", {})
    bridge_config = bridge_config if isinstance(bridge_config, dict) else {}
    bridge_enabled = bool(bridge_config.get("enabled", True))
    bridge_path = resolve_bridge_capture_path(log_path, config)
    log_file = None
    bridge_file = None
    bridge_open_attempt = 0.0
    duplicate_window = float(bridge_config.get("duplicate_window_seconds", 0.75))
    recent_signatures: dict[str, tuple[float, str]] = {}
    notifications = None if dry_run else NotificationQueueWorker(config, token)
    if notifications:
        notifications.start()
    presence = None if dry_run or not env_bool("DISCORD_GATEWAY_ENABLED", True) else DiscordGatewayPresence(config, token)
    if presence:
        presence.start()
    last_heartbeat = 0.0
    try:
        while not log_path.exists():
            if time.monotonic() - last_heartbeat >= 5:
                print(f"Aguardando Minecraft criar log: {log_path}", flush=True)
                update_service_status(config, "log_watcher", "waiting", f"aguardando {log_path}")
                update_service_status(config, "gts_bridge", "waiting", f"aguardando {bridge_path}")
                last_heartbeat = time.monotonic()
            time.sleep(2)

        log_file = open_log_file(log_path, seek_to_end=not bool(config.get("read_from_start", False)))
        if bridge_enabled and bridge_path.exists():
            bridge_file = open_log_file(
                bridge_path,
                seek_to_end=not bool(bridge_config.get("read_from_start", False)),
            )

        print(f"Lendo log: {log_path}", flush=True)
        if bridge_enabled:
            print(f"Lendo GTS Bridge: {bridge_path}", flush=True)
        print("Aguardando anúncios do GTS. Ctrl+C para sair.", flush=True)
        update_service_status(config, "log_watcher", "online", str(log_path))
        update_service_status(
            config,
            "gts_bridge",
            "online" if bridge_file else "waiting",
            str(bridge_path),
        )

        while True:
            if time.monotonic() - last_heartbeat >= 5:
                update_service_status(config, "log_watcher", "online", f"monitorando {log_path.name}")
                if bridge_enabled:
                    update_service_status(
                        config,
                        "gts_bridge",
                        "online" if bridge_file else "waiting",
                        f"monitorando {bridge_path.name}" if bridge_file else f"aguardando {bridge_path}",
                    )
                last_heartbeat = time.monotonic()
            if should_reopen_log(log_path, log_file):
                log_file.close()
                log_file = open_log_file(log_path, seek_to_end=False)
                print("latest.log foi recriado/truncado; leitura reaberta.")

            if bridge_enabled and bridge_file and should_reopen_log(bridge_path, bridge_file):
                bridge_file.close()
                bridge_file = open_log_file(bridge_path, seek_to_end=False)
                print("captures.jsonl foi recriado/truncado; leitura reaberta.")
            if bridge_enabled and bridge_file is None and time.monotonic() - bridge_open_attempt >= 2:
                bridge_open_attempt = time.monotonic()
                if bridge_path.exists():
                    bridge_file = open_log_file(bridge_path, seek_to_end=False)
                    print("GTS Bridge encontrado; captura enriquecida ativada.", flush=True)

            bridge_line = bridge_file.readline() if bridge_file else ""
            if bridge_line:
                listing = parse_bridge_capture(bridge_line, patterns)
                if listing:
                    signature = listing_signature(listing)
                    recent_signatures[signature] = (time.monotonic(), "bridge")
                    process_detected_listing(
                        listing, config, template, print_filtered, dry_run, notifications
                    )
                continue

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
            signature = listing_signature(listing)
            last_match = recent_signatures.get(signature)
            if (
                last_match is not None
                and last_match[1] == "bridge"
                and time.monotonic() - last_match[0] <= duplicate_window
            ):
                continue
            recent_signatures[signature] = (time.monotonic(), "log")
            if len(recent_signatures) > max_seen:
                cutoff = time.monotonic() - max(duplicate_window * 4, 5)
                recent_signatures = {
                    key: match for key, match in recent_signatures.items() if match[0] >= cutoff
                }
            process_detected_listing(listing, config, template, print_filtered, dry_run, notifications)
    finally:
        update_service_status(config, "log_watcher", "offline", "processo encerrado")
        update_service_status(config, "gts_bridge", "offline", "processo encerrado")
        log_file.close() if log_file else None
        bridge_file.close() if bridge_file else None
        presence.stop() if presence else None
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
    parser.add_argument("--announce-site-unavailable", help="Marca a mensagem oficial do painel como reconectando e sai.")
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

    if args.announce_site_unavailable:
        guild_id = get_required_env("DISCORD_GUILD_ID")
        channel_id = get_required_env("DISCORD_ANNOUNCE_CHANNEL_ID")
        reason = args.announce_site_unavailable
        message_id, pin_error = upsert_pinned_site_message(token, channel_id, format_site_unavailable_message(reason))
        permanent_access_url = f"https://discord.com/channels/{guild_id}/{channel_id}/{message_id}"
        PERMANENT_ACCESS_URL_PATH.write_text(permanent_access_url + "\n", encoding="utf-8")
        print(f"Mensagem oficial do site marcada como reconectando: {message_id}")
        print(f"Link fixo de acesso: {permanent_access_url}")
        if pin_error:
            print(f"[AVISO PIN DISCORD] {pin_error}", file=sys.stderr)
        else:
            print("Mensagem oficial fixada no canal do Discord.")
        send_telegram_text_optional(format_telegram_site_unavailable(reason, permanent_access_url))
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
