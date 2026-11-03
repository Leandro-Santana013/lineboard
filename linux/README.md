# Adaptador Linux do Lineboard

Este adaptador é o cliente Linux do plano cloud do Lineboard. Ele:

- autentica a instalação com a credencial já usada por `sic-sync`;
- baixa o snapshot inicial do Supabase;
- escuta mudanças de `sic_shared_carts` pelo Supabase Realtime;
- faz uma única reconciliação por evento ou reconexão, sem polling periódico;
- mantém um snapshot local com permissão `0600`;
- oferece uma API LAN somente de leitura para catálogo e carrinho.

Ele não é ainda um substituto do conector SICNET: venda fiscal, escrita no SQL
Server local, cadastro que exige o SIC e confirmação de venda continuam no desktop
Windows. O Linux pode ser usado como consumidor cloud/read-only e como ponte de
estado; não deve ser anunciado como caixa fiscal.

## Requisitos

- Linux com Node.js 22 ou mais recente;
- acesso HTTPS ao projeto Supabase;
- a credencial de integração `slb_live_...` da organização;
- a chave Realtime configurada para o projeto, se o modo orientado a eventos for usado.

## Configuração sem exibir credenciais

No shell do usuário que executará o serviço:

```bash
cd /opt/lineboard
read -r -s LINEBOARD_SYNC_TOKEN
export LINEBOARD_SYNC_TOKEN
read -r -s LINEBOARD_REALTIME_KEY
export LINEBOARD_REALTIME_KEY
node linux/lineboard-adapter.mjs configure \
  --sync-url 'https://<projeto>.supabase.co/functions/v1/sic-sync' \
  --realtime-url 'wss://<projeto>.supabase.co/realtime/v1/websocket'
unset LINEBOARD_SYNC_TOKEN LINEBOARD_REALTIME_KEY
```

O comando cria `~/.config/lineboard/adapter.json` com modo `0600`, gera um
`instance_id` próprio e não imprime os segredos. Para verificar sem revelar
credenciais:

```bash
node linux/lineboard-adapter.mjs status
node linux/lineboard-adapter.mjs sync-now
```

## Executar

Para manter o adaptador conectado ao Realtime:

```bash
node linux/lineboard-adapter.mjs run --host 0.0.0.0 --port 47832
```

O serviço expõe apenas:

- `GET /api/health` sem credencial;
- `GET /api/catalog` com `Authorization: Bearer <token cloud>`;
- `GET /api/cart` com `Authorization: Bearer <token cloud>`.

O endpoint LAN é deliberadamente read-only. O celular deve continuar usando o
modo cloud para adicionar/remover itens do carrinho; isso preserva as RPCs
canônicas e não cria uma segunda fonte de estoque.

## systemd de usuário

Depois de configurar, crie `~/.config/systemd/user/lineboard-adapter.service`:

```ini
[Unit]
Description=Lineboard Linux cloud adapter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lineboard
ExecStart=/usr/bin/node /opt/lineboard/linux/lineboard-adapter.mjs run --host 0.0.0.0 --port 47832
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.config/lineboard %h/.local/state/lineboard

[Install]
WantedBy=default.target
```

Ative-o:

```bash
systemctl --user daemon-reload
systemctl --user enable --now lineboard-adapter.service
systemctl --user status lineboard-adapter.service
journalctl --user -u lineboard-adapter.service -f
```

Para ele continuar após logout:

```bash
loginctl enable-linger "$USER"
```
