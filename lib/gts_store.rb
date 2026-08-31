# frozen_string_literal: true

require "csv"
require "digest"
require "sqlite3"
require "time"

module GTSStore
  module_function

  USER_COLUMNS = {
    "discord_user_id" => "TEXT",
    "telegram_chat_id" => "TEXT",
    "notifications_enabled" => "INTEGER NOT NULL DEFAULT 1"
  }.freeze

  LISTING_COLUMNS = {
    "source" => "TEXT NOT NULL DEFAULT 'log'", "hover_action" => "TEXT", "hover_payload" => "TEXT",
    "is_pokemon" => "INTEGER NOT NULL DEFAULT 0", "ability" => "TEXT",
    "hidden_ability" => "INTEGER NOT NULL DEFAULT 0", "nature" => "TEXT",
    "gender" => "TEXT", "pokemon_size" => "TEXT", "texture" => "TEXT", "unbreedable" => "TEXT",
    "iv_total" => "INTEGER", "iv_max" => "INTEGER", "iv_percent" => "REAL", "iv_hp" => "INTEGER",
    "iv_attack" => "INTEGER", "iv_defense" => "INTEGER", "iv_sp_attack" => "INTEGER",
    "iv_sp_defense" => "INTEGER", "iv_speed" => "INTEGER", "ev_total" => "INTEGER",
    "ev_max" => "INTEGER", "ev_percent" => "REAL", "ev_hp" => "INTEGER", "ev_attack" => "INTEGER",
    "ev_defense" => "INTEGER", "ev_sp_attack" => "INTEGER", "ev_sp_defense" => "INTEGER",
    "ev_speed" => "INTEGER", "moves_json" => "TEXT"
  }.freeze

  ALERT_COLUMNS = {
    "match_mode" => "TEXT NOT NULL DEFAULT 'text'",
    "texture_query" => "TEXT",
    "min_iv_percent" => "REAL",
    "hidden_ability_only" => "INTEGER NOT NULL DEFAULT 0"
  }.freeze

  MERCHANT_COLUMNS = {
    "world" => "TEXT NOT NULL DEFAULT 'lohr'",
    "location" => "TEXT",
    "coordinate_text" => "TEXT"
  }.freeze

  def connect(path)
    database = SQLite3::Database.new(path)
    database.results_as_hash = true
    # O painel compartilha o SQLite com o coletor Python. Aguarde uma fila
    # curta de escritores antes de retornar database is locked ao navegador.
    database.busy_timeout = 30_000
    database.execute("PRAGMA foreign_keys = ON")
    database.execute("PRAGMA journal_mode = WAL")
    database
  end

  def initialize!(path:, csv_path: nil)
    database = connect(path)
    database.execute_batch(schema_sql)
    ensure_columns(database, "users", USER_COLUMNS)
    ensure_columns(database, "listings", LISTING_COLUMNS)
    ensure_columns(database, "alerts", ALERT_COLUMNS)
    ensure_columns(database, "merchant_spawns", MERCHANT_COLUMNS)
    ensure_indexes(database)
    database.execute("UPDATE listings SET hidden_ability=1 WHERE lower(COALESCE(ability, '')) LIKE '%(ha%'")
    import_csv(database, csv_path) if csv_path
    quarantined = quarantine_non_global_listings(database)
    rebuild_item_stats(database) if quarantined.positive? || database.get_first_value("SELECT COUNT(*) FROM item_stats").to_i.zero?
  ensure
    database&.close
  end

  def ensure_columns(database, table, columns)
    existing = database.table_info(table).map { |column| column["name"] }
    columns.each do |name, definition|
      database.execute("ALTER TABLE #{table} ADD COLUMN #{name} #{definition}") unless existing.include?(name)
    end
  end

  def ensure_indexes(database)
    database.execute_batch(<<~SQL)
      CREATE INDEX IF NOT EXISTS idx_listings_texture_detected ON listings(texture, detected_at_epoch DESC);
      CREATE INDEX IF NOT EXISTS idx_listings_sent_texture ON listings(status, item_key, price_type, texture, detected_at_epoch DESC);
      CREATE INDEX IF NOT EXISTS idx_listings_sent_iv ON listings(status, is_pokemon, iv_percent DESC, detected_at_epoch DESC);
      CREATE INDEX IF NOT EXISTS idx_alerts_texture ON alerts(active, texture_query, min_iv_percent, hidden_ability_only);
      CREATE INDEX IF NOT EXISTS idx_item_stats_last_seen ON item_stats(last_seen_epoch DESC);
      CREATE INDEX IF NOT EXISTS idx_item_stats_texture ON item_stats(texture_key, appearances, last_seen_epoch DESC);
      CREATE INDEX IF NOT EXISTS idx_item_stats_item ON item_stats(item_key, price_type, last_seen_epoch DESC);
      CREATE INDEX IF NOT EXISTS idx_merchant_spawns_detected ON merchant_spawns(detected_at_epoch DESC);
      CREATE INDEX IF NOT EXISTS idx_merchant_spawns_coords ON merchant_spawns(world, x, y, z, detected_at_epoch DESC);
    SQL
  end

  def import_csv(database, path)
    return unless File.file?(path)

    database.transaction
    CSV.foreach(path, headers: true, encoding: "UTF-8") do |row|
      insert_listing(database, row.to_h)
    end
    database.commit
  rescue CSV::MalformedCSVError, SQLite3::Exception => e
    database.rollback if database&.transaction_active?
    warn "Falha ao importar histórico CSV: #{e.message}"
  end

  def quarantine_non_global_listings(database)
    quarantined = 0
    duplicate_ids = database.execute(<<~SQL).map { |row| row["id"] }
      SELECT id FROM listings
      WHERE status != 'invalid' AND lower(raw_chat) LIKE '%[gtsbridge]%'
    SQL
    unless duplicate_ids.empty?
      placeholders = (["?"] * duplicate_ids.length).join(", ")
      database.execute(
        "UPDATE notification_queue SET status='cancelled', last_error='duplicate_bridge_logger' WHERE listing_id IN (#{placeholders}) AND status IN ('pending','retry','processing')",
        duplicate_ids
      )
      database.execute(
        "UPDATE listings SET status='invalid', reason='duplicate_bridge_logger' WHERE id IN (#{placeholders})",
        duplicate_ids
      )
      quarantined += duplicate_ids.length
    end
    non_global_ids = database.execute(<<~SQL).map { |row| row["id"] }
      SELECT id FROM listings
      WHERE status = 'sent'
        AND lower(raw_chat) NOT LIKE '%to the global gts for%'
        AND lower(raw_chat) NOT LIKE '%ao gts global por%'
    SQL
    database.execute(<<~SQL)
      UPDATE listings SET status = 'invalid', reason = 'not_global_gts'
      WHERE status = 'sent'
        AND lower(raw_chat) NOT LIKE '%to the global gts for%'
        AND lower(raw_chat) NOT LIKE '%ao gts global por%'
    SQL
    quarantined + non_global_ids.length
  end

  def insert_listing(database, row)
    detected_at = row.fetch("detected_at", Time.now.utc.iso8601).to_s
    fingerprint = row["fingerprint"].to_s
    fingerprint = Digest::SHA256.hexdigest("#{detected_at}\0#{row['raw_chat']}") if fingerprint.empty?
    item = row.fetch("item", "").to_s.strip
    amount = row.fetch("amount", "").to_s
    amount_value = row["amount_value"] || parse_amount(amount)
    epoch = row["detected_at_epoch"] || parse_epoch(detected_at)

    values = {
      "fingerprint" => fingerprint, "detected_at" => detected_at, "detected_at_epoch" => epoch,
      "status" => row["status"], "reason" => row["reason"], "item" => item, "item_key" => fold(item),
      "seller" => row["seller"], "amount" => amount, "amount_value" => amount_value,
      "currency" => row["currency"], "price_type" => row["price_type"], "price" => row["price"],
      "raw_chat" => row["raw_chat"], "created_at" => Time.now.to_i,
      "source" => row.fetch("source", "log"), "hover_action" => row["hover_action"],
      "hover_payload" => row["hover_payload"], "is_pokemon" => row.fetch("is_pokemon", 0),
      "ability" => row["ability"], "hidden_ability" => row.fetch("hidden_ability", 0),
      "nature" => row["nature"], "gender" => row["gender"],
      "pokemon_size" => row["pokemon_size"], "texture" => row["texture"],
      "unbreedable" => row["unbreedable"], "iv_total" => row["iv_total"], "iv_max" => row["iv_max"],
      "iv_percent" => row["iv_percent"], "iv_hp" => row["iv_hp"], "iv_attack" => row["iv_attack"],
      "iv_defense" => row["iv_defense"], "iv_sp_attack" => row["iv_sp_attack"],
      "iv_sp_defense" => row["iv_sp_defense"], "iv_speed" => row["iv_speed"],
      "ev_total" => row["ev_total"], "ev_max" => row["ev_max"], "ev_percent" => row["ev_percent"],
      "ev_hp" => row["ev_hp"], "ev_attack" => row["ev_attack"], "ev_defense" => row["ev_defense"],
      "ev_sp_attack" => row["ev_sp_attack"], "ev_sp_defense" => row["ev_sp_defense"],
      "ev_speed" => row["ev_speed"], "moves_json" => row["moves_json"]
    }
    columns = values.keys
    database.execute(
      "INSERT OR IGNORE INTO listings (#{columns.join(', ')}) VALUES (#{(['?'] * columns.length).join(', ')})",
      values.values
    )
    listing_id = database.last_insert_row_id
    update_item_stats(database, listing_id) if listing_id.to_i.positive? && values["status"] == "sent"
    listing_id
  end

  def insert_merchant_spawn(database, row)
    detected_at = row.fetch("detected_at", Time.now.utc.iso8601).to_s
    epoch = row["detected_at_epoch"] || parse_epoch(detected_at)
    x = row.fetch("x").to_f
    y = row.fetch("y").to_f
    z = row.fetch("z").to_f
    coordinate_text = row["coordinate_text"].to_s
    coordinate_text = format_coordinates(x, y, z) if coordinate_text.empty?
    raw_chat = row.fetch("raw_chat", "").to_s
    fingerprint = row["fingerprint"].to_s
    fingerprint = Digest::SHA256.hexdigest("#{epoch / 60}\0#{coordinate_text}\0#{raw_chat}") if fingerprint.empty?
    values = {
      "fingerprint" => fingerprint,
      "detected_at" => detected_at,
      "detected_at_epoch" => epoch,
      "world" => row.fetch("world", "lohr"),
      "location" => row["location"],
      "x" => x,
      "y" => y,
      "z" => z,
      "coordinate_text" => coordinate_text,
      "raw_chat" => raw_chat,
      "source" => row.fetch("source", "log"),
      "created_at" => Time.now.to_i
    }
    columns = values.keys
    database.execute(
      "INSERT OR IGNORE INTO merchant_spawns (#{columns.join(', ')}) VALUES (#{(['?'] * columns.length).join(', ')})",
      values.values
    )
    merchant_id = database.last_insert_row_id
    return merchant_id if merchant_id.to_i.positive?

    database.get_first_value("SELECT id FROM merchant_spawns WHERE fingerprint=?", [fingerprint]).to_i
  end

  def format_coordinates(x, y, z)
    [x, y, z].map { |value| format_coordinate(value) }.join(" ")
  end

  def format_coordinate(value)
    number = value.to_f
    number == number.to_i ? number.to_i.to_s : format("%.2f", number).sub(/\.?0+\z/, "")
  end

  def texture_key(value)
    folded = fold(value).gsub(/[^a-z0-9]+/, "")
    folded.empty? ? "original" : folded
  end

  def update_item_stats(database, listing_id)
    row = database.get_first_row("SELECT * FROM listings WHERE id=? AND status='sent'", [listing_id])
    return unless row

    raw_price_type = row["price_type"].to_s
    key = [row["item_key"], texture_key(row["texture"]), raw_price_type.empty? ? "unknown" : raw_price_type]
    rows = database.execute(
      "SELECT * FROM listings WHERE status='sent' AND item_key=? AND COALESCE(price_type,'')=?",
      [key[0], raw_price_type]
    ).select { |candidate| texture_key(candidate["texture"]) == key[1] }
    upsert_item_stats(database, key[0], key[1], key[2], rows)
  end

  def rebuild_item_stats(database)
    database.execute("DELETE FROM item_stats")
    groups = database.execute(<<~SQL).group_by { |row| [row["item_key"], texture_key(row["texture"]), row["price_type"].to_s.empty? ? "unknown" : row["price_type"]] }
      SELECT * FROM listings WHERE status='sent'
    SQL
    groups.each do |(item_key, texture_key_value, price_type), rows|
      upsert_item_stats(database, item_key, texture_key_value, price_type, rows)
    end
  end

  def upsert_item_stats(database, item_key, texture_key_value, price_type, rows)
    rows = rows.compact
    return if rows.empty?

    latest = rows.max_by { |row| row["detected_at_epoch"].to_i }
    first = rows.min_by { |row| row["detected_at_epoch"].to_i }
    amounts = rows.filter_map { |row| row["amount_value"]&.to_f }.select(&:positive?).sort
    median = percentile(amounts, 0.5)
    timestamp = Time.now.to_i
    sql = <<~SQL
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
    SQL
    database.execute(sql, [
      item_key, texture_key_value, price_type, latest["item"], latest["texture"], latest["currency"],
      latest["seller"], latest["amount"], latest["price"], latest["is_pokemon"].to_i, latest["hidden_ability"].to_i,
      latest["iv_percent"], rows.length, first["detected_at_epoch"].to_i, latest["detected_at_epoch"].to_i,
      latest["id"].to_i, amounts.min, median, amounts.max, amounts.sum, amounts.length, timestamp, timestamp
    ])
  end

  def percentile(sorted_values, fraction)
    return nil if sorted_values.empty?

    position = (sorted_values.length - 1) * fraction
    lower = sorted_values[position.floor]
    upper = sorted_values[position.ceil]
    lower + ((upper - lower) * (position - position.floor))
  end

  def parse_amount(value)
    clean = value.to_s.gsub(/[^0-9,.-]/, "")
    return nil if clean.empty?

    if clean.include?(",") && clean.include?(".")
      clean = clean.rindex(",") > clean.rindex(".") ? clean.delete(".").tr(",", ".") : clean.delete(",")
    elsif clean.include?(",")
      left, _separator, right = clean.rpartition(",")
      clean = right.length.between?(1, 2) ? "#{left}.#{right}" : clean.delete(",")
    end
    Float(clean)
  rescue ArgumentError
    nil
  end

  def parse_epoch(value)
    Time.iso8601(value.to_s).to_i
  rescue ArgumentError
    Time.now.to_i
  end

  def fold(value)
    value.to_s.unicode_normalize(:nfkd).encode("ASCII", invalid: :replace, undef: :replace, replace: "").downcase
  end

  def schema_sql
    <<~SQL
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
        password_hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'user', status TEXT NOT NULL DEFAULT 'pending',
        invite_code TEXT, approval_token TEXT UNIQUE, created_at INTEGER NOT NULL, approved_at INTEGER, last_login_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, csrf_token TEXT NOT NULL,
        created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE TABLE IF NOT EXISTS invite_codes (
        id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL UNIQUE, note TEXT,
        max_uses INTEGER NOT NULL DEFAULT 1, used_count INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL, expires_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, user_id INTEGER, details TEXT, created_at INTEGER NOT NULL
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
        created_at INTEGER NOT NULL, FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_alerts_user ON alerts(user_id, active);
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
      CREATE TABLE IF NOT EXISTS merchant_spawns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        fingerprint TEXT NOT NULL UNIQUE,
        detected_at TEXT NOT NULL,
        detected_at_epoch INTEGER NOT NULL,
        world TEXT NOT NULL DEFAULT 'lohr',
        location TEXT,
        x REAL NOT NULL,
        y REAL NOT NULL,
        z REAL NOT NULL,
        coordinate_text TEXT,
        raw_chat TEXT,
        source TEXT NOT NULL DEFAULT 'log',
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS alert_matches (
        id INTEGER PRIMARY KEY AUTOINCREMENT, alert_id INTEGER NOT NULL, listing_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL, created_at INTEGER NOT NULL, seen_at INTEGER,
        UNIQUE(alert_id, listing_id),
        FOREIGN KEY(alert_id) REFERENCES alerts(id) ON DELETE CASCADE,
        FOREIGN KEY(listing_id) REFERENCES listings(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_alert_matches_user ON alert_matches(user_id, seen_at, created_at DESC);
      CREATE TABLE IF NOT EXISTS favorites (
        id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('item', 'seller')),
        value TEXT NOT NULL, value_key TEXT NOT NULL, created_at INTEGER NOT NULL,
        UNIQUE(user_id, kind, value_key),
        FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_favorites_user ON favorites(user_id, kind, created_at DESC);
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
      CREATE TABLE IF NOT EXISTS login_attempts (
        id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT, ip TEXT, succeeded INTEGER NOT NULL, created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_login_attempts_lookup ON login_attempts(email, ip, created_at DESC);
      CREATE TABLE IF NOT EXISTS password_reset_tokens (
        token TEXT PRIMARY KEY, user_id INTEGER NOT NULL, expires_at INTEGER NOT NULL,
        used_at INTEGER, created_at INTEGER NOT NULL, FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    SQL
  end
end
