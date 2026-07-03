# frozen_string_literal: true

require "tmpdir"
require "rack/mock"

def assert_response(response, path, expected = 200)
  return if response.status == expected

  raise "#{path}: HTTP #{response.status}, esperado #{expected}\n#{response.body[0, 500]}"
end

Dir.mktmpdir do |directory|
  ENV["PANEL_DB_PATH"] = File.join(directory, "panel.db")
  ENV["DISCORD_USER_ID"] = "123456789012345678"
  ENV["TELEGRAM_CHAT_ID"] = "123456789"
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
  [10_000_000, 11_000_000, 12_000_000].each_with_index do |price, index|
    GTSStore.insert_listing(database, {
      "fingerprint" => "panel-history-#{index}", "detected_at" => (Time.now.utc - ((index + 1) * 60)).iso8601,
      "status" => "sent", "item" => "Marshadow", "seller" => "SELLER#{index}", "amount" => price.to_s,
      "currency" => "PokéCoins", "price_type" => "money", "price" => "$ #{price} PokéCoins",
      "raw_chat" => "[GTS Global] history test #{index}"
    })
  end
  latest_id = GTSStore.insert_listing(database, {
    "fingerprint" => "panel-test-token", "detected_at" => (Time.now.utc + 1).iso8601, "status" => "sent",
    "item" => "Chave Shiny", "seller" => "MURILO", "amount" => "4.00",
    "currency" => "Tokens", "price_type" => "token", "price" => "Token 4.00 Tokens",
    "raw_chat" => "[GTS Global] token test"
  })
  invalid_id = GTSStore.insert_listing(database, {
    "fingerprint" => "panel-invalid", "detected_at" => Time.now.utc.iso8601, "status" => "invalid",
    "reason" => "not_global_gts", "item" => "Haunter", "seller" => "LOCAL", "amount" => "1.00",
    "currency" => "PokéCoins", "price_type" => "money", "price" => "$ 1.00", "raw_chat" => "local GTS"
  })
  database.close

  request = Rack::MockRequest.new(PixelmonGTSPanel)
  headers = { "HTTP_COOKIE" => "gts_panel_session=test-session" }
  assert_response(request.get("/health"), "/health")
  assert_response(request.get("/dashboard", headers), "/dashboard")
  filtered_feed = request.get("/feed?type=money&period=24h", headers)
  assert_response(filtered_feed, "/feed")
  raise "cursor LIVE não usa o último ID global" unless filtered_feed.body.include?("data-latest-id=\"#{latest_id}\"")
  version_response = request.get("/feed/version", headers)
  assert_response(version_response, "/feed/version")
  raise "/feed/version retornou ID inválido" unless JSON.parse(version_response.body).fetch("id").to_i == latest_id
  assert_response(request.get("/listing/#{listing_id}", headers), "/listing/:id")
  assert_response(request.get("/seller/ARKIO", headers), "/seller/:name")
  opportunities = request.get("/opportunities", headers)
  assert_response(opportunities, "/opportunities")
  raise "central não destacou a oportunidade esperada" unless opportunities.body.include?("Marshadow") && opportunities.body.include?("62%")
  assert_response(request.get("/alerts", headers), "/alerts")
  assert_response(request.get("/settings", headers), "/settings")
  assert_response(request.get("/admin", headers), "/admin")
  assert_response(request.get("/admin/invalid", headers), "/admin/invalid")
  assert_response(request.get("/manifest.webmanifest"), "/manifest.webmanifest")

  form_headers = headers.merge("CONTENT_TYPE" => "application/x-www-form-urlencoded")
  favorite_response = request.post(
    "/favorites",
    form_headers.merge(input: "csrf=test-csrf&kind=item&value=Marshadow&return_to=%2Ffavorites")
  )
  assert_response(favorite_response, "POST /favorites", 303)
  favorites = request.get("/favorites", headers)
  assert_response(favorites, "/favorites")
  raise "favorito não foi exibido" unless favorites.body.include?("Marshadow")
  notification_response = request.get("/notifications/check?after=0", headers)
  assert_response(notification_response, "/notifications/check")
  notification_data = JSON.parse(notification_response.body)
  raise "notificação de favorito ausente" unless notification_data.fetch("matches").any? { |match| match["item"] == "Marshadow" }

  response = request.post(
    "/alerts",
    form_headers.merge(input: "csrf=test-csrf&query=Marshadow&price_type=money&max_amount=5000000")
  )
  assert_response(response, "POST /alerts", 303)

  integration_response = request.post(
    "/admin/test-notification",
    form_headers.merge(input: "csrf=test-csrf&channel=discord")
  )
  assert_response(integration_response, "POST /admin/test-notification", 303)
  database = GTSStore.connect(ENV.fetch("PANEL_DB_PATH"))
  raise "teste de integração não entrou na fila" unless database.get_first_value("SELECT COUNT(*) FROM notification_queue WHERE status='pending'").to_i == 1
  database.close

  restore_response = request.post(
    "/admin/invalid/#{invalid_id}",
    form_headers.merge(input: "csrf=test-csrf&action=restore&return_to=%2Fadmin%2Finvalid")
  )
  assert_response(restore_response, "POST /admin/invalid/:id", 303)
end

puts "Painel Rack: OK"
