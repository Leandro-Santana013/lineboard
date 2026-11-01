# Integração do estoque

> Este documento descreve a API Supabase anterior. Na arquitetura escolhida em
> 28/10/2026, o Flutter usa o desktop na LAN e a venda é confirmada no Windows.
> O conector SIC e a ponte de sincronização estão descritos em
> [desktop/README.md](../desktop/README.md). A API abaixo continua disponível no
> código, mas não deve registrar novamente uma venda recebida pela ponte SIC.

O Supabase é a fonte de verdade. O celular registra o cadastro e vendas físicas;
o aplicativo Windows poderá ler `inventory`, `sales` e `stock_movements` com o
login do usuário e as mesmas políticas por organização. Nenhum cliente deve
editar `stock_items.quantity` diretamente.

## Credencial por empresa

Um administrador autenticado pode gerar uma credencial no terminal:

```powershell
$env:SUPABASE_URL = 'https://PROJETO.supabase.co'
$env:SUPABASE_PUBLISHABLE_KEY = 'CHAVE_PUBLICA'
$env:ADMIN_ACCESS_TOKEN = 'ACCESS_TOKEN_DO_ADMIN'
$env:ORGANIZATION_ID = 'UUID_DA_EMPRESA'
node scripts/create-integration.mjs "Minha loja virtual"
```

O script exibe o ID e um token uma única vez. Guarde o token apenas no servidor
do e-commerce. O banco guarda somente o SHA-256. Não colocar em JavaScript público,
no app mobile ou no controle de versão. Revogue com a RPC
`revoke_integration_key({p_id: ID})`, usando o login do administrador.

## Consultar catálogo e disponibilidade

```http
GET /functions/v1/commerce?limit=100&after=SLB-000000000001
Authorization: Bearer slb_live_...
```

Resposta `200`: `{ "items": [...], "next_after": "SLB-..." | null }`.
Omitir `after` na primeira página; usar `next_after` até receber `null`.
O limite é de 1 a 500 itens. Os registros incluem `barcode`, `stock_item_id`,
`product_id`, `variant_id`, nome, marca, cor, medida, `tracking`, `quantity` e
`updated_at`. Itens vendidos continuam presentes com quantidade zero.
Fotos são privadas; `photo_path` é uma referência de armazenamento, não uma URL
pública para o e-commerce. A publicação de fotos deve ser feita pelo futuro
backend do e-commerce com autorização específica.

Usar `barcode` como SKU externo estável. No modo individual cada unidade é um SKU
vendável; a vitrine pode agrupar por `variant_id`, mas a venda deve informar o
código da unidade exata. O endpoint é uma consulta paginada atual, não um snapshot
transacional nem um feed de mudanças. Refaça a consulta para atualizar a vitrine.

## Baixar uma venda confirmada

```http
POST /functions/v1/commerce
Authorization: Bearer slb_live_...
Idempotency-Key: 0e6ae468-58e0-46b2-8919-36a2acdc50c8
Content-Type: application/json

{
  "order_id": "shopify:pedido-1042",
  "lines": [
    { "barcode": "SLB-000000000001", "quantity": 2 },
    { "barcode": "SLB-000000000008", "quantity": 1 }
  ]
}
```

Resposta `200`: `{ "sale_id": "uuid", "replayed": false }`.
O sistema faz tudo em uma transação: bloqueia os itens, confere disponibilidade,
registra a venda, baixa o saldo e grava o histórico. Qualquer falha desfaz a venda
inteira. Saldo negativo e segunda venda da mesma unidade individual são recusados.

O backend do e-commerce deve gerar e persistir um UUID por pedido antes do
primeiro envio. Em timeout, falha de rede ou `5xx`, repetir a mesma chave e o mesmo
conteúdo. A repetição retorna o mesmo `sale_id` com `replayed: true`. Reutilizar a
chave com outro conteúdo retorna `409 IDEMPOTENCY_CONFLICT`. Uma referência de
pedido já usada com outra chave retorna `409 ORDER_ALREADY_RECORDED` e não baixa
novamente. Prefixe a referência com o canal para evitar colisões entre plataformas.

Erros: `401 UNAUTHORIZED`, `400 INVALID_LINES`, `400 BARCODE_NOT_FOUND`,
`409 INSUFFICIENT_STOCK`, `409 IDEMPOTENCY_CONFLICT`,
`409 ORDER_ALREADY_RECORDED`. A credencial determina a empresa; não há parâmetro
para escolher outra organização.

O adaptador futuro deverá validar a assinatura do webhook do provedor e escolher
um único evento de pedido confirmado para chamar esta API. Não chamar para pedido
criado, checkout aberto e pagamento confirmado do mesmo pedido como vendas
distintas. Vendas online já integradas não devem ser registradas novamente como
venda física pelo celular.

Este MVP não implementa reserva no checkout, pagamento, cancelamento, estorno,
devolução ou reposição. Se a última peça for vendida no balcão e online ao mesmo
tempo, a primeira baixa confirmada vence; a outra recebe falta de estoque. O
futuro checkout precisa tratar isso antes de prometer a peça ao comprador.

## RPCs do app mobile

- `accept_invitations()`: aceita convites não expirados do e-mail verificado.
- `create_product(p_org, p_request_id, p_product)`: cadastro transacional,
  incluindo variantes, códigos e saldo inicial. `p_request_id` é UUID estável
  enquanto o resultado não for confirmado.
- `update_product(p_org, p_product_id, p_fields)`: altera nome, categoria, marca,
  modelo e observações online. Identificadores, modo de controle, variantes e
  saldos não são editados por esta operação.
- `record_physical_sale(p_org, p_key, p_lines, p_reference)`: mesma baixa, vinculada
  ao funcionário. O canal é sempre `physical`, definido no banco.
- `prepare_invitation` é usado pela função `invite-member`, que verifica o usuário
  e o papel de administrador antes de enviar o e-mail pelo Supabase Auth.

`p_product` usa `name`, `category`, `brand`, `model`, `tracking`
(`quantity` ou `individual`), `notes`, `photo_path` opcional e `variants`:
`[{"color":"Azul","size":"M","quantity":5}]`.
O modo por quantidade gera um código por variante; o individual gera um por peça.
Os códigos Code 128 têm formato `SLB-` e 12 dígitos, gerados exclusivamente pela
sequência do banco. Lacunas na sequência são normais e não devem ser reutilizadas.
