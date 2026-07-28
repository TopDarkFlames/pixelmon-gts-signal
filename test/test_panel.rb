# frozen_string_literal: true

require "tmpdir"
require "rack/mock"

def assert_response(response, path, expected = 200)
  return if response.status == expected

  raise "#{path}: HTTP #{response.status}, esperado #{expected}\n#{response.body[0, 500]}"
end

Dir.mktmpdir do |directory|
  ENV["RACK_ENV"] = "test"
  ENV["PANEL_DB_PATH"] = File.join(directory, "panel.db")
  ENV["DISCORD_USER_ID"] = "123456789012345678"
  ENV["TELEGRAM_CHAT_ID"] = "123456789"
  ENV["GTS_ASSETS_ENABLED"] = "false"
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
    "raw_chat" => "[GTS Global] test", "source" => "bridge", "is_pokemon" => 1,
    "ability" => "Technician", "hidden_ability" => 1, "nature" => "Jolly", "texture" => "Hero",
    "iv_total" => 140, "iv_max" => 186, "iv_percent" => 75.27, "iv_hp" => 14,
    "iv_attack" => 27, "iv_defense" => 6, "iv_sp_attack" => 31, "iv_sp_defense" => 31,
    "iv_speed" => 31, "moves_json" => JSON.generate(["Spectral Thief", "Drain Punch"])
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
  dashboard_response = request.get("/dashboard", headers)
  assert_response(dashboard_response, "/dashboard")
  raise "tema escuro não é o padrão" unless dashboard_response.body.include?('data-theme="dark"')
  raise "color-scheme inicial não acompanha o tema" unless dashboard_response.body.include?('name="color-scheme" content="dark"')
  light_response = request.get("/dashboard", "HTTP_COOKIE" => "gts_panel_session=test-session; gts_panel_theme=light")
  assert_response(light_response, "/dashboard tema claro")
  raise "opção de tema claro não foi preservada" unless light_response.body.include?('data-theme="light"')
  raise "menu não exibe histórico" unless dashboard_response.body.include?('href="/history"')
  raise "menu não exibe texturas" unless dashboard_response.body.include?('href="/textures"')
  filtered_feed = request.get("/feed?type=money&period=24h", headers)
  assert_response(filtered_feed, "/feed")
  raise "cursor LIVE não usa o último ID global" unless filtered_feed.body.include?("data-latest-id=\"#{latest_id}\"")
  version_response = request.get("/feed/version", headers)
  assert_response(version_response, "/feed/version")
  raise "/feed/version retornou ID inválido" unless JSON.parse(version_response.body).fetch("id").to_i == latest_id
  listing_response = request.get("/listing/#{listing_id}", headers)
  assert_response(listing_response, "/listing/:id")
  raise "perfil Pixelmon não foi exibido" unless listing_response.body.include?("Perfil do Pokémon")
  raise "textura não foi exibida" unless listing_response.body.include?("Hero")
  raise "IVs não foram exibidos" unless listing_response.body.include?("75.27%")
  raise "selo HA não foi exibido" unless listing_response.body.include?('class="ha-tag">HA')
  raise "golpes não foram exibidos" unless listing_response.body.include?("Spectral Thief")
  raise "seção de modelo 3D ainda está no detalhe" if listing_response.body.include?("RESOURCE PACK / MODELO 3D")
  texture_feed = request.get("/feed?texture=custom", headers)
  assert_response(texture_feed, "/feed?texture=custom")
  raise "filtro de textura customizada não encontrou o Pokémon" unless texture_feed.body.include?("Marshadow")
  history_response = request.get("/history?q=Marshadow&texture=custom", headers)
  assert_response(history_response, "/history")
  raise "histórico não exibiu o Pokémon salvo" unless history_response.body.include?("Marshadow") && history_response.body.include?("Aparições registradas")
  textures_response = request.get("/textures?q=Marshadow", headers)
  assert_response(textures_response, "/textures")
  raise "radar de texturas não exibiu a TXT salva" unless textures_response.body.include?("Radar de Texturas") && textures_response.body.include?("Hero")
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
    form_headers.merge(input: "csrf=test-csrf&query=Marshadow&price_type=money&match_mode=item&texture_query=custom&min_iv_percent=70&hidden_ability_only=1&max_amount=5000000")
  )
  assert_response(response, "POST /alerts", 303)
  alerts_page = request.get("/alerts", headers)
  assert_response(alerts_page, "/alerts avançado")
  raise "alerta avançado não exibiu TXT/IV/HA" unless alerts_page.body.include?("qualquer TXT customizada") && alerts_page.body.include?("IV &gt;= 70%") && alerts_page.body.include?("HA")

  priority_response = request.post(
    "/alerts/priority-textures",
    form_headers.merge(input: "csrf=test-csrf&discord=1&telegram=1")
  )
  assert_response(priority_response, "POST /alerts/priority-textures", 303)
  database = GTSStore.connect(ENV.fetch("PANEL_DB_PATH"))
  priority_count = database.get_first_value("SELECT COUNT(*) FROM alerts WHERE texture_query='custom' AND query IN ('Zacian','Kyogre','Rayquaza','Zamazenta','Eternatus')").to_i
  database.close
  raise "pacote de alertas lendários não foi criado" unless priority_count == 5

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
