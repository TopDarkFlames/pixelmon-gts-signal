# Pixelmon GTS Signal

> [!IMPORTANT]
> Projeto em desenvolvimento ativo. A arquitetura e o roadmap evoluem a partir do uso real em um servidor Pixelmon.

[Roadmap](ROADMAP.md) · [Changelog](CHANGELOG.md)

Sistema local que acompanha o `latest.log` do Pixelmon, detecta anúncios do GTS Global e distribui as informações para:

- DM privada no Discord;
- Telegram;
- painel web com histórico;
- mensagem oficial no canal do Discord com o endereço atual do painel, pronta para ser fixada.

## Componentes ativos

| Componente | Tecnologia | Arquivo |
| --- | --- | --- |
| Captura e notificações | Python | `gts_dm_bot.py` |
| Painel web | Ruby, Sinatra e ERB | `panel.rb`, `views/` |
| Atualização do feed | HTMX e verificação incremental | `public/dashboard.js`, `public/htmx.min.js` |
| Estilo | CSS | `public/styles.css` |
| Usuários, histórico e fila | SQLite WAL | `access_panel.db` |
| Hospedagem automática | Tailscale/Cloudflare | `iniciar_permanente.sh` |
| Inicialização no boot | systemd | `systemd/pixelmon-gts.service` |

## Configuração

Requisitos:

- Python 3.10+;
- Ruby 3.4+ e Bundler;
- Linux com `systemd` para o modo automático;
- `cloudflared` e, opcionalmente, Tailscale.

Preparação inicial:

```bash
bundle install
cp .env.example .env
```

As credenciais e caminhos ficam no arquivo `.env`. Use `.env.example` como referência.

Variáveis obrigatórias:

```env
DISCORD_BOT_TOKEN=token_do_bot
DISCORD_USER_ID=id_da_dm
DISCORD_GUILD_ID=id_do_servidor
DISCORD_ANNOUNCE_CHANNEL_ID=id_do_canal
MINECRAFT_LOG_PATH=/caminho/para/minecraft/logs/latest.log

TELEGRAM_ENABLED=true
TELEGRAM_BOT_TOKEN=token_do_botfather
TELEGRAM_CHAT_ID=id_da_conversa

PANEL_HOST=127.0.0.1
PANEL_PORT=8080
PANEL_DB_PATH=access_panel.db
```

Nunca publique o arquivo `.env`.

## Serviço automático

Instalação inicial:

```bash
./instalar_servico_permanente.sh
```

Depois de instalado, painel, bot e túnel iniciam automaticamente com o computador e reiniciam sozinhos em caso de falha.

Não execute outro launcher manual ao mesmo tempo: o serviço automático já usa a porta 8080.

Consultar serviço, URL e logs:

```bash
./status_permanente.sh
```

Comandos de manutenção:

```bash
systemctl --user restart pixelmon-gts.service
systemctl --user stop pixelmon-gts.service
systemctl --user start pixelmon-gts.service
journalctl --user -u pixelmon-gts.service -f
```

## URL pública

O serviço tenta primeiro o Tailscale Funnel, que oferece endereço fixo `*.ts.net`. Se o administrador da tailnet não tiver habilitado Funnel, o sistema usa Cloudflare Quick Tunnel.

No modo Cloudflare, a URL pode mudar após uma reinicialização. O bot atualiza sempre a mesma mensagem no canal do Discord; depois de fixada uma vez, ela permanece fixa enquanto o endereço dentro dela é atualizado.

O permalink dessa mensagem é um endereço fixo e fica salvo em `runtime/permanent_access_url.txt`.

A URL ativa também fica em:

```text
runtime/site_url.txt
```

## Formato detectado

O parser identifica mensagens que contêm `to the global GTS for`, por exemplo:

```text
[GTS Global] grey_xzfx added a Chave de Shiny Aleatório to the global GTS for Token 4.00 Tokens!
```

Tipos reconhecidos:

- PokéCoins;
- Tokens;
- Saldo no Site.

O marcador completo é obrigatório. Mensagens do GTS local ou linhas que apenas mencionem “GTS” são descartadas antes da extração.

Testar uma linha sem enviar notificações:

```bash
python3 gts_dm_bot.py --test-line 'linha completa da log'
```

Testar integrações:

```bash
python3 gts_dm_bot.py --test-discord --test-type token
python3 gts_dm_bot.py --test-telegram --test-type token
```

## Discord

O bot usa `DISCORD_ANNOUNCE_CHANNEL_ID` para criar ou atualizar uma única mensagem oficial com o link do painel. Para fixá-la, o bot precisa destas permissões no canal:

- Ver canal;
- Enviar mensagens;
- Ler histórico de mensagens;
- Gerenciar mensagens.

Os anúncios do GTS continuam sendo enviados para a DM configurada em `DISCORD_USER_ID`.

## Painel

Rotas principais:

- `/login`: autenticação;
- `/register`: solicitação de conta;
- `/dashboard`: histórico ao vivo;
- `/opportunities`: anúncios abaixo da mediana com histórico suficiente;
- `/alerts`: monitores personalizados e resultados;
- `/settings`: IDs privados do Discord e Telegram;
- `/listing/:id`: detalhes e histórico de preço;
- `/admin`: usuários, convites e aprovações;
- `/forgot-password`: recuperação de senha;
- `/health`: verificação do serviço.

O painel oferece tema claro/escuro, atualização automática por versão, filtros por período e preço, detector de oportunidades, alertas por usuário, telemetria das integrações e recuperação de senha.

A Central de Oportunidades usa até 30 dias de histórico, exige pelo menos três amostras comparáveis e remove valores extremos pelo intervalo interquartil quando existem oito ou mais registros. Cada sinal exibe quantidade de amostras e confiança baixa, média ou alta.

Os anúncios e trabalhos de entrega ficam no SQLite. Falhas de Discord ou Telegram são tentadas novamente até cinco vezes e sobrevivem a reinicializações. O antigo `gts_history.csv` é importado de forma incremental por fingerprint, sem duplicar anúncios já migrados.

## Testes

```bash
./testar.sh
```

Os testes cobrem o parser, moedas, deduplicação, alertas, fila persistente, migração e renderização das rotas Sinatra.

## Arquivos importantes

Não apague:

- `.env`;
- `access_panel.db`;
- `gts_history.csv` enquanto a migração não tiver sido confirmada;
- `vendor/`;
- `public/htmx.min.js`;
- arquivos dentro de `views/` e `systemd/`.
