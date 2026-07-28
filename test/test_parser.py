import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

import gts_dm_bot as bot


class ParserTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = bot.load_config(Path(__file__).parents[1] / "config.json")
        cls.patterns = bot.compile_patterns(cls.config)

    def test_parses_pokecoin_listing(self):
        line = "[14:25:53] [Client thread/INFO] [minecraft/GuiNewChat]: [CHAT] §7[§6GTS Global§7] §eARKIO§7 added a Marshadow to the global GTS for §b$ 4,000,000.00 PokéCoins!"
        listing = bot.parse_listing(line, self.patterns)
        self.assertIsNotNone(listing)
        self.assertEqual("Marshadow", listing.item)
        self.assertEqual("ARKIO", listing.seller)
        self.assertEqual("money", listing.price_type)
        self.assertEqual(4_000_000.0, bot.amount_to_float(listing.amount))

    def test_parses_token_listing(self):
        line = "[CHAT] [GTS Global] grey_xzfx added a Chave de Shiny Aleatório to the global GTS for Token 4.00 Tokens!"
        listing = bot.parse_listing(line, self.patterns)
        self.assertEqual("token", listing.price_type)
        self.assertEqual("4.00", listing.amount)

    def test_ignores_local_gts_and_unrelated_lines(self):
        invalid_lines = [
            "[CHAT] [GTS] mamp added a Haunter to the GTS for $ 375,000.00 PokéCoins!",
            "[CHAT] [GTS] auction starting for $ 1,000,000.00 PokéCoins!",
            "[CHAT] jogador comentou que viu um Marshadow no GTS por 500000",
        ]
        for line in invalid_lines:
            with self.subTest(line=line):
                self.assertIsNone(bot.parse_listing(line, self.patterns))

    def test_ignores_bridge_logger_echo(self):
        line = "[18:05:01] [Client thread/INFO] [gtsbridge]: Captured Global GTS message: [GTS Global] ARKIO added a Marshadow to the global GTS for $ 4,000,000.00 PokéCoins!"
        self.assertIsNone(bot.parse_listing(line, self.patterns))

    def test_parses_pokemon_hover_from_bridge(self):
        capture = {
            "capturedAt": "2026-07-04T18:00:00Z",
            "unformatted": "[GTS Global] ARKIO added a Hero Marshadow to the global GTS for $ 39,000,000.00 PokéCoins!",
            "hoverEvents": [{
                "action": "show_text",
                "valueUnformatted": (
                    "Hero Marshadow: Level 100 (#4637)\nSpecies: Marshadow\nAbility: Technician (HA)\n"
                    "Nature: Jolly\nGender: None\nSize: Giant\nTexture: Hero\nUnbreedable: No\n\n"
                    "IVs: 140/186 (75.27%)\nHP: 14 / Atk: 27 / Def: 6\nSpA: 31 / SpD: 31 / Spe: 31\n\n"
                    "EVs: 510/510 (100.00%)\nHP: 6 / Atk: 252 / Def: 0\nSpA: 0 / SpD: 0 / Spe: 252\n\n"
                    "Moves:\nSpectral Thief | Drain Punch | Assurance | Sucker Punch"
                ),
            }],
        }
        listing = bot.parse_bridge_capture(json.dumps(capture), self.patterns)
        self.assertIsNotNone(listing)
        self.assertEqual("bridge", listing.source)
        self.assertTrue(listing.is_pokemon)
        self.assertEqual("Hero", listing.texture)
        self.assertEqual("Technician", listing.ability)
        self.assertTrue(listing.hidden_ability)
        self.assertEqual("Jolly", listing.nature)
        self.assertEqual(140, listing.iv_total)
        self.assertEqual(31, listing.iv_speed)
        self.assertEqual(252, listing.ev_speed)
        self.assertEqual("Spectral Thief", listing.moves[0])

    def test_sqlite_deduplication_and_alert_match(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "test.db"
            old_database = os.environ.get("PANEL_DB_PATH")
            old_discord = os.environ.get("DISCORD_USER_ID")
            old_telegram = os.environ.get("TELEGRAM_ENABLED")
            os.environ["PANEL_DB_PATH"] = str(database)
            os.environ["DISCORD_USER_ID"] = "123456789012345678"
            os.environ["TELEGRAM_ENABLED"] = "false"
            try:
                bot.ensure_storage(self.config)
                with sqlite3.connect(database) as connection:
                    connection.execute("INSERT INTO users(email,name,password_hash,role,status,created_at) VALUES ('user@example.com','User','hash','user','approved',1)")
                    connection.execute("INSERT INTO alerts(user_id,query,price_type,channels,created_at) VALUES (1,'Marshadow','money','site',1)")
                    connection.execute(
                        """
                        INSERT INTO alerts(user_id,query,price_type,match_mode,texture_query,min_iv_percent,hidden_ability_only,channels,created_at)
                        VALUES (1,'Marshadow','all','item','custom',70,1,'site',1)
                        """
                    )
                listing = bot.GtsListing(
                    item="Marshadow", seller="ARKIO", amount="4,000,000.00", currency="PokéCoins",
                    price_type="money", price="$ 4,000,000.00 PokéCoins", raw_chat="GTS test",
                    fingerprint="stable-test", detected_at="2026-07-03T12:00:00+00:00",
                    source="bridge", is_pokemon=True, ability="Technician", hidden_ability=True, nature="Jolly",
                    texture="Hero", iv_total=140, iv_max=186, iv_percent=75.27,
                    iv_speed=31, moves=("Spectral Thief", "Drain Punch"),
                )
                first_id = bot.append_history(self.config, listing, "sent")
                second_id = bot.append_history(self.config, listing, "sent")
                self.assertEqual(first_id, second_id)
                with sqlite3.connect(database) as connection:
                    self.assertEqual(1, connection.execute("SELECT COUNT(*) FROM listings").fetchone()[0])
                    self.assertEqual(2, connection.execute("SELECT COUNT(*) FROM alert_matches").fetchone()[0])
                    self.assertEqual(1, connection.execute("SELECT COUNT(*) FROM notification_queue").fetchone()[0])
                    self.assertEqual(1, connection.execute("SELECT COUNT(*) FROM item_stats").fetchone()[0])
                    self.assertEqual(
                        ("marshadow", "hero", "money", 1),
                        connection.execute("SELECT item_key, texture_key, price_type, appearances FROM item_stats").fetchone(),
                    )
                    details = connection.execute(
                        "SELECT source, texture, iv_total, hidden_ability, moves_json FROM listings"
                    ).fetchone()
                    self.assertEqual(("bridge", "Hero", 140, 1, '["Spectral Thief", "Drain Punch"]'), details)

                worker = bot.NotificationQueueWorker(self.config, "test-token")
                job = worker._claim()
                original_sender = bot.send_dm_payload
                try:
                    bot.send_dm_payload = lambda token, destination, payload: None
                    worker._deliver(job)
                    worker._finish(job)
                finally:
                    bot.send_dm_payload = original_sender
                with sqlite3.connect(database) as connection:
                    self.assertEqual("sent", connection.execute("SELECT status FROM notification_queue").fetchone()[0])
            finally:
                if old_database is None:
                    os.environ.pop("PANEL_DB_PATH", None)
                else:
                    os.environ["PANEL_DB_PATH"] = old_database
                if old_discord is None:
                    os.environ.pop("DISCORD_USER_ID", None)
                else:
                    os.environ["DISCORD_USER_ID"] = old_discord
                if old_telegram is None:
                    os.environ.pop("TELEGRAM_ENABLED", None)
                else:
                    os.environ["TELEGRAM_ENABLED"] = old_telegram


if __name__ == "__main__":
    unittest.main()
