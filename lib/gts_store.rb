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

  def connect(path)
    database = SQLite3::Database.new(path)
    database.results_as_hash = true
    database.busy_timeout = 5_000
    database.execute("PRAGMA foreign_keys = ON")
    database.execute("PRAGMA journal_mode = WAL")
    database
  end

  def initialize!(path:, csv_path: nil)
    database = connect(path)
    database.execute_batch(schema_sql)
    ensure_columns(database, "users", USER_COLUMNS)
    import_csv(database, csv_path) if csv_path
    quarantine_non_global_listings(database)
  ensure
    database&.close
  end

  def ensure_columns(database, table, columns)
    existing = database.table_info(table).map { |column| column["name"] }
    columns.each do |name, definition|
      database.execute("ALTER TABLE #{table} ADD COLUMN #{name} #{definition}") unless existing.include?(name)
    end
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
    database.execute(<<~SQL)
      UPDATE listings SET status = 'invalid', reason = 'not_global_gts'
      WHERE status = 'sent' AND lower(raw_chat) NOT LIKE '%to the global gts for%'
    SQL
  end

  def insert_listing(database, row)
    detected_at = row.fetch("detected_at", Time.now.utc.iso8601).to_s
    fingerprint = row["fingerprint"].to_s
    fingerprint = Digest::SHA256.hexdigest("#{detected_at}\0#{row['raw_chat']}") if fingerprint.empty?
    item = row.fetch("item", "").to_s.strip
    amount = row.fetch("amount", "").to_s
    amount_value = row["amount_value"] || parse_amount(amount)
    epoch = row["detected_at_epoch"] || parse_epoch(detected_at)

    database.execute(<<~SQL, [fingerprint, detected_at, epoch, row["status"], row["reason"], item, fold(item), row["seller"], amount, amount_value, row["currency"], row["price_type"], row["price"], row["raw_chat"], Time.now.to_i])
      INSERT OR IGNORE INTO listings
        (fingerprint, detected_at, detected_at_epoch, status, reason, item, item_key, seller,
         amount, amount_value, currency, price_type, price, raw_chat, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    database.last_insert_row_id
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
        currency TEXT, price_type TEXT, price TEXT, raw_chat TEXT, created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_listings_detected ON listings(detected_at_epoch DESC);
      CREATE INDEX IF NOT EXISTS idx_listings_type_detected ON listings(price_type, detected_at_epoch DESC);
      CREATE INDEX IF NOT EXISTS idx_listings_item ON listings(item_key, price_type, detected_at_epoch DESC);
      CREATE TABLE IF NOT EXISTS alerts (
        id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, query TEXT NOT NULL,
        price_type TEXT NOT NULL DEFAULT 'all', min_amount REAL, max_amount REAL,
        channels TEXT NOT NULL DEFAULT 'site', active INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL, FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_alerts_user ON alerts(user_id, active);
      CREATE TABLE IF NOT EXISTS alert_matches (
        id INTEGER PRIMARY KEY AUTOINCREMENT, alert_id INTEGER NOT NULL, listing_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL, created_at INTEGER NOT NULL, seen_at INTEGER,
        UNIQUE(alert_id, listing_id),
        FOREIGN KEY(alert_id) REFERENCES alerts(id) ON DELETE CASCADE,
        FOREIGN KEY(listing_id) REFERENCES listings(id) ON DELETE CASCADE
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
