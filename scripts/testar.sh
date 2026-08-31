#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUBY_ABI="$(ruby -e 'print RbConfig::CONFIG.fetch("ruby_version")')"
GEM_ROOT="$ROOT_DIR/vendor/bundle/ruby/$RUBY_ABI"
export GEM_HOME="$GEM_ROOT"
export GEM_PATH="$GEM_ROOT:/usr/lib/ruby/gems/$RUBY_ABI"

bash -n scripts/abrir_launcher.sh scripts/executar_painel.sh scripts/iniciar_permanente.sh scripts/instalar_servico_permanente.sh scripts/status_permanente.sh scripts/testar.sh
python3 -m unittest discover -s test -p 'test_*.py' -v
ruby test/test_store.rb
ruby test/test_panel.rb
ruby -rjson -e 'JSON.parse(File.read("config/config.json")); JSON.parse(File.read("public/manifest.webmanifest")); puts "JSON: OK"'
ruby -ryaml -e 'YAML.load_file(".github/workflows/test.yml"); puts "Workflow YAML: OK"'
ruby -rerb -e 'Dir["views/*.erb"].sort.each { |file| source = ERB.new(File.read(file)).src; RubyVM::InstructionSequence.compile("def __render__; #{source}; end", file) }; puts "ERB: OK"'
command -v node >/dev/null && node --check public/dashboard.js

echo "Todos os testes passaram."
