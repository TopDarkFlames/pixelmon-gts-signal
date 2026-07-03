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
require "csv"
require "json"
require "net/smtp"
require "openssl"
require "pathname"
require "securerandom"
require "sinatra/base"
require "sqlite3"
require "time"

class PixelmonGTSPanel < Sinatra::Base
  ROOT = File.expand_path(__dir__)
  ENV_PATH = File.join(ROOT, ".env")
  CONFIG_PATH = File.join(ROOT, "config.json")
  COOKIE_NAME = "gts_panel_session"
  PBKDF2_ITERATIONS = 260_000
  SESSION_TTL = 60 * 60 * 24 * 14

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
      database = SQLite3::Database.new(config_env("PANEL_DB_PATH", File.join(ROOT, "access_panel.db")))
      database.results_as_hash = true
      database.busy_timeout = 5_000
      database
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

    def history_path
      config = File.exist?(CONFIG_PATH) ? JSON.parse(File.read(CONFIG_PATH, encoding: "UTF-8")) : {}
      raw_path = config.dig("history", "path").to_s
      raw_path = "gts_history.csv" if raw_path.empty?
      Pathname.new(raw_path).absolute? ? raw_path : File.join(ROOT, raw_path)
    rescue JSON::ParserError
      File.join(ROOT, "gts_history.csv")
    end

    def recent_history(limit = 50)
      path = history_path
      return [] unless File.exist?(path)

      rows = CSV.read(path, headers: true, encoding: "UTF-8").map(&:to_h)
      rows.last(limit).reverse
    rescue CSV::MalformedCSVError, Errno::ENOENT
      []
    end

    def filtered_history(rows)
      type = params.fetch("type", "all")
      query = params.fetch("q", "").strip.downcase
      rows.select do |row|
        matches_type = type == "all" || row["price_type"] == type
        searchable = "#{row['item']} #{row['seller']}".downcase
        matches_type && (query.empty? || searchable.include?(query))
      end
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

      recipients = approval_recipients
      smtp_host = config_env("SMTP_HOST")
      smtp_user = config_env("SMTP_USER")
      smtp_password = config_env("SMTP_PASSWORD")
      from = config_env("SMTP_FROM", smtp_user)
      if recipients.empty? || smtp_host.empty? || smtp_user.empty? || smtp_password.empty? || from.empty?
        warn "\n=== APROVAÇÃO PENDENTE ===\n#{body}=== FIM ===\n"
        return
      end

      message = <<~MAIL
        From: #{from}
        To: #{recipients.join(', ')}
        Subject: Nova solicitacao de acesso ao Pixelmon GTS
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8

        #{body}
      MAIL
      smtp = Net::SMTP.new(smtp_host, Integer(config_env("SMTP_PORT", "587")))
      smtp.enable_starttls if env_bool("SMTP_TLS", true)
      smtp.start(smtp_host, smtp_user, smtp_password, :login) { |connection| connection.send_message(message, from, recipients) }
    rescue StandardError => e
      warn "Falha ao enviar email de aprovação: #{e.message}"
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
      "Content-Security-Policy" => "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'"
    )
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
      user = database.get_first_row("SELECT * FROM users WHERE email = ?", [email])
      unless user && valid_password?(password, user["password_hash"])
        halt page("Entrar", :login, message: "Email ou senha inválidos.")
      end
      halt page("Entrar", :login, message: "Conta ainda não aprovada.") unless user["status"] == "approved"

      session_id, = create_session(database, user["id"])
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
      with_db { |database| database.execute("DELETE FROM sessions WHERE id = ?", [@current_user["session_id"]]) }
    end
    clear_session_cookie
    redirect "/login"
  end

  post "/theme" do
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
    @all_rows = recent_history
    @rows = filtered_history(@all_rows)
    @filter = params.fetch("type", "all")
    @query = params.fetch("q", "")
    page("Dashboard", :dashboard)
  end

  get "/feed" do
    approved!
    @all_rows = recent_history
    @rows = filtered_history(@all_rows)
    @oob = true
    erb :feed, layout: false
  end

  get "/admin" do
    admin!
    with_db do |database|
      @pending = database.execute("SELECT * FROM users WHERE status = 'pending' ORDER BY created_at DESC")
      @users = database.execute("SELECT * FROM users ORDER BY created_at DESC LIMIT 100")
      @invites = database.execute("SELECT * FROM invite_codes ORDER BY created_at DESC LIMIT 50")
    end
    page("Admin", :admin)
  end

  post "/admin/user" do
    admin!
    csrf!
    status = { "approve" => "approved", "deny" => "denied" }[params["action"]]
    halt 400, "Ação inválida." unless status
    with_db do |database|
      database.execute(
        "UPDATE users SET status = ?, approved_at = ? WHERE id = ? AND role != 'admin'",
        [status, status == "approved" ? now : nil, params["user_id"].to_i]
      )
      log_event(database, "user_#{status}", params["user_id"].to_i)
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
        "UPDATE users SET status = ?, approved_at = ? WHERE id = ?",
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
    database = SQLite3::Database.new(ENV.fetch("PANEL_DB_PATH", File.join(ROOT, "access_panel.db")))
    database.execute_batch(<<~SQL)
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
        password_hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'user', status TEXT NOT NULL DEFAULT 'pending',
        invite_code TEXT, approval_token TEXT UNIQUE, created_at INTEGER NOT NULL, approved_at INTEGER, last_login_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, csrf_token TEXT NOT NULL,
        created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, FOREIGN KEY(user_id) REFERENCES users(id)
      );
      CREATE TABLE IF NOT EXISTS invite_codes (
        id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL UNIQUE, note TEXT,
        max_uses INTEGER NOT NULL DEFAULT 1, used_count INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL, expires_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, user_id INTEGER, details TEXT, created_at INTEGER NOT NULL
      );
    SQL
  ensure
    database&.close
  end
end

if $PROGRAM_NAME == __FILE__
  PixelmonGTSPanel.init_database!
  PixelmonGTSPanel.run!
end
