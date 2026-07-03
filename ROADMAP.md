# Roadmap

O Pixelmon GTS Signal está em desenvolvimento ativo. O foco atual é transformar a automação pessoal em um serviço pequeno, confiável e fácil de operar.

## Entregue

- Leitura ao vivo do `latest.log` do Minecraft.
- Parser de PokéCoins, Tokens e Saldo no Site.
- Alertas assíncronos no Discord e Telegram.
- Mensagem oficial do painel atualizada no canal do Discord.
- Painel Ruby/ERB com autenticação, convites e aprovação.
- Dashboard HTMX responsivo com tema claro e escuro.
- Inicialização automática e recuperação por `systemd`.
- Tailscale Funnel com contingência automática via Cloudflare.

## Em andamento

- Migrar o histórico de CSV para SQLite.
- Criar uma fila persistente de notificações com tentativas automáticas.
- Melhorar a deduplicação de anúncios repetidos.
- Exibir a saúde das integrações no painel.

## Planejado

- Alertas personalizados por Pokémon, moeda e faixa de preço.
- Favoritos e filtros salvos por usuário.
- Gráficos de preço e volume de anúncios.
- Atualização em tempo real com SSE.
- Recuperação de senha e proteção contra tentativas excessivas de login.
- Testes automatizados do parser, autenticação e integrações.

As prioridades podem mudar conforme o formato do GTS e o uso real do painel evoluírem.
