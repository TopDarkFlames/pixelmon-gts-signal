# frozen_string_literal: true

require "tmpdir"
require "rack/mock"

def assert_response(response, path, expected = 200)
  return if response.status == expected

  raise "#{path}: HTTP #{response.status}, esperado #{expected}\n#{response.body[0, 500]}"
end

Dir.mktmpdir do |directory|
  ENV["PANEL_DB_PATH"] = File.join(directory, "panel.db")
  require_relative "../panel"
  PixelmonGTSPanel.init_database!

  database = GTSStore.connect(ENV.fetch("PANEL_DB_PATH"))
  database.execute(
    "INSERT INTO users(id,email,name,password_hash,role,status,created_at,notifications_enabled) VALUES (1,'test@example.com','Teste','x','admin','approved',?,1)",
    [Time.now.to_i]
  )
  database.execute(
    "INSERT INTO sessions(id,user_id,csrf_token,created_at,expires_at) VALUES ('test-session',1,'test-csrf',?,?)",
    [Time.now.to_i, Time.now.to_i + 3600]
  )
  listing_id = GTSStore.insert_listing(database, {
    "fingerprint" => "panel-test", "detected_at" => Time.now.utc.iso8601, "status" => "sent",
    "item" => "Marshadow", "seller" => "ARKIO", "amount" => "4000000.00",
    "currency" => "PokéCoins", "price_type" => "money", "price" => "$ 4,000,000.00 PokéCoins",
    "raw_chat" => "[GTS Global] test"
  })
  database.close

  request = Rack::MockRequest.new(PixelmonGTSPanel)
  headers = { "HTTP_COOKIE" => "gts_panel_session=test-session" }
  assert_response(request.get("/health"), "/health")
  assert_response(request.get("/dashboard", headers), "/dashboard")
  assert_response(request.get("/feed?type=money&period=24h", headers), "/feed")
  assert_response(request.get("/listing/#{listing_id}", headers), "/listing/:id")
  assert_response(request.get("/alerts", headers), "/alerts")
  assert_response(request.get("/settings", headers), "/settings")
  assert_response(request.get("/admin", headers), "/admin")

  form_headers = headers.merge("CONTENT_TYPE" => "application/x-www-form-urlencoded")
  response = request.post(
    "/alerts",
    form_headers.merge(input: "csrf=test-csrf&query=Marshadow&price_type=money&max_amount=5000000")
  )
  assert_response(response, "POST /alerts", 303)
end

puts "Painel Rack: OK"
