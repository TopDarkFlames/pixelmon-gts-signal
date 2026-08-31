# Pixelmon GTS Signal v0.5.0

Data: 2026-08-10

Esta release adiciona o Mercador Viajante como um sinal próprio do painel, separado do mercado GTS.

## Destaques

- Nova aba `/merchant` com último spawn, histórico de locais e coordenadas copiáveis.
- Parser do GTS Global aceitando `added ... to the global GTS for` e `adicionou ... ao GTS Global por`.
- GTS Bridge atualizado para capturar hover/TXT nos dois formatos.
- Parser do chat para `O Mercador viajante chegou!`, com suporte a coordenadas na mesma linha ou na linha seguinte.
- Alertas do Mercador pelo Discord e Telegram usando a fila persistente existente.
- Alerta sonoro no site quando um novo spawn chega enquanto o painel está aberto.
- Tabela `merchant_spawns` no SQLite para manter o histórico de aparições.

## Para Atualizar

```bash
git pull
./testar.sh
systemctl --user restart pixelmon-gts.service
```

Na primeira inicialização depois do update, o banco cria a tabela `merchant_spawns` automaticamente.

## Verificação

```bash
python3 gts_dm_bot.py --test-merchant-line '[CHAT] O Mercador viajante chegou! Coordenadas: X: -123 Y: 64 Z: 987'
./status_permanente.sh
```

Confira:

- `/merchant` abre no painel;
- o serviço `log_watcher` está online;
- Discord/Telegram estão online;
- o botão `Ativar som` foi clicado pelo menos uma vez no navegador.

## Observações

O Mercador depende do servidor escrever as coordenadas no chat/log. Se o servidor mudar o texto exato do aviso, o parser pode precisar de um novo exemplo real da log.
