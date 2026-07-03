# Changelog

Todas as mudanças relevantes deste projeto serão registradas aqui.

## [0.2.0] - 2026-07-03

### Adicionado

- SQLite compartilhado para usuários, anúncios, alertas e entregas.
- Migração automática do histórico CSV.
- Fila persistente com retry exponencial para Discord e Telegram.
- Alertas personalizados e destinos por usuário.
- Feed SSE, paginação e filtros de período, preço e ordenação.
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
