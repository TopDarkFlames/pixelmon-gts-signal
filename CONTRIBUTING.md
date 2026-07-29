# Contribuindo

Este projeto é desenvolvido a partir de uso real em servidor Pixelmon. Mudanças pequenas e bem testadas são preferidas.

## Setup local

```bash
bundle install
cp .env.example .env
```

Configure o `.env` localmente. Nunca envie tokens, banco SQLite ou logs privados para o Git.

## Validação obrigatória

Antes de abrir PR ou fazer push:

```bash
./testar.sh
git diff --check
```

## Áreas principais

- `gts_dm_bot.py`: parser, Discord, Telegram e fila.
- `panel.rb`: rotas Sinatra, autenticação e painel.
- `lib/gts_store.rb`: schema SQLite, migrações e estatísticas.
- `views/`: telas ERB.
- `public/styles.css`: visual do painel.
- `gts-bridge/`: mod Forge usado para capturar hover do chat.

## Regras práticas

- Preserve compatibilidade com bancos antigos.
- Não altere resource packs ou mods externos; o projeto só lê esses arquivos.
- Se adicionar campo no SQLite, atualize o migrador Ruby e o migrador Python.
- Se mudar parser ou alerta, cubra com teste.
- Se mudar tela pública, teste `/dashboard`, `/history`, `/textures`, `/alerts` e `/admin`.
