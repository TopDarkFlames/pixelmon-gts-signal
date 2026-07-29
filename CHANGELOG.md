# Changelog

Todas as mudanças relevantes deste projeto serão registradas aqui.

## [0.4.0] - 2026-07-29

### Adicionado

- Radar de texturas em `/textures`, agrupando item, TXT e moeda.
- Alertas avançados por modo de busca, textura, IV mínimo e HA.
- Pacote rápido de alertas para qualquer TXT de Zacian, Kyogre, Rayquaza, Zamazenta e Eternatus.
- Tabela `item_stats` para histórico resumido e páginas mais leves com meses de dados.
- Memória de mercado no detalhe do anúncio, com aparições, mediana e faixa histórica.
- Diagnóstico administrativo separado para `gts_bridge`, `discord_gateway`, Discord, Telegram e túnel.
- Ações administrativas para reconstruir estatísticas e otimizar o SQLite.

### Melhorado

- Coletor Python e painel Ruby agora compartilham a mesma lógica de alerta avançado.
- Migrações ficaram seguras para bancos antigos que ainda não tinham colunas de alerta.
- README ganhou badges, arquitetura, destaque das features atuais e links de release/perfil.
- Testes passaram a cobrir radar de TXT, alertas avançados e estatísticas resumidas.

## [0.3.0] - 2026-07-03

### Adicionado

- Favoritos de itens e vendedores com página pessoal.
- Perfil de vendedor com atividade em 24h, 7d e 30d.
- Comparação temporal de mediana, volume e tendência semanal.
- Notificações do navegador para favoritos e alertas.
- Manifesto PWA e service worker para interação com notificações.
- Revisão administrativa dos registros isolados.
- Testes reais de Discord e Telegram pela fila persistente.
- Latência média de entrega e estado do SMTP no painel administrativo.
- Backup automático do SQLite com retenção configurável.
- Workflow de testes no GitHub Actions.

## [0.2.1] - 2026-07-03

### Corrigido

- Parser agora exige o marcador completo do GTS Global e ignora anúncios locais.
- Cursor LIVE acompanha o último ID global mesmo quando a tabela está filtrada.
- Registros históricos falsos são isolados automaticamente.

### Adicionado

- Central de Oportunidades ordenada pelo desconto estimado.
- Mediana robusta com remoção de extremos pelo intervalo interquartil.
- Quantidade de amostras e nível de confiança em cada análise de preço.

## [0.2.0] - 2026-07-03

### Adicionado

- SQLite compartilhado para usuários, anúncios, alertas e entregas.
- Migração automática do histórico CSV.
- Fila persistente com retry exponencial para Discord e Telegram.
- Alertas personalizados e destinos por usuário.
- Feed com atualização automática, paginação e filtros de período, preço e ordenação.
- Histórico de preços e detector de ofertas abaixo da mediana.
- Painel operacional com saúde das integrações e auditoria.
- Recuperação de senha e gerenciamento completo de usuários.
- Testes automatizados de Python, Ruby e rotas Sinatra.

### Segurança

- Limite de tentativas de login por email e IP.
- Tokens de aprovação descartados após o uso.
- Revogação de sessões quando acesso ou senha muda.
- Cabeçalhos CSP, HSTS e Permissions Policy.

## [0.1.0] - 2026-07-03

### Adicionado

- Captura ao vivo de anúncios do GTS Global pela log do Prism Launcher.
- Notificações privadas no Discord e Telegram.
- Painel web em Ruby, Sinatra, ERB e HTMX.
- Contas com aprovação, convites e área administrativa.
- Histórico pesquisável com classificação por moeda.
- Tema claro e escuro persistente.
- Serviço automático no Linux com `systemd`.
- Hospedagem com Tailscale Funnel e fallback Cloudflare.
- Mensagem oficial do site atualizada automaticamente no Discord.

### Segurança

- Credenciais isoladas no `.env`.
- Banco de usuários, histórico e logs excluídos do Git.
- Senhas armazenadas com PBKDF2-SHA256.
- Cookies HTTP-only e proteção CSRF nas ações administrativas.
