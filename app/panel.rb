#!/usr/bin/env ruby
# frozen_string_literal: true

require "rubygems"

vendor_gems = File.join(__dir__, "..", "vendor", "bundle", "ruby", RbConfig::CONFIG.fetch("ruby_version"))
Gem.paths = {
  "GEM_HOME" => vendor_gems,
  "GEM_PATH" => [vendor_gems, Gem.default_dir, Gem.user_dir].uniq.join(File::PATH_SEPARATOR)
}
require "base64"
require "cgi"
require "json"
require "net/smtp"
require "openssl"
require "securerandom"
require "set"
require "sinatra/base"
require "sqlite3"
require "time"
require_relative "../lib/gts_store"
require_relative "../lib/gts_assets"

class PixelmonGTSPanel < Sinatra::Base
  ROOT = File.expand_path("..", __dir__)
  ENV_PATH = File.join(ROOT, ".env")
  CONFIG_PATH = File.join(ROOT, "config", "config.json")
  COOKIE_NAME = "gts_panel_session"
  PBKDF2_ITERATIONS = 260_000
  SESSION_TTL = 60 * 60 * 24 * 14
  LOGIN_WINDOW = 15 * 60
  LOGIN_MAX_FAILURES = 5
  RESET_TTL = 60 * 60
  FEED_PAGE_SIZE = 40
  HISTORY_PAGE_SIZE = 60
  TEXTURE_PAGE_SIZE = 72
  MERCHANT_PAGE_SIZE = 80
  PRIORITY_TEXTURE_TARGETS = %w[Zacian Kyogre Rayquaza Zamazenta Eternatus].freeze

  configure do
    if File.exist?(ENV_PATH)
      File.foreach(ENV_PATH, chomp: true) do |raw_line|
        line = raw_line.strip
        next if line.empty? || line.start_with?("#") || !line.include?("=")

        key, value = line.split("=", 2)
        ENV[key.strip] ||= value.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
      end
    end

    set :root, ROOT
    set :environment, ENV.fetch("RACK_ENV", "production").to_sym
    set :reload_templates, false
    set :views, File.join(ROOT, "views")
    set :public_folder, File.join(ROOT, "public")
    set :static, true
    set :server, :puma
    set :bind, ENV.fetch("PANEL_HOST", "127.0.0.1")
    set :port, Integer(ENV.fetch("PANEL_PORT", "8080"))
    set :show_exceptions, false
    set :raise_errors, false
    set :host_authorization, { permitted_hosts: [] }
  end

  helpers do
    def config_env(name, fallback = "")
      ENV.fetch(name, fallback).to_s.strip
    end

    def env_bool(name, fallback = false)
      %w[1 true yes sim on].include?(config_env(name, fallback.to_s).downcase)
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    def db
      GTSStore.connect(database_path)
    end

    def database_path
      configured = config_env("PANEL_DB_PATH", "data/access_panel.db")
      File.absolute_path(configured, ROOT)
    end

    def minecraft_root
      configured = config_env("MINECRAFT_LOG_PATH")
      return "" if configured.empty?

      log_path = File.expand_path(configured)
      File.dirname(File.dirname(log_path))
    end

    def asset_catalog
      return unless env_bool("GTS_ASSETS_ENABLED", true)
      return if minecraft_root.empty? || !Dir.exist?(minecraft_root)

      @asset_catalog ||= GTSAssets.catalog(minecraft_root)
    rescue StandardError => e
      warn "Imagens do GTS indisponíveis: #{e.message}"
      nil
    end

    def listing_image_url(row)
      asset_catalog&.resolve(row) ? "/listing/#{row['id']}/image" : nil
    end

    def with_db
      database = db
      yield database
    ensure
      database&.close
    end

    def now
      Time.now.to_i
    end

    def format_utc(timestamp)
      Time.at(timestamp.to_i).utc.strftime("%d/%m/%Y %H:%M UTC")
    end

    def format_detected_at(value)
      Time.iso8601(value.to_s).getlocal.strftime("%d/%m %H:%M:%S")
    rescue ArgumentError
      value.to_s
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      OpenSSL.fixed_length_secure_compare(left, right)
    end

    def hash_password(password)
      salt = SecureRandom.random_bytes(16)
      digest = OpenSSL::PKCS5.pbkdf2_hmac(password, salt, PBKDF2_ITERATIONS, 32, "sha256")
      "pbkdf2_sha256$#{PBKDF2_ITERATIONS}$#{Base64.strict_encode64(salt)}$#{Base64.strict_encode64(digest)}"
    end

    def valid_password?(password, stored)
      algorithm, iterations, salt64, digest64 = stored.to_s.split("$", 4)
      return false unless algorithm == "pbkdf2_sha256"

      salt = Base64.strict_decode64(salt64)
      expected = Base64.strict_decode64(digest64)
      actual = OpenSSL::PKCS5.pbkdf2_hmac(password, salt, Integer(iterations), expected.bytesize, "sha256")
      secure_compare(actual, expected)
    rescue ArgumentError, TypeError
      false
    end

    def log_event(database, type, user_id = nil, details = "")
      database.execute(
        "INSERT INTO events (type, user_id, details, created_at) VALUES (?, ?, ?, ?)",
        [type, user_id, details, now]
      )
    end

    def create_session(database, user_id)
      session_id = SecureRandom.urlsafe_base64(32)
      csrf_token = SecureRandom.urlsafe_base64(32)
      database.execute(
        "INSERT INTO sessions (id, user_id, csrf_token, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
        [session_id, user_id, csrf_token, now, now + SESSION_TTL]
      )
      [session_id, csrf_token]
    end

    def set_session_cookie(session_id)
      response.set_cookie(
        COOKIE_NAME,
        value: session_id,
        path: "/",
        max_age: SESSION_TTL,
        httponly: true,
        same_site: :lax,
        secure: request.secure? || request.env["HTTP_X_FORWARDED_PROTO"] == "https"
      )
    end

    def clear_session_cookie
      response.delete_cookie(COOKIE_NAME, path: "/")
    end

    def theme
      request.cookies["gts_panel_theme"] == "light" ? "light" : "dark"
    end

    def dark_theme?
      theme == "dark"
    end

    def load_current_user
      session_id = request.cookies[COOKIE_NAME].to_s
      return if session_id.empty?

      with_db do |database|
        database.execute("DELETE FROM sessions WHERE expires_at < ?", [now])
        @current_user = database.get_first_row(<<~SQL, [session_id, now])
          SELECT sessions.id AS session_id, sessions.csrf_token, users.*
          FROM sessions
          JOIN users ON users.id = sessions.user_id
          WHERE sessions.id = ? AND sessions.expires_at >= ?
        SQL
        if @current_user
          @nav_alert_count = database.get_first_value(
            "SELECT COUNT(*) FROM alert_matches WHERE user_id = ? AND seen_at IS NULL",
            [@current_user["id"]]
          ).to_i
          @favorite_keys = database.execute(
            "SELECT kind, value_key FROM favorites WHERE user_id = ?",
            [@current_user["id"]]
          ).map { |row| "#{row['kind']}:#{row['value_key']}" }.to_set
        end
      end
    end

    def approved!
      redirect "/login" unless @current_user
      halt 403, erb(:status, locals: { code: 403, title: "Acesso pendente", message: "Sua conta ainda não foi aprovada." }) unless @current_user["status"] == "approved"
    end

    def admin!
      approved!
      halt 403, erb(:status, locals: { code: 403, title: "Acesso negado", message: "Esta área é exclusiva para administradores." }) unless @current_user["role"] == "admin"
    end

    def csrf!
      supplied = params["csrf"].to_s
      expected = @current_user&.fetch("csrf_token", "").to_s
      halt 403, "Token CSRF inválido." if supplied.empty? || !secure_compare(supplied, expected)
    end

    def feed_filter
      type = params.fetch("type", "all").to_s
      %w[all money token site].include?(type) ? type : "all"
    end

    def feed_texture
      value = params.fetch("texture", "all").to_s
      %w[all pokemon custom original].include?(value) ? value : "all"
    end

    def feed_page
      [params.fetch("page", "1").to_i, 1].max
    end

    def feed_query
      params.fetch("q", "").to_s.strip[0, 80]
    end

    def feed_period
      value = params.fetch("period", "all").to_s
      %w[1h 24h 7d 30d all].include?(value) ? value : "all"
    end

    def feed_sort
      value = params.fetch("sort", "newest").to_s
      %w[newest price_low price_high].include?(value) ? value : "newest"
    end

    def history_period
      value = params.fetch("period", "all").to_s
      %w[30d 90d 180d all].include?(value) ? value : "all"
    end

    def history_sort
      value = params.fetch("sort", "last_seen").to_s
      %w[last_seen total name price_low price_high].include?(value) ? value : "last_seen"
    end

    def texture_sort
      value = params.fetch("sort", "recent").to_s
      %w[recent rare popular price_low price_high name].include?(value) ? value : "recent"
    end

    def listing_rows(database, limit: FEED_PAGE_SIZE)
      clauses = ["status = 'sent'"]
      values = []
      unless feed_filter == "all"
        clauses << "price_type = ?"
        values << feed_filter
      end
      case feed_texture
      when "pokemon"
        clauses << "is_pokemon = 1"
      when "custom"
        clauses << "trim(COALESCE(texture, '')) <> '' AND lower(texture) <> 'original'"
      when "original"
        clauses << "is_pokemon = 1 AND lower(texture) = 'original'"
      end
      unless feed_query.empty?
        clauses << "(item_key LIKE ? OR lower(seller) LIKE ? OR lower(COALESCE(texture, '')) LIKE ? OR lower(COALESCE(nature, '')) LIKE ? OR lower(COALESCE(ability, '')) LIKE ?)"
        search = "%#{GTSStore.fold(feed_query)}%"
        values.concat([search, search, search, search, search])
      end
      seconds = { "1h" => 3_600, "24h" => 86_400, "7d" => 604_800, "30d" => 2_592_000 }[feed_period]
      if seconds
        clauses << "detected_at_epoch >= ?"
        values << now - seconds
      end
      { "min" => ">=", "max" => "<=" }.each do |key, operator|
        raw = params[key].to_s.strip
        next if raw.empty?
        numeric = Float(raw)
        clauses << "amount_value #{operator} ?"
        values << numeric
      rescue ArgumentError
        next
      end
      where = clauses.join(" AND ")
      order = {
        "newest" => "detected_at_epoch DESC",
        "price_low" => "amount_value IS NULL, amount_value ASC, detected_at_epoch DESC",
        "price_high" => "amount_value IS NULL, amount_value DESC, detected_at_epoch DESC"
      }.fetch(feed_sort)
      total = database.get_first_value("SELECT COUNT(*) FROM listings WHERE #{where}", values).to_i
      rows = database.execute(
        "SELECT * FROM listings WHERE #{where} ORDER BY #{order} LIMIT ? OFFSET ?",
        values + [limit, (feed_page - 1) * limit]
      )
      [enrich_opportunities(database, rows), total]
    end

    def confidence_from_count(count)
      count = count.to_i
      count >= 20 ? "alta" : (count >= 8 ? "média" : (count >= 3 ? "baixa" : "insuficiente"))
    end

    def history_row_from_stats(row)
      last_seen = row["last_seen_epoch"].to_i
      row.merge(
        "id" => row["last_listing_id"],
        "item" => row["sample_item"],
        "seller" => row["last_seller"],
        "amount" => row["last_amount"],
        "currency" => row["sample_currency"],
        "price" => row["last_price"],
        "texture" => row["sample_texture"],
        "detected_at_epoch" => last_seen,
        "detected_at" => last_seen.positive? ? Time.at(last_seen).utc.iso8601 : "",
        "history_min" => row["min_amount"],
        "history_median" => row["median_amount"],
        "history_max" => row["max_amount"],
        "history_samples" => row["amount_count"],
        "history_confidence" => confidence_from_count(row["amount_count"])
      )
    end

    def history_rows(database)
      clauses = ["1=1"]
      values = []
      unless feed_filter == "all"
        clauses << "price_type = ?"
        values << feed_filter
      end
      case feed_texture
      when "pokemon"
        clauses << "is_pokemon = 1"
      when "custom"
        clauses << "texture_key <> 'original'"
      when "original"
        clauses << "is_pokemon = 1 AND texture_key = 'original'"
      end
      unless feed_query.empty?
        clauses << "(item_key LIKE ? OR lower(sample_item) LIKE ? OR lower(last_seller) LIKE ? OR lower(COALESCE(sample_texture, '')) LIKE ?)"
        search = "%#{GTSStore.fold(feed_query)}%"
        values.concat([search, search, search, search])
      end
      seconds = { "30d" => 2_592_000, "90d" => 7_776_000, "180d" => 15_552_000 }[history_period]
      if seconds
        clauses << "last_seen_epoch >= ?"
        values << now - seconds
      end

      order = {
        "total" => "appearances DESC, last_seen_epoch DESC",
        "name" => "sample_item COLLATE NOCASE ASC, last_seen_epoch DESC",
        "price_low" => "min_amount IS NULL, min_amount ASC, last_seen_epoch DESC",
        "price_high" => "max_amount IS NULL, max_amount DESC, last_seen_epoch DESC",
        "last_seen" => "last_seen_epoch DESC, sample_item COLLATE NOCASE ASC"
      }.fetch(history_sort)
      where = clauses.join(" AND ")
      total = database.get_first_value("SELECT COUNT(*) FROM item_stats WHERE #{where}", values).to_i
      rows = database.execute(
        "SELECT * FROM item_stats WHERE #{where} ORDER BY #{order} LIMIT ? OFFSET ?",
        values + [HISTORY_PAGE_SIZE, (feed_page - 1) * HISTORY_PAGE_SIZE]
      )
      [rows.map { |row| history_row_from_stats(row) }, total]
    end

    def history_metrics(database)
      {
        total: database.get_first_value("SELECT COUNT(*) FROM listings WHERE status='sent'").to_i,
        unique_items: database.get_first_value("SELECT COUNT(DISTINCT item_key) FROM listings WHERE status='sent'").to_i,
        custom_textures: database.get_first_value("SELECT COUNT(*) FROM listings WHERE status='sent' AND trim(COALESCE(texture, '')) <> '' AND lower(texture) <> 'original'").to_i,
        first_seen: database.get_first_value("SELECT MIN(detected_at_epoch) FROM listings WHERE status='sent'").to_i,
        database_size: File.file?(database_path) ? File.size(database_path) : 0
      }
    end

    def texture_rows(database)
      clauses = ["texture_key <> 'original'"]
      values = []
      unless feed_filter == "all"
        clauses << "price_type = ?"
        values << feed_filter
      end
      unless feed_query.empty?
        clauses << "(item_key LIKE ? OR lower(sample_item) LIKE ? OR lower(COALESCE(sample_texture, '')) LIKE ? OR lower(last_seller) LIKE ?)"
        search = "%#{GTSStore.fold(feed_query)}%"
        values.concat([search, search, search, search])
      end
      order = {
        "recent" => "last_seen_epoch DESC, sample_item COLLATE NOCASE ASC",
        "rare" => "appearances ASC, last_seen_epoch DESC",
        "popular" => "appearances DESC, last_seen_epoch DESC",
        "price_low" => "min_amount IS NULL, min_amount ASC, last_seen_epoch DESC",
        "price_high" => "max_amount IS NULL, max_amount DESC, last_seen_epoch DESC",
        "name" => "sample_item COLLATE NOCASE ASC, sample_texture COLLATE NOCASE ASC"
      }.fetch(texture_sort)
      where = clauses.join(" AND ")
      total = database.get_first_value("SELECT COUNT(*) FROM item_stats WHERE #{where}", values).to_i
      rows = database.execute(
        "SELECT * FROM item_stats WHERE #{where} ORDER BY #{order} LIMIT ? OFFSET ?",
        values + [TEXTURE_PAGE_SIZE, (feed_page - 1) * TEXTURE_PAGE_SIZE]
      )
      [rows.map { |row| history_row_from_stats(row) }, total]
    end

    def texture_metrics(database)
      {
        total: database.get_first_value("SELECT COUNT(*) FROM item_stats WHERE texture_key <> 'original'").to_i,
        pokemon: database.get_first_value("SELECT COUNT(DISTINCT item_key) FROM item_stats WHERE texture_key <> 'original' AND is_pokemon=1").to_i,
        rare: database.get_first_value("SELECT COUNT(*) FROM item_stats WHERE texture_key <> 'original' AND appearances <= 2").to_i,
        latest: database.get_first_value("SELECT MAX(last_seen_epoch) FROM item_stats WHERE texture_key <> 'original'").to_i
      }
    end

    def merchant_page
      [params.fetch("page", "1").to_i, 1].max
    end

    def merchant_rows(database, limit: MERCHANT_PAGE_SIZE)
      total = database.get_first_value("SELECT COUNT(*) FROM merchant_spawns").to_i
      rows = database.execute(
        "SELECT * FROM merchant_spawns ORDER BY detected_at_epoch DESC LIMIT ? OFFSET ?",
        [limit, (merchant_page - 1) * limit]
      )
      [rows, total]
    end

    def merchant_latest(database)
      database.get_first_row("SELECT * FROM merchant_spawns ORDER BY detected_at_epoch DESC, id DESC LIMIT 1")
    end

    def merchant_metrics(database)
      {
        total: database.get_first_value("SELECT COUNT(*) FROM merchant_spawns").to_i,
        unique_coords: database.get_first_value("SELECT COUNT(DISTINCT world || ':' || x || ':' || y || ':' || z) FROM merchant_spawns").to_i,
        last_seen: database.get_first_value("SELECT MAX(detected_at_epoch) FROM merchant_spawns").to_i,
        day: database.get_first_value("SELECT COUNT(*) FROM merchant_spawns WHERE detected_at_epoch >= ?", [now - 86_400]).to_i
      }
    end

    def enrich_opportunities(database, rows)
      history = database.execute(<<~SQL, [now - (30 * 86_400)])
        SELECT item_key, price_type, amount_value FROM listings
        WHERE status = 'sent' AND amount_value IS NOT NULL AND detected_at_epoch >= ?
        ORDER BY detected_at_epoch DESC LIMIT 4000
      SQL
      statistics = history.group_by { |row| [row["item_key"], row["price_type"]] }.to_h do |key, values|
        [key, robust_price_stats(values.map { |row| row["amount_value"] })]
      end
      rows.map do |row|
        stats = statistics[[row["item_key"], row["price_type"]]] || robust_price_stats([])
        median = stats[:median]
        discount = if median&.positive? && row["amount_value"]
                     ((median - row["amount_value"].to_f) / median * 100).round
                   end
        row.merge(
          "market_median" => median,
          "market_min" => stats[:min],
          "market_max" => stats[:max],
          "market_samples" => stats[:count],
          "market_confidence" => stats[:confidence],
          "market_outliers" => stats[:outliers],
          "discount_percent" => discount,
          "deal" => stats[:count] >= 3 && discount && discount >= 15
        )
      end
    end

    def percentile(sorted_values, fraction)
      return nil if sorted_values.empty?

      position = (sorted_values.length - 1) * fraction
      lower = sorted_values[position.floor]
      upper = sorted_values[position.ceil]
      lower + ((upper - lower) * (position - position.floor))
    end

    def robust_price_stats(values)
      prices = values.compact.map(&:to_f).select(&:positive?).sort
      filtered = prices
      if prices.length >= 8
        first_quartile = percentile(prices, 0.25)
        third_quartile = percentile(prices, 0.75)
        spread = third_quartile - first_quartile
        minimum = first_quartile - (spread * 1.5)
        maximum = third_quartile + (spread * 1.5)
        without_outliers = prices.select { |price| price.between?(minimum, maximum) }
        filtered = without_outliers if without_outliers.length >= 3
      end
      count = filtered.length
      {
        count: count,
        min: filtered.min,
        max: filtered.max,
        median: percentile(filtered, 0.5),
        outliers: prices.length - count,
        confidence: count >= 20 ? "alta" : (count >= 8 ? "média" : (count >= 3 ? "baixa" : "insuficiente"))
      }
    end

    def item_period_comparison(database, item_key, price_type)
      periods = { "24 horas" => 86_400, "7 dias" => 604_800, "30 dias" => 2_592_000 }
      comparison = periods.to_h do |label, seconds|
        values = database.execute(
          "SELECT amount_value FROM listings WHERE status='sent' AND item_key=? AND price_type=? AND amount_value IS NOT NULL AND detected_at_epoch >= ?",
          [item_key, price_type, now - seconds]
        ).map { |row| row["amount_value"] }
        [label, robust_price_stats(values)]
      end
      current_week = comparison.fetch("7 dias")[:median]
      previous_values = database.execute(<<~SQL, [item_key, price_type, now - (14 * 86_400), now - (7 * 86_400)])
        SELECT amount_value FROM listings
        WHERE status='sent' AND item_key=? AND price_type=? AND amount_value IS NOT NULL
          AND detected_at_epoch >= ? AND detected_at_epoch < ?
      SQL
      previous_week = robust_price_stats(previous_values.map { |row| row["amount_value"] })[:median]
      trend = if current_week&.positive? && previous_week&.positive?
                ((current_week - previous_week) / previous_week * 100).round
              end
      [comparison, trend]
    end

    def dashboard_stats(database)
      since = now - 86_400
      counts = database.execute(
        "SELECT price_type, COUNT(*) AS total FROM listings WHERE status='sent' AND detected_at_epoch >= ? GROUP BY price_type",
        [since]
      ).to_h { |row| [row["price_type"], row["total"].to_i] }
      {
        "total" => counts.values.sum,
        "money" => counts.fetch("money", 0),
        "token" => counts.fetch("token", 0),
        "site" => counts.fetch("site", 0),
        "queue" => database.get_first_value("SELECT COUNT(*) FROM notification_queue WHERE status IN ('pending','retry','processing')").to_i,
        "alerts" => database.get_first_value("SELECT COUNT(*) FROM alert_matches WHERE user_id = ? AND seen_at IS NULL", [@current_user["id"]]).to_i
      }
    end

    def system_health(database)
      statuses = database.execute("SELECT * FROM service_status ORDER BY name").to_h { |row| [row["name"], row] }
      site_url_path = File.join(ROOT, "runtime", "site_url.txt")
      tunnel_status_path = File.join(ROOT, "runtime", "tunnel_status.txt")
      statuses["panel"] = { "name" => "panel", "status" => "online", "detail" => "Ruby/Puma", "updated_at" => now }
      if File.file?(tunnel_status_path)
        status, timestamp, detail = File.read(tunnel_status_path).strip.split("\t", 3)
        statuses["tunnel"] = { "name" => "tunnel", "status" => status.to_s, "detail" => detail.to_s, "updated_at" => timestamp.to_i }
      elsif File.file?(site_url_path)
        statuses["tunnel"] = { "name" => "tunnel", "status" => "online", "detail" => File.read(site_url_path).strip, "updated_at" => File.mtime(site_url_path).to_i }
      end
      statuses
    end

    def format_number(value)
      return "—" if value.nil?

      whole, decimal = format("%.2f", value.to_f).split(".", 2)
      "#{whole.reverse.scan(/.{1,3}/).join('.').reverse},#{decimal}"
    end

    def format_coord(value)
      number = value.to_f
      number == number.to_i ? number.to_i.to_s : format("%.2f", number).sub(/\.?0+\z/, "")
    end

    def merchant_coord_text(row)
      row["coordinate_text"].to_s.empty? ? [row["x"], row["y"], row["z"]].map { |value| format_coord(value) }.join(" ") : row["coordinate_text"]
    end

    def merchant_route_text(row)
      "/warp #{row['world']}\n#{merchant_coord_text(row)}"
    end

    def format_file_size(bytes)
      units = %w[B KB MB GB]
      size = bytes.to_f
      unit = units.shift
      while size >= 1024 && !units.empty?
        size /= 1024
        unit = units.shift
      end
      unit == "B" ? "#{size.to_i} #{unit}" : "#{format('%.1f', size)} #{unit}"
    end

    def confidence_class(value)
      { "alta" => "high", "média" => "medium", "baixa" => "low" }.fetch(value.to_s, "insufficient")
    end

    def favorite?(kind, value)
      @favorite_keys&.include?("#{kind}:#{GTSStore.fold(value)}")
    end

    def safe_return_to(value, fallback = "/dashboard")
      destination = value.to_s
      destination.start_with?("/") && !destination.start_with?("//") ? destination : fallback
    end

    def market_return_path
      allowed = params.to_h.select { |key, _value| %w[q type texture period sort min max page].include?(key) }
      query = Rack::Utils.build_query(allowed)
      query.empty? ? "/dashboard" : "/dashboard?#{query}"
    end

    def price_type(row)
      type = row["price_type"].to_s
      %w[money token site].include?(type) ? type : "unknown"
    end

    def pokemon_listing?(row)
      row["is_pokemon"].to_i == 1
    end

    def hidden_ability?(row)
      row["hidden_ability"].to_i == 1 || row["ability"].to_s.match?(/\(\s*HA\b\s*\)?/i)
    end

    def ability_name(row)
      row["ability"].to_s.gsub(/\(\s*HA\b\s*\)?/i, "").strip
    end

    def pokemon_profile_value(value)
      text = value.to_s.strip
      return "" if text.empty?

      {
        "macho" => "Male",
        "femea" => "Female",
        "masculino" => "Male",
        "feminino" => "Female",
        "nenhum" => "None",
        "sem genero" => "None",
        "nao" => "No",
        "sim" => "Yes"
      }.fetch(GTSStore.fold(text), text)
    end

    def pokemon_profile_fields(row)
      [
        ["ABILITY", ability_name(row)],
        ["NATURE", pokemon_profile_value(row["nature"])],
        ["GENDER", pokemon_profile_value(row["gender"])],
        ["SIZE", pokemon_profile_value(row["pokemon_size"])],
        ["TEXTURE", pokemon_profile_value(row["texture"])],
        ["UNBREEDABLE", pokemon_profile_value(row["unbreedable"])]
      ]
    end

    def custom_texture?(row)
      !row["texture"].to_s.empty? && row["texture"].to_s.casecmp("original") != 0
    end

    def parse_optional_float(value)
      text = value.to_s.strip
      text.empty? ? nil : Float(text)
    end

    def alert_searchable_text(alert, listing)
      case alert["match_mode"].to_s
      when "seller"
        listing["seller"].to_s
      when "item", "pokemon"
        listing["item"].to_s
      when "texture"
        listing["texture"].to_s
      else
        "#{listing['item']} #{listing['seller']} #{listing['texture']} #{listing['ability']} #{listing['nature']} #{listing['raw_chat']}"
      end
    end

    def alert_matches_listing?(alert, listing)
      query = GTSStore.fold(alert["query"]).strip
      return false if !query.empty? && !GTSStore.fold(alert_searchable_text(alert, listing)).include?(query)
      return false unless alert["price_type"].to_s.empty? || alert["price_type"] == "all" || alert["price_type"] == listing["price_type"]

      amount = listing["amount_value"]&.to_f
      return false if alert["min_amount"] && (!amount || amount < alert["min_amount"].to_f)
      return false if alert["max_amount"] && (!amount || amount > alert["max_amount"].to_f)

      texture_query = GTSStore.fold(alert["texture_query"]).strip
      listing_texture = GTSStore.fold(listing["texture"]).strip
      unless texture_query.empty?
        if %w[custom txt textura customizada].include?(texture_query) || texture_query == "textura custom" || texture_query == "qualquer txt"
          return false if listing_texture.empty? || listing_texture == "original"
        elsif texture_query == "original"
          return false unless listing_texture == "original"
        else
          return false unless listing_texture.include?(texture_query)
        end
      end

      return false if alert["hidden_ability_only"].to_i == 1 && !hidden_ability?(listing)
      minimum_iv = alert["min_iv_percent"]
      return false if minimum_iv && (!listing["iv_percent"] || listing["iv_percent"].to_f < minimum_iv.to_f)

      true
    end

    def alert_description(alert)
      parts = []
      parts << (alert["price_type"] == "all" ? "todas as moedas" : alert["price_type"].to_s)
      texture_query = alert["texture_query"].to_s.strip
      parts << (GTSStore.fold(texture_query).match?(/\A(custom|txt|textura|customizada|qualquer txt)\z/) ? "qualquer TXT customizada" : "TXT #{texture_query}") unless texture_query.empty?
      parts << "IV >= #{format('%.0f', alert['min_iv_percent'].to_f)}%" if alert["min_iv_percent"]
      parts << "HA" if alert["hidden_ability_only"].to_i == 1
      parts << alert["channels"].to_s
      parts.reject(&:empty?).join(" · ")
    end

    def selected_alert_channels
      channels = ["site"]
      channels << "discord" if params["discord"] == "1"
      channels << "telegram" if params["telegram"] == "1"
      channels.join(",")
    end

    def create_priority_texture_alerts(database, user_id, channels)
      created = 0
      PRIORITY_TEXTURE_TARGETS.each do |target|
        existing = database.get_first_value(<<~SQL, [user_id, GTSStore.fold(target)])
          SELECT id FROM alerts
          WHERE user_id = ? AND lower(query) = ? AND COALESCE(texture_query, '') IN ('custom', 'txt')
        SQL
        next if existing

        database.execute(<<~SQL, [user_id, target, channels, now])
          INSERT INTO alerts(user_id, query, price_type, match_mode, texture_query, channels, active, created_at)
          VALUES (?, ?, 'all', 'item', 'custom', ?, 1, ?)
        SQL
        created += 1
      end
      created
    end

    def listing_moves(row)
      parsed = JSON.parse(row["moves_json"].to_s)
      parsed.is_a?(Array) ? parsed.map(&:to_s).reject(&:empty?) : []
    rescue JSON::ParserError
      []
    end

    def pokemon_stats(row, prefix)
      [
        ["HP", row["#{prefix}_hp"]], ["Atk", row["#{prefix}_attack"]],
        ["Def", row["#{prefix}_defense"]], ["SpA", row["#{prefix}_sp_attack"]],
        ["SpD", row["#{prefix}_sp_defense"]], ["Spe", row["#{prefix}_speed"]]
      ]
    end

    def page(title, template, **locals)
      @title = title
      @page_class = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
      erb(template, locals: locals)
    end

    def request_base_url
      host = request.env["HTTP_X_FORWARDED_HOST"].to_s
      host = request.host_with_port if host.empty?
      protocol = request.env["HTTP_X_FORWARDED_PROTO"].to_s
      protocol = request.scheme if protocol.empty?
      protocol = "https" if host.end_with?(".trycloudflare.com")
      "#{protocol}://#{host}"
    end

    def approval_recipients
      configured = config_env("PANEL_OWNER_EMAIL").split(/[;,]/).map(&:strip).reject(&:empty?)
      return configured unless configured.empty?

      fallback = config_env("PANEL_ADMIN_EMAIL")
      fallback.empty? ? [] : [fallback]
    end

    def client_ip
      forwarded = request.env["HTTP_CF_CONNECTING_IP"].to_s.split(",").first.to_s.strip
      forwarded.empty? ? request.ip : forwarded
    end

    def login_blocked?(database, email)
      failures = database.get_first_value(<<~SQL, [email, client_ip, now - LOGIN_WINDOW]).to_i
        SELECT COUNT(*) FROM login_attempts
        WHERE email = ? AND ip = ? AND succeeded = 0 AND created_at >= ?
      SQL
      failures >= LOGIN_MAX_FAILURES
    end

    def record_login_attempt(database, email, succeeded)
      database.execute(
        "INSERT INTO login_attempts(email, ip, succeeded, created_at) VALUES (?, ?, ?, ?)",
        [email, client_ip, succeeded ? 1 : 0, now]
      )
      database.execute("DELETE FROM login_attempts WHERE created_at < ?", [now - (7 * 86_400)])
    end

    def send_email(recipients, subject, body)
      recipients = Array(recipients).map(&:to_s).map(&:strip).reject(&:empty?)
      smtp_host = config_env("SMTP_HOST")
      smtp_user = config_env("SMTP_USER")
      smtp_password = config_env("SMTP_PASSWORD")
      from = config_env("SMTP_FROM", smtp_user)
      if recipients.empty? || smtp_host.empty? || smtp_user.empty? || smtp_password.empty? || from.empty?
        warn "\n=== EMAIL LOCAL: #{subject} ===\n#{body}=== FIM ===\n"
        return false
      end

      message = <<~MAIL
        From: #{from}
        To: #{recipients.join(', ')}
        Subject: #{subject}
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8

        #{body}
      MAIL
      smtp = Net::SMTP.new(smtp_host, Integer(config_env("SMTP_PORT", "587")))
      smtp.enable_starttls if env_bool("SMTP_TLS", true)
      smtp.start(smtp_host, smtp_user, smtp_password, :login) { |connection| connection.send_message(message, from, recipients) }
      true
    rescue StandardError => e
      warn "Falha ao enviar email: #{e.message}"
      false
    end

    def notify_pending(user)
      token = CGI.escapeURIComponent(user["approval_token"])
      body = <<~BODY
        Nova solicitação de acesso ao painel Pixelmon GTS.

        Nome: #{user['name']}
        Email: #{user['email']}
        Convite: #{user['invite_code'].to_s.empty? ? 'sem convite' : user['invite_code']}

        Aprovar: #{request_base_url}/review?token=#{token}&decision=approve
        Recusar: #{request_base_url}/review?token=#{token}&decision=deny
      BODY

      send_email(approval_recipients, "Nova solicitacao de acesso ao Pixelmon GTS", body)
    end

    def consume_invite(database, code)
      clean_code = code.to_s.strip
      return [!env_bool("PANEL_REQUIRE_INVITE_CODE"), "Código de convite obrigatório."] if clean_code.empty?

      invite = database.get_first_row("SELECT * FROM invite_codes WHERE code = ? AND active = 1", [clean_code])
      return [false, "Código de convite inválido."] unless invite
      return [false, "Código de convite expirado."] if invite["expires_at"] && invite["expires_at"].to_i < now
      return [false, "Código de convite já usado."] if invite["used_count"].to_i >= invite["max_uses"].to_i

      database.execute("UPDATE invite_codes SET used_count = used_count + 1 WHERE id = ?", [invite["id"]])
      [true, ""]
    end

  end

  before do
    headers(
      "X-Content-Type-Options" => "nosniff",
      "X-Frame-Options" => "DENY",
      "Referrer-Policy" => "same-origin",
      "Permissions-Policy" => "camera=(), microphone=(), geolocation=()",
      "Content-Security-Policy" => "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'"
    )
    headers("Strict-Transport-Security" => "max-age=31536000") if request.secure? || request.env["HTTP_X_FORWARDED_PROTO"] == "https"
    load_current_user
  end

  get "/health" do
    content_type "text/plain"
    "ok"
  end

  get "/" do
    redirect(@current_user ? "/dashboard" : "/login")
  end

  get "/login" do
    redirect "/dashboard" if @current_user&.fetch("status", nil) == "approved"
    page("Entrar", :login, message: nil)
  end

  post "/login" do
    email = params.fetch("email", "").strip.downcase
    password = params.fetch("password", "")
    user = nil
    session_id = nil
    with_db do |database|
      halt 429, page("Entrar", :login, message: "Muitas tentativas. Aguarde 15 minutos.") if login_blocked?(database, email)
      user = database.get_first_row("SELECT * FROM users WHERE email = ?", [email])
      unless user && valid_password?(password, user["password_hash"])
        record_login_attempt(database, email, false)
        halt 401, page("Entrar", :login, message: "Email ou senha inválidos.")
      end
      halt 403, page("Entrar", :login, message: "Conta ainda não aprovada.") unless user["status"] == "approved"

      session_id, = create_session(database, user["id"])
      record_login_attempt(database, email, true)
      database.execute("UPDATE users SET last_login_at = ? WHERE id = ?", [now, user["id"]])
      log_event(database, "login", user["id"], email)
    end
    set_session_cookie(session_id)
    redirect "/dashboard"
  end

  get "/register" do
    page("Solicitar acesso", :register, message: nil)
  end

  post "/register" do
    name = params.fetch("name", "").strip
    email = params.fetch("email", "").strip.downcase
    password = params.fetch("password", "")
    invite_code = params.fetch("invite_code", "").strip
    halt page("Solicitar acesso", :register, message: "Informe um nome válido.") if name.length < 2
    halt page("Solicitar acesso", :register, message: "Informe um email válido.") unless email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
    halt page("Solicitar acesso", :register, message: "A senha precisa ter pelo menos 8 caracteres.") if password.length < 8

    user = nil
    with_db do |database|
      halt page("Solicitar acesso", :register, message: "Esse email já está cadastrado.") if database.get_first_value("SELECT 1 FROM users WHERE email = ?", [email])

      database.transaction
      allowed, error = consume_invite(database, invite_code)
      unless allowed
        database.rollback
        halt page("Solicitar acesso", :register, message: error)
      end
      approval_token = SecureRandom.urlsafe_base64(32)
      database.execute(<<~SQL, [email, name, hash_password(password), invite_code, approval_token, now])
        INSERT INTO users (email, name, password_hash, role, status, invite_code, approval_token, created_at)
        VALUES (?, ?, ?, 'user', 'pending', ?, ?, ?)
      SQL
      user = database.get_first_row("SELECT * FROM users WHERE email = ?", [email])
      log_event(database, "register_pending", user["id"], email)
      database.commit
    rescue SQLite3::ConstraintException
      database.rollback
      halt page("Solicitar acesso", :register, message: "Esse email já está cadastrado.")
    end
    notify_pending(user)
    page("Solicitação enviada", :status, code: "RX", title: "Solicitação enviada", message: "Sua conta entrou na fila de aprovação.")
  end

  post "/logout" do
    if @current_user
      csrf!
      with_db { |database| database.execute("DELETE FROM sessions WHERE id = ?", [@current_user["session_id"]]) }
    end
    clear_session_cookie
    redirect "/login"
  end

  post "/theme" do
    csrf! if @current_user
    next_theme = dark_theme? ? "light" : "dark"
    response.set_cookie(
      "gts_panel_theme",
      value: next_theme,
      path: "/",
      max_age: 60 * 60 * 24 * 365,
      httponly: true,
      same_site: :lax,
      secure: request.secure? || request.env["HTTP_X_FORWARDED_PROTO"] == "https"
    )
    destination = params.fetch("return_to", "/").to_s
    destination = "/" unless destination.start_with?("/") && !destination.start_with?("//")
    redirect destination
  end

  get "/dashboard" do
    approved!
    with_db do |database|
      @rows, @total_rows = listing_rows(database)
      @feed_version = database.get_first_value("SELECT COALESCE(MAX(id), 0) FROM listings WHERE status='sent'").to_i
      @stats = dashboard_stats(database)
      @health = system_health(database)
      @recent_matches = database.execute(<<~SQL, [@current_user["id"]])
        SELECT alert_matches.*, listings.item, listings.price, listings.price_type
        FROM alert_matches JOIN listings ON listings.id = alert_matches.listing_id
        WHERE alert_matches.user_id = ? ORDER BY alert_matches.created_at DESC LIMIT 5
      SQL
    end
    @filter = feed_filter
    @texture_filter = feed_texture
    @query = feed_query
    @page = feed_page
    page("Dashboard", :dashboard)
  end

  get "/feed" do
    approved!
    with_db do |database|
      @rows, @total_rows = listing_rows(database)
      @feed_version = database.get_first_value("SELECT COALESCE(MAX(id), 0) FROM listings WHERE status='sent'").to_i
      @stats = dashboard_stats(database)
    end
    @filter = feed_filter
    @texture_filter = feed_texture
    @query = feed_query
    @page = feed_page
    @oob = params["oob"] != "0"
    erb :feed, layout: false
  end

  get "/feed/version" do
    approved!
    content_type :json
    headers "Cache-Control" => "no-store, max-age=0"
    latest_id = with_db do |database|
      database.get_first_value("SELECT COALESCE(MAX(id), 0) FROM listings WHERE status='sent'").to_i
    end
    JSON.generate(id: latest_id, checked_at: now)
  end

  get "/history" do
    approved!
    with_db do |database|
      @history_rows, @total_rows = history_rows(database)
      @history_metrics = history_metrics(database)
    end
    @filter = feed_filter
    @texture_filter = feed_texture
    @query = feed_query
    @page = feed_page
    @period = history_period
    @sort = history_sort
    page("Histórico", :history)
  end

  get "/textures" do
    approved!
    with_db do |database|
      @texture_rows, @total_rows = texture_rows(database)
      @texture_metrics = texture_metrics(database)
    end
    @filter = feed_filter
    @query = feed_query
    @page = feed_page
    @sort = texture_sort
    page("Texturas", :textures)
  end

  get "/merchant" do
    approved!
    with_db do |database|
      @merchant_rows, @total_rows = merchant_rows(database)
      @latest_merchant = merchant_latest(database)
      @merchant_metrics = merchant_metrics(database)
      @merchant_version = @latest_merchant&.fetch("id", 0).to_i
    end
    @page = merchant_page
    page("Mercador Viajante", :merchant)
  end

  get "/merchant/feed" do
    approved!
    with_db do |database|
      @merchant_rows, @total_rows = merchant_rows(database)
      @latest_merchant = merchant_latest(database)
      @merchant_metrics = merchant_metrics(database)
      @merchant_version = @latest_merchant&.fetch("id", 0).to_i
    end
    @page = merchant_page
    erb :merchant_feed, layout: false
  end

  get "/merchant/version" do
    approved!
    content_type :json
    headers "Cache-Control" => "no-store, max-age=0"
    latest = with_db { |database| merchant_latest(database) }
    payload = if latest
                {
                  id: latest["id"].to_i,
                  world: latest["world"],
                  location: latest["location"],
                  coordinate_text: merchant_coord_text(latest),
                  route_text: merchant_route_text(latest),
                  detected_at: latest["detected_at"],
                  detected_at_epoch: latest["detected_at_epoch"].to_i
                }
              else
                { id: 0 }
              end
    JSON.generate(payload.merge(checked_at: now))
  end

  get "/notifications/check" do
    approved!
    content_type :json
    headers "Cache-Control" => "no-store, max-age=0"
    after_id = [params.fetch("after", "0").to_i, 0].max
    result = with_db do |database|
      favorites = database.execute("SELECT kind, value_key FROM favorites WHERE user_id=?", [@current_user["id"]])
      favorite_items = favorites.select { |row| row["kind"] == "item" }.map { |row| row["value_key"] }.to_set
      favorite_sellers = favorites.select { |row| row["kind"] == "seller" }.map { |row| row["value_key"] }.to_set
      alerts = database.execute("SELECT * FROM alerts WHERE user_id=? AND active=1", [@current_user["id"]])
      listings = database.execute(
        "SELECT * FROM listings WHERE status='sent' AND id>? ORDER BY id ASC LIMIT 50",
        [after_id]
      )
      matches = listings.filter_map do |listing|
        reasons = []
        reasons << "Item favorito" if favorite_items.include?(listing["item_key"])
        reasons << "Vendedor favorito" if favorite_sellers.include?(GTSStore.fold(listing["seller"]))
        alerts.each do |alert|
          next unless alert_matches_listing?(alert, listing)

          reasons << "Alerta: #{alert_description(alert)}"
        end
        next if reasons.empty?
        {
          id: listing["id"], item: listing["item"], seller: listing["seller"],
          price: listing["price"], reasons: reasons.uniq
        }
      end
      { matches: matches, cursor: listings.last&.fetch("id", after_id) || after_id }
    end
    JSON.generate(result)
  end

  get "/listing/:id" do
    approved!
    with_db do |database|
      @listing = database.get_first_row("SELECT * FROM listings WHERE id = ? AND status='sent'", [params["id"].to_i])
      halt 404, page("Não encontrado", :status, code: "404", title: "Anúncio não encontrado", message: "Este registro não existe mais.") unless @listing
      @listing_stats = database.get_first_row(
        "SELECT * FROM item_stats WHERE item_key=? AND texture_key=? AND price_type=?",
        [
          @listing["item_key"],
          GTSStore.texture_key(@listing["texture"]),
          @listing["price_type"].to_s.empty? ? "unknown" : @listing["price_type"]
        ]
      )
      @price_history = database.execute(<<~SQL, [@listing["item_key"], @listing["price_type"]])
        SELECT * FROM listings WHERE item_key = ? AND price_type = ? AND status='sent' AND amount_value IS NOT NULL
        ORDER BY detected_at_epoch DESC LIMIT 60
      SQL
      @price_stats = robust_price_stats(@price_history.map { |row| row["amount_value"] })
      @period_comparison, @weekly_trend = item_period_comparison(database, @listing["item_key"], @listing["price_type"])
    end
    page("Detalhes", :listing)
  end

  get "/listing/:id/image" do
    approved!
    listing = with_db do |database|
      database.get_first_row("SELECT * FROM listings WHERE id = ? AND status='sent'", [params["id"].to_i])
    end
    halt 404 unless listing && asset_catalog

    image_path = asset_catalog.cache(listing, File.join(ROOT, "runtime", "listing-assets"))
    halt 404 unless image_path

    content_type "image/png"
    headers "Cache-Control" => "private, max-age=86400"
    send_file image_path, disposition: "inline"
  end

  get "/seller/:name" do
    approved!
    seller_key = params["name"].to_s.downcase
    with_db do |database|
      @seller_rows = database.execute(
        "SELECT * FROM listings WHERE status='sent' AND lower(seller)=? ORDER BY detected_at_epoch DESC LIMIT 100",
        [seller_key]
      )
      halt 404, page("Não encontrado", :status, code: "404", title: "Vendedor não encontrado", message: "Nenhum anúncio global válido foi encontrado.") if @seller_rows.empty?
      @seller = @seller_rows.first["seller"]
      @seller_metrics = {
        day: database.get_first_value("SELECT COUNT(*) FROM listings WHERE status='sent' AND lower(seller)=? AND detected_at_epoch>=?", [seller_key, now - 86_400]).to_i,
        week: database.get_first_value("SELECT COUNT(*) FROM listings WHERE status='sent' AND lower(seller)=? AND detected_at_epoch>=?", [seller_key, now - (7 * 86_400)]).to_i,
        month: database.get_first_value("SELECT COUNT(*) FROM listings WHERE status='sent' AND lower(seller)=? AND detected_at_epoch>=?", [seller_key, now - (30 * 86_400)]).to_i,
        items: database.get_first_value("SELECT COUNT(DISTINCT item_key) FROM listings WHERE status='sent' AND lower(seller)=? AND detected_at_epoch>=?", [seller_key, now - (30 * 86_400)]).to_i
      }
      @seller_top_items = database.execute(<<~SQL, [seller_key, now - (30 * 86_400)])
        SELECT item, item_key, price_type, COUNT(*) AS total, MIN(amount_value) AS minimum,
               MAX(amount_value) AS maximum, MAX(detected_at_epoch) AS last_seen
        FROM listings WHERE status='sent' AND lower(seller)=? AND detected_at_epoch>=?
        GROUP BY item_key, price_type ORDER BY total DESC, last_seen DESC LIMIT 12
      SQL
    end
    page("Vendedor", :seller)
  end

  get "/opportunities" do
    approved!
    @filter = feed_filter
    with_db do |database|
      clauses = ["status='sent'", "amount_value IS NOT NULL", "detected_at_epoch >= ?"]
      values = [now - (30 * 86_400)]
      unless @filter == "all"
        clauses << "price_type = ?"
        values << @filter
      end
      rows = database.execute(
        "SELECT * FROM listings WHERE #{clauses.join(' AND ')} ORDER BY detected_at_epoch DESC LIMIT 1500",
        values
      )
      @opportunities = enrich_opportunities(database, rows)
                       .select { |row| row["deal"] }
                       .sort_by { |row| [-row["discount_percent"].to_i, -row["detected_at_epoch"].to_i] }
                       .first(100)
      @opportunity_summary = @opportunities.group_by { |row| row["price_type"] }.transform_values(&:length)
    end
    page("Oportunidades", :opportunities)
  end

  get "/favorites" do
    approved!
    with_db do |database|
      favorites = database.execute("SELECT * FROM favorites WHERE user_id = ? ORDER BY created_at DESC", [@current_user["id"]])
      @favorites = favorites.map do |favorite|
        column = favorite["kind"] == "item" ? "item_key" : "lower(seller)"
        latest = database.get_first_row(
          "SELECT * FROM listings WHERE status='sent' AND #{column} = ? ORDER BY detected_at_epoch DESC LIMIT 1",
          [favorite["value_key"]]
        )
        count = database.get_first_value(
          "SELECT COUNT(*) FROM listings WHERE status='sent' AND #{column} = ? AND detected_at_epoch >= ?",
          [favorite["value_key"], now - (30 * 86_400)]
        ).to_i
        favorite.merge("latest" => latest, "monthly_count" => count)
      end
    end
    page("Favoritos", :favorites)
  end

  post "/favorites" do
    approved!
    csrf!
    kind = params["kind"].to_s
    value = params["value"].to_s.strip[0, 160]
    halt 422, "Favorito inválido." unless %w[item seller].include?(kind) && value.length >= 2
    value_key = GTSStore.fold(value)
    with_db do |database|
      existing = database.get_first_value(
        "SELECT id FROM favorites WHERE user_id=? AND kind=? AND value_key=?",
        [@current_user["id"], kind, value_key]
      )
      if existing
        database.execute("DELETE FROM favorites WHERE id=?", [existing])
        action = "removed"
      else
        database.execute(
          "INSERT INTO favorites(user_id, kind, value, value_key, created_at) VALUES (?, ?, ?, ?, ?)",
          [@current_user["id"], kind, value, value_key, now]
        )
        action = "added"
      end
      log_event(database, "favorite_#{action}", @current_user["id"], "#{kind}:#{value}")
    end
    redirect safe_return_to(params["return_to"], "/favorites")
  end

  get "/alerts" do
    approved!
    with_db do |database|
      @alerts = database.execute("SELECT * FROM alerts WHERE user_id = ? ORDER BY created_at DESC", [@current_user["id"]])
      existing_priority = @alerts
                          .select { |alert| %w[custom txt].include?(alert["texture_query"].to_s) }
                          .map { |alert| GTSStore.fold(alert["query"]) }
                          .to_set
      @priority_missing = PRIORITY_TEXTURE_TARGETS.reject { |target| existing_priority.include?(GTSStore.fold(target)) }
      @matches = database.execute(<<~SQL, [@current_user["id"]])
        SELECT alert_matches.*, alerts.query, alerts.texture_query, alerts.min_iv_percent, alerts.hidden_ability_only,
               listings.item, listings.seller, listings.price, listings.price_type, listings.texture, listings.iv_percent
        FROM alert_matches
        JOIN alerts ON alerts.id = alert_matches.alert_id
        JOIN listings ON listings.id = alert_matches.listing_id
        WHERE alert_matches.user_id = ? ORDER BY alert_matches.created_at DESC LIMIT 50
      SQL
      database.execute("UPDATE alert_matches SET seen_at = ? WHERE user_id = ? AND seen_at IS NULL", [now, @current_user["id"]])
    end
    page("Alertas", :alerts, message: nil)
  end

  post "/alerts" do
    approved!
    csrf!
    query = params.fetch("query", "").strip[0, 80]
    halt 422, page("Alertas", :status, code: "422", title: "Alerta inválido", message: "Informe um item, Pokémon ou vendedor.") if query.length < 2
    price_type = %w[all money token site].include?(params["price_type"]) ? params["price_type"] : "all"
    match_mode = %w[text item seller texture].include?(params["match_mode"]) ? params["match_mode"] : "text"
    texture_query = params.fetch("texture_query", "").strip[0, 80]
    hidden_ability_only = params["hidden_ability_only"] == "1" ? 1 : 0
    minimum = params["min_amount"].to_s.strip
    maximum = params["max_amount"].to_s.strip
    minimum_iv = parse_optional_float(params["min_iv_percent"])
    halt 422, page("Alertas", :status, code: "422", title: "IV inválido", message: "Use IV mínimo entre 0 e 100.") if minimum_iv && !minimum_iv.between?(0, 100)
    with_db do |database|
      database.execute(
        "INSERT INTO alerts(user_id, query, price_type, min_amount, max_amount, match_mode, texture_query, min_iv_percent, hidden_ability_only, channels, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
          @current_user["id"], query, price_type, minimum.empty? ? nil : Float(minimum),
          maximum.empty? ? nil : Float(maximum), match_mode, texture_query.empty? ? nil : texture_query,
          minimum_iv, hidden_ability_only, selected_alert_channels, now
        ]
      )
      log_event(database, "alert_created", @current_user["id"], "#{query} #{texture_query}".strip)
    end
    redirect "/alerts"
  rescue ArgumentError
    halt 422, page("Alertas", :status, code: "422", title: "Número inválido", message: "Use apenas números nos limites de preço e IV.")
  end

  post "/alerts/priority-textures" do
    approved!
    csrf!
    with_db do |database|
      created = create_priority_texture_alerts(database, @current_user["id"], selected_alert_channels)
      log_event(database, "priority_texture_alerts", @current_user["id"], "#{created} criados")
    end
    redirect "/alerts?notice=priority_textures"
  end

  post "/alerts/:id" do
    approved!
    csrf!
    with_db do |database|
      if params["action"] == "delete"
        database.execute("DELETE FROM alerts WHERE id = ? AND user_id = ?", [params["id"].to_i, @current_user["id"]])
      else
        database.execute("UPDATE alerts SET active = CASE active WHEN 1 THEN 0 ELSE 1 END WHERE id = ? AND user_id = ?", [params["id"].to_i, @current_user["id"]])
      end
      log_event(database, "alert_#{params['action']}", @current_user["id"], params["id"])
    end
    redirect "/alerts"
  end

  get "/settings" do
    approved!
    page("Preferências", :settings, message: nil)
  end

  post "/settings" do
    approved!
    csrf!
    discord_id = params.fetch("discord_user_id", "").strip
    telegram_id = params.fetch("telegram_chat_id", "").strip
    halt 422, page("Preferências", :settings, message: "O ID do Discord deve conter apenas números.") unless discord_id.empty? || discord_id.match?(/\A\d{15,22}\z/)
    halt 422, page("Preferências", :settings, message: "O ID do Telegram deve conter apenas números e sinal negativo opcional.") unless telegram_id.empty? || telegram_id.match?(/\A-?\d{5,20}\z/)
    with_db do |database|
      database.execute(
        "UPDATE users SET discord_user_id=?, telegram_chat_id=?, notifications_enabled=? WHERE id=?",
        [discord_id, telegram_id, params["notifications_enabled"] == "1" ? 1 : 0, @current_user["id"]]
      )
      log_event(database, "settings_updated", @current_user["id"])
    end
    redirect "/settings?saved=1"
  end

  get "/forgot-password" do
    page("Recuperar senha", :forgot_password, message: nil)
  end

  post "/forgot-password" do
    email = params.fetch("email", "").strip.downcase
    with_db do |database|
      user = database.get_first_row("SELECT * FROM users WHERE email = ? AND status='approved'", [email])
      if user
        token = SecureRandom.urlsafe_base64(32)
        database.execute("DELETE FROM password_reset_tokens WHERE user_id = ?", [user["id"]])
        database.execute(
          "INSERT INTO password_reset_tokens(token, user_id, expires_at, created_at) VALUES (?, ?, ?, ?)",
          [token, user["id"], now + RESET_TTL, now]
        )
        send_email(email, "Recuperacao de senha do Pixelmon GTS", "Redefina sua senha em: #{request_base_url}/reset-password?token=#{CGI.escapeURIComponent(token)}\n")
      end
    end
    page("Recuperar senha", :status, code: "OK", title: "Solicitação recebida", message: "Se o email estiver cadastrado, enviaremos um link de recuperação.")
  end

  get "/reset-password" do
    @reset_token = params.fetch("token", "")
    valid = with_db do |database|
      database.get_first_value("SELECT 1 FROM password_reset_tokens WHERE token=? AND used_at IS NULL AND expires_at >= ?", [@reset_token, now])
    end
    halt 404, page("Link expirado", :status, code: "404", title: "Link inválido", message: "Solicite uma nova recuperação de senha.") unless valid
    page("Nova senha", :reset_password, message: nil)
  end

  post "/reset-password" do
    token = params.fetch("token", "")
    password = params.fetch("password", "")
    @reset_token = token
    halt 422, page("Nova senha", :reset_password, message: "A senha precisa ter pelo menos 10 caracteres.") if password.length < 10
    changed = with_db do |database|
      reset = database.get_first_row("SELECT * FROM password_reset_tokens WHERE token=? AND used_at IS NULL AND expires_at >= ?", [token, now])
      next false unless reset
      database.transaction
      database.execute("UPDATE users SET password_hash=? WHERE id=?", [hash_password(password), reset["user_id"]])
      database.execute("UPDATE password_reset_tokens SET used_at=? WHERE token=?", [now, token])
      database.execute("DELETE FROM sessions WHERE user_id=?", [reset["user_id"]])
      log_event(database, "password_reset", reset["user_id"])
      database.commit
      true
    end
    halt 404, page("Link expirado", :status, code: "404", title: "Link inválido", message: "Solicite uma nova recuperação de senha.") unless changed
    page("Senha alterada", :status, code: "OK", title: "Senha atualizada", message: "Você já pode entrar usando a nova senha.")
  end

  get "/admin" do
    admin!
    with_db do |database|
      @pending = database.execute("SELECT * FROM users WHERE status = 'pending' ORDER BY created_at DESC")
      @users = database.execute("SELECT * FROM users ORDER BY created_at DESC LIMIT 100")
      @invites = database.execute("SELECT * FROM invite_codes ORDER BY created_at DESC LIMIT 50")
      @events = database.execute(<<~SQL)
        SELECT events.*, users.name AS user_name FROM events
        LEFT JOIN users ON users.id = events.user_id ORDER BY events.created_at DESC LIMIT 30
      SQL
      @queue_summary = database.execute("SELECT status, COUNT(*) AS total FROM notification_queue GROUP BY status").to_h { |row| [row["status"], row["total"].to_i] }
      @health = system_health(database)
      @invalid_count = database.get_first_value("SELECT COUNT(*) FROM listings WHERE status='invalid'").to_i
      @item_stats_count = database.get_first_value("SELECT COUNT(*) FROM item_stats").to_i
      @database_size = File.file?(database_path) ? File.size(database_path) : 0
      @delivery_latency = database.get_first_value(<<~SQL).to_f
        SELECT AVG(sent_at - created_at) FROM (
          SELECT sent_at, created_at FROM notification_queue
          WHERE status='sent' AND sent_at IS NOT NULL ORDER BY sent_at DESC LIMIT 100
        )
      SQL
      @smtp_configured = %w[SMTP_HOST SMTP_USER SMTP_PASSWORD SMTP_FROM].all? { |name| !config_env(name).empty? }
    end
    page("Admin", :admin)
  end

  post "/admin/maintenance" do
    admin!
    csrf!
    action = params["action"].to_s
    halt 400, "Ação inválida." unless %w[rebuild_stats optimize].include?(action)
    with_db do |database|
      case action
      when "rebuild_stats"
        GTSStore.rebuild_item_stats(database)
      when "optimize"
        database.execute("PRAGMA optimize")
      end
      log_event(database, "maintenance_#{action}", @current_user["id"])
    end
    redirect "/admin?notice=#{action}"
  end

  post "/admin/user" do
    admin!
    csrf!
    action = params["action"].to_s
    halt 400, "Ação inválida." unless %w[approve deny revoke promote demote].include?(action)
    target_id = params["user_id"].to_i
    halt 422, "Você não pode alterar sua própria conta por aqui." if target_id == @current_user["id"].to_i
    with_db do |database|
      case action
      when "approve"
        database.execute("UPDATE users SET status='approved', approved_at=? WHERE id=?", [now, target_id])
      when "deny", "revoke"
        database.execute("UPDATE users SET status='denied', approved_at=NULL WHERE id=?", [target_id])
        database.execute("DELETE FROM sessions WHERE user_id=?", [target_id])
      when "promote"
        database.execute("UPDATE users SET role='admin', status='approved', approved_at=COALESCE(approved_at, ?) WHERE id=?", [now, target_id])
      when "demote"
        database.execute("UPDATE users SET role='user' WHERE id=?", [target_id])
      end
      log_event(database, "user_#{action}", target_id)
    end
    redirect "/admin"
  end

  post "/admin/invite" do
    admin!
    csrf!
    max_uses = [params.fetch("max_uses", "1").to_i, 1].max
    code = SecureRandom.urlsafe_base64(8).delete("-_")[0, 10].upcase
    with_db do |database|
      database.execute(
        "INSERT INTO invite_codes (code, note, max_uses, created_at) VALUES (?, ?, ?, ?)",
        [code, params.fetch("note", "").strip, max_uses, now]
      )
      log_event(database, "invite_created", nil, code)
    end
    redirect "/admin"
  end

  get "/admin/invalid" do
    admin!
    @page = [params.fetch("page", "1").to_i, 1].max
    limit = 80
    with_db do |database|
      @invalid_total = database.get_first_value("SELECT COUNT(*) FROM listings WHERE status='invalid'").to_i
      @invalid_rows = database.execute(
        "SELECT * FROM listings WHERE status='invalid' ORDER BY detected_at_epoch DESC LIMIT ? OFFSET ?",
        [limit, (@page - 1) * limit]
      )
    end
    @invalid_pages = [(@invalid_total.to_f / limit).ceil, 1].max
    page("Revisão", :invalid)
  end

  post "/admin/invalid/:id" do
    admin!
    csrf!
    halt 400, "Ação inválida." unless params["action"] == "restore"
    with_db do |database|
      database.execute("UPDATE listings SET status='sent', reason='admin_restored' WHERE id=? AND status='invalid'", [params["id"].to_i])
      GTSStore.update_item_stats(database, params["id"].to_i)
      log_event(database, "invalid_restored", @current_user["id"], params["id"])
    end
    redirect safe_return_to(params["return_to"], "/admin/invalid")
  end

  post "/admin/test-notification" do
    admin!
    csrf!
    channel = params["channel"].to_s
    halt 400, "Canal inválido." unless %w[discord telegram].include?(channel)
    destination = if channel == "discord"
                    @current_user["discord_user_id"].to_s.empty? ? config_env("DISCORD_USER_ID") : @current_user["discord_user_id"].to_s
                  else
                    @current_user["telegram_chat_id"].to_s.empty? ? config_env("TELEGRAM_CHAT_ID") : @current_user["telegram_chat_id"].to_s
                  end
    redirect "/admin?notice=missing_#{channel}" if destination.empty?

    fingerprint = "admin-test-#{SecureRandom.hex(12)}"
    detected_at = Time.now.utc.iso8601
    listing = {
      "item" => "Teste de integração", "price" => "Token 1.00 Tokens", "raw_chat" => "Teste manual do painel",
      "seller" => "GTS_SIGNAL", "amount" => "1.00", "currency" => "Tokens", "price_type" => "token",
      "fingerprint" => fingerprint, "detected_at" => detected_at
    }
    with_db do |database|
      listing_id = GTSStore.insert_listing(database, listing.merge("status" => "test"))
      timestamp = now
      database.execute(
        "INSERT INTO notification_queue(listing_id, alert_id, channel, destination, payload, status, next_attempt_at, created_at) VALUES (?, 0, ?, ?, ?, 'pending', ?, ?)",
        [listing_id, channel, destination, JSON.generate("listing" => listing, "message" => "Teste de integração do painel", "alert" => "Teste manual"), timestamp, timestamp]
      )
      log_event(database, "#{channel}_test_queued", @current_user["id"])
    end
    redirect "/admin?notice=#{channel}_queued"
  end

  get "/review" do
    token = params.fetch("token", "")
    status = { "approve" => "approved", "deny" => "denied" }[params["decision"]]
    halt 400, "Link inválido." if token.empty? || !status
    user = nil
    with_db do |database|
      user = database.get_first_row("SELECT * FROM users WHERE approval_token = ?", [token])
      halt 404, "Solicitação não encontrada." unless user
      database.execute(
        "UPDATE users SET status = ?, approved_at = ?, approval_token = NULL WHERE id = ?",
        [status, status == "approved" ? now : nil, user["id"]]
      )
      log_event(database, "email_#{status}", user["id"], user["email"])
    end
    label = status == "approved" ? "aprovada" : "recusada"
    page("Solicitação revisada", :status, code: "OK", title: "Solicitação #{label}", message: "#{user['email']} foi #{label}.")
  end

  not_found do
    status 404
    page("Não encontrado", :status, code: "404", title: "Sinal não encontrado", message: "A página solicitada não existe.")
  end

  error do
    warn request.env["sinatra.error"]&.full_message
    status 500
    page("Erro", :status, code: "500", title: "Falha no painel", message: "Não foi possível concluir esta operação.")
  end

  def self.init_database!
    configured = ENV.fetch("PANEL_DB_PATH", "data/access_panel.db")
    path = File.absolute_path(configured, ROOT)
    GTSStore.initialize!(path: path, csv_path: File.join(ROOT, "data", "gts_history.csv"))
  end
end

if $PROGRAM_NAME == __FILE__
  PixelmonGTSPanel.init_database!
  PixelmonGTSPanel.run!
end
