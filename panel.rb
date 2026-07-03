#!/usr/bin/env ruby
# frozen_string_literal: true

require "rubygems"

vendor_gems = File.join(__dir__, "vendor", "bundle", "ruby", RbConfig::CONFIG.fetch("ruby_version"))
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
require "sinatra/base"
require "sqlite3"
require "time"
require_relative "lib/gts_store"

class PixelmonGTSPanel < Sinatra::Base
  ROOT = File.expand_path(__dir__)
  ENV_PATH = File.join(ROOT, ".env")
  CONFIG_PATH = File.join(ROOT, "config.json")
  COOKIE_NAME = "gts_panel_session"
  PBKDF2_ITERATIONS = 260_000
  SESSION_TTL = 60 * 60 * 24 * 14
  LOGIN_WINDOW = 15 * 60
  LOGIN_MAX_FAILURES = 5
  RESET_TTL = 60 * 60
  FEED_PAGE_SIZE = 40

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
      configured = config_env("PANEL_DB_PATH", "access_panel.db")
      File.absolute_path(configured, ROOT)
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
      request.cookies["gts_panel_theme"] == "dark" ? "dark" : "light"
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

    def listing_rows(database, limit: FEED_PAGE_SIZE)
      clauses = ["status = 'sent'"]
      values = []
      unless feed_filter == "all"
        clauses << "price_type = ?"
        values << feed_filter
      end
      unless feed_query.empty?
        clauses << "(item_key LIKE ? OR lower(seller) LIKE ?)"
        search = "%#{GTSStore.fold(feed_query)}%"
        values.concat([search, search])
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

    def enrich_opportunities(database, rows)
      history = database.execute(<<~SQL, [now - (30 * 86_400)])
        SELECT item_key, price_type, amount_value FROM listings
        WHERE status = 'sent' AND amount_value IS NOT NULL AND detected_at_epoch >= ?
        ORDER BY detected_at_epoch DESC LIMIT 4000
      SQL
      medians = history.group_by { |row| [row["item_key"], row["price_type"]] }.to_h do |key, values|
        prices = values.map { |row| row["amount_value"].to_f }.sort
        midpoint = prices.length / 2
        median = prices.length.odd? ? prices[midpoint] : (prices[midpoint - 1] + prices[midpoint]) / 2.0
        [key, median]
      end
      rows.map do |row|
        median = medians[[row["item_key"], row["price_type"]]]
        discount = if median&.positive? && row["amount_value"]
                     ((median - row["amount_value"].to_f) / median * 100).round
                   end
        row.merge("market_median" => median, "discount_percent" => discount, "deal" => discount && discount >= 15)
      end
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
      statuses["panel"] = { "name" => "panel", "status" => "online", "detail" => "Ruby/Puma", "updated_at" => now }
      if File.file?(site_url_path)
        statuses["tunnel"] = { "name" => "tunnel", "status" => "online", "detail" => File.read(site_url_path).strip, "updated_at" => File.mtime(site_url_path).to_i }
      end
      statuses
    end

    def format_number(value)
      return "—" if value.nil?

      whole, decimal = format("%.2f", value.to_f).split(".", 2)
      "#{whole.reverse.scan(/.{1,3}/).join('.').reverse},#{decimal}"
    end

    def price_type(row)
      type = row["price_type"].to_s
      %w[money token site].include?(type) ? type : "unknown"
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
      @stats = dashboard_stats(database)
      @health = system_health(database)
      @recent_matches = database.execute(<<~SQL, [@current_user["id"]])
        SELECT alert_matches.*, listings.item, listings.price, listings.price_type
        FROM alert_matches JOIN listings ON listings.id = alert_matches.listing_id
        WHERE alert_matches.user_id = ? ORDER BY alert_matches.created_at DESC LIMIT 5
      SQL
    end
    @filter = feed_filter
    @query = feed_query
    @page = feed_page
    page("Dashboard", :dashboard)
  end

  get "/feed" do
    approved!
    with_db do |database|
      @rows, @total_rows = listing_rows(database)
      @stats = dashboard_stats(database)
    end
    @filter = feed_filter
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

  get "/listing/:id" do
    approved!
    with_db do |database|
      @listing = database.get_first_row("SELECT * FROM listings WHERE id = ? AND status='sent'", [params["id"].to_i])
      halt 404, page("Não encontrado", :status, code: "404", title: "Anúncio não encontrado", message: "Este registro não existe mais.") unless @listing
      @price_history = database.execute(<<~SQL, [@listing["item_key"], @listing["price_type"]])
        SELECT * FROM listings WHERE item_key = ? AND price_type = ? AND status='sent' AND amount_value IS NOT NULL
        ORDER BY detected_at_epoch DESC LIMIT 60
      SQL
      prices = @price_history.map { |row| row["amount_value"].to_f }.sort
      midpoint = prices.length / 2
      @price_stats = {
        min: prices.min,
        max: prices.max,
        median: prices.empty? ? nil : (prices.length.odd? ? prices[midpoint] : (prices[midpoint - 1] + prices[midpoint]) / 2.0)
      }
    end
    page("Detalhes", :listing)
  end

  get "/alerts" do
    approved!
    with_db do |database|
      @alerts = database.execute("SELECT * FROM alerts WHERE user_id = ? ORDER BY created_at DESC", [@current_user["id"]])
      @matches = database.execute(<<~SQL, [@current_user["id"]])
        SELECT alert_matches.*, alerts.query, listings.item, listings.seller, listings.price, listings.price_type
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
    channels = ["site"]
    channels << "discord" if params["discord"] == "1"
    channels << "telegram" if params["telegram"] == "1"
    minimum = params["min_amount"].to_s.strip
    maximum = params["max_amount"].to_s.strip
    with_db do |database|
      database.execute(
        "INSERT INTO alerts(user_id, query, price_type, min_amount, max_amount, channels, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [@current_user["id"], query, price_type, minimum.empty? ? nil : Float(minimum), maximum.empty? ? nil : Float(maximum), channels.join(","), now]
      )
      log_event(database, "alert_created", @current_user["id"], query)
    end
    redirect "/alerts"
  rescue ArgumentError
    halt 422, page("Alertas", :status, code: "422", title: "Preço inválido", message: "Use apenas números nos limites de preço.")
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
    end
    page("Admin", :admin)
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
    configured = ENV.fetch("PANEL_DB_PATH", "access_panel.db")
    path = File.absolute_path(configured, ROOT)
    GTSStore.initialize!(path: path, csv_path: File.join(ROOT, "gts_history.csv"))
  end
end

if $PROGRAM_NAME == __FILE__
  PixelmonGTSPanel.init_database!
  PixelmonGTSPanel.run!
end
