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
    2026-07-03T12:00:00+00:00,sent,,Marshadow,ARKIO,"4,000,000.00",PokéCoins,money,"$ 4,000,000.00 PokéCoins",GTS test
  CSV

  GTSStore.initialize!(path: database_path, csv_path: csv_path)
  GTSStore.initialize!(path: database_path, csv_path: csv_path)

  database = GTSStore.connect(database_path)
  assert_equal(1, database.get_first_value("SELECT COUNT(*) FROM listings"), "importação única")
  raise "coluna discord_user_id ausente" unless database.table_info("users").map { |column| column["name"] }.include?("discord_user_id")
  assert_equal(4_000_000.0, database.get_first_value("SELECT amount_value FROM listings"), "valor importado")
ensure
  database&.close
end

assert_equal(1_234.56, GTSStore.parse_amount("1.234,56"), "formato brasileiro")
assert_equal(1_234.56, GTSStore.parse_amount("1,234.56"), "formato americano")
puts "Ruby store: OK"
