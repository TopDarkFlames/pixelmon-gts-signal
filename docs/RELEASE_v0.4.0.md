# Pixelmon GTS Signal v0.4.0

Data: 2026-07-29

Esta release transforma o painel em uma central mais completa para caça de texturas e alertas inteligentes do GTS Global.

## Destaques

- Novo radar de texturas em `/textures`.
- Alertas avançados por TXT, IV mínimo e HA.
- Pacote rápido de alertas para qualquer TXT de Zacian, Kyogre, Rayquaza, Zamazenta e Eternatus.
- Histórico resumido em `item_stats`, mantendo páginas rápidas mesmo com milhares de anúncios.
- Detalhe do anúncio com memória de mercado: aparições, mediana, menor e maior preço.
- Admin com serviços mais claros: painel, coletor, GTS Bridge, Discord Gateway, Discord, Telegram e túnel.

## Para atualizar

```bash
git pull
./testar.sh
systemctl --user restart pixelmon-gts.service
```

Na primeira inicialização depois do update, o banco cria as colunas novas e reconstrói a tabela `item_stats`.

## Verificação

```bash
./status_permanente.sh
```

Confira:

- `log_watcher` online;
- `gts_bridge` online;
- `discord_gateway` online;
- Discord/Telegram online;
- URL pública atualizada na mensagem fixada do Discord.

## Observações

Cloudflare Quick Tunnel continua podendo trocar a URL pública no modo free. A mensagem fixada no Discord é o link permanente operacional, porque o conteúdo dela é atualizado automaticamente a cada restart.
