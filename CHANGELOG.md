# Changelog

Todas as mudanças relevantes deste projeto serão registradas aqui.

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
