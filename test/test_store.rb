# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/gts_store"

def assert_equal(expected, actual, label)
  raise "#{label}: esperado #{expected.inspect}, recebido #{actual.inspect}" unless expected == actual
end

Dir.mktmpdir do |directory|
  database_path = File.join(directory, "panel.db")
  csv_path = File.join(directory, "history.csv")
  File.write(csv_path, <<~CSV)
    detected_at,status,reason,item,seller,amount,currency,price_type,price,raw_chat
    2026-07-03T12:00:00+00:00,sent,,Marshadow,ARKIO,"4,000,000.00",PokéCoins,money,"$ 4,000,000.00 PokéCoins",ARKIO added a Marshadow to the global GTS for price
  CSV

  GTSStore.initialize!(path: database_path, csv_path: csv_path)
  GTSStore.initialize!(path: database_path, csv_path: csv_path)

  database = GTSStore.connect(database_path)
  assert_equal(1, database.get_first_value("SELECT COUNT(*) FROM listings"), "importação única")
  raise "coluna discord_user_id ausente" unless database.table_info("users").map { |column| column["name"] }.include?("discord_user_id")
  raise "coluna texture ausente" unless database.table_info("listings").map { |column| column["name"] }.include?("texture")
  raise "coluna hidden_ability ausente" unless database.table_info("listings").map { |column| column["name"] }.include?("hidden_ability")
  raise "coluna texture_query ausente" unless database.table_info("alerts").map { |column| column["name"] }.include?("texture_query")
  raise "tabela item_stats não foi preenchida" unless database.get_first_value("SELECT COUNT(*) FROM item_stats").to_i == 1
  assert_equal("original", database.get_first_value("SELECT texture_key FROM item_stats"), "textura padrão no resumo")
  assert_equal(4_000_000.0, database.get_first_value("SELECT amount_value FROM listings"), "valor importado")
  assert_equal("sent", database.get_first_value("SELECT status FROM listings"), "anúncio global preservado")

  GTSStore.insert_listing(database, {
    "fingerprint" => "local-gts", "detected_at" => "2026-07-03T12:01:00+00:00", "status" => "sent",
    "item" => "Haunter", "raw_chat" => "player added a Haunter to the GTS for price"
  })
  GTSStore.quarantine_non_global_listings(database)
  assert_equal("invalid", database.get_first_value("SELECT status FROM listings WHERE fingerprint='local-gts'"), "GTS local isolado")

  GTSStore.insert_listing(database, {
    "fingerprint" => "bridge-logger", "detected_at" => "2026-07-03T12:02:00+00:00", "status" => "sent",
    "item" => "Marshadow", "raw_chat" => "[gtsbridge] [GTS Global] player added a Marshadow to the global GTS for price"
  })
  GTSStore.quarantine_non_global_listings(database)
  assert_equal("duplicate_bridge_logger", database.get_first_value("SELECT reason FROM listings WHERE fingerprint='bridge-logger'"), "eco do logger isolado")
ensure
  database&.close
end

assert_equal(1_234.56, GTSStore.parse_amount("1.234,56"), "formato brasileiro")
assert_equal(1_234.56, GTSStore.parse_amount("1,234.56"), "formato americano")
puts "Ruby store: OK"
