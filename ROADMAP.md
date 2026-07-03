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
- Histórico consolidado no SQLite em modo WAL.
- Fila persistente com retry para Discord e Telegram.
- Deduplicação entre reinicializações.
- Alertas por item, vendedor, moeda e faixa de preço.
- IDs de entrega configuráveis por usuário.
- Histórico e detector de oportunidade por mediana de preço.
- Feed em tempo real por verificação incremental de baixo custo.
- Indicadores de saúde e fila no painel administrativo.
- Recuperação de senha e limite de tentativas de login.
- Testes automatizados do parser, banco, fila e rotas Sinatra.

## Em andamento

- Ajustar o detector de oportunidade com dados reais de cada moeda.
- Melhorar a observabilidade do túnel público.
- Ampliar a cobertura de testes de email e falhas das APIs externas.

## Planejado

- Favoritos e filtros salvos por usuário.
- Relatórios semanais de preço e volume.
- Exportação de histórico por período.
- Notificações web via PWA.
- Autenticação opcional por passkey.

As prioridades podem mudar conforme o formato do GTS e o uso real do painel evoluírem.
