# Interface React/Mantine no desktop

Orientação do usuário em 31/10/2026: adotar biblioteca frontend por causa dos
defeitos constantes de borda e da abertura de novas janelas a cada clique.
Manter a composição visual aprovada e o backend SIC, mas usar uma aplicação
React + Mantine local, embutida no executável Windows pelo WebView2.

## Experiência

- Uma janela nativa e um AppShell persistente. Loja/estoque, novo produto,
  edição, histórico, etiquetas e configurações são vistas internas, sem abrir
  Forms, abas de navegador ou recarregar a aplicação a cada clique.
- Manter rascunho do produto quando navegar. Ficha, grade e resumo simultâneos;
  adicionais recolhidos conforme `novo-produto-aprovado.png`.
- Ações pequenas (ajuste, confirmação da venda) podem usar painel lateral ou
  confirmação dentro da tela; não uma nova janela do sistema operacional.
- Usar componentes Mantine reais e tema compartilhado. Nada de imitar controles
  desenhando retângulos nativos manualmente. Menu azul escuro e ações petróleo.
- Sincronização automática em segundo plano; nenhuma seção Conexões no menu.
- Conteúdo e componentes empacotados localmente, sem CDN, fontes externas ou
  servidor Node obrigatório para executar o aplicativo. Acesso ao SIC somente
  pelo código .NET existente. A API do celular mantém as mesmas proteções.

## Contrato da ponte host/frontend

Origem virtual fixa `https://lineboard.local/`, assets em `desktop/bin/ui`.
WebView2 recebe objeto via `window.chrome.webview.postMessage`:

```json
{"id":"correlation-id","action":"bootstrap","payload":{}}
```

Resposta postada pelo host como objeto JSON:

```json
{"id":"correlation-id","ok":true,"data":{}}
```

Erro:

```json
{"id":"correlation-id","ok":false,"error":{"code":"DOMAIN_CODE","message":"Mensagem amigável"}}
```

Comandos (contrato comum dos dois implementadores):

| action | payload | data |
| --- | --- | --- |
| bootstrap | {} | {catalog: Unit[], cart: {version, items: Unit[], total}, mode: "sandbox", sync_state: string} |
| product.create | ProductDraft (inclui request_id e variants) | retorno de SicStore.CreateProduct |
| unit.get | {barcode} | retorno de Lookup |
| unit.edit | {barcode, draft: EditDraft} | retorno de Edit |
| stock.adjust | AdjustmentDraft | retorno de Adjust |
| cart.add | CartDraft | retorno de AddCart |
| cart.remove | CartDraft | retorno de RemoveCart |
| cart.confirm | ConfirmDraft (version, payment, request_id) | retorno de Confirm |
| history.list | {} | {items: store.History()} |
| labels.preview | {} | {html: Labels.Html(catalog com quantity=1, 50, 30)} |
| labels.export | {} | {saved: bool} (SaveFileDialog é permitido para escolher o arquivo) |
| settings.info | {} | {address: api.Address, sync_configured: bool, mode: "sandbox"} |
| pair.open | {} | {address: api.Address, pin: api.OpenPairing(), expires_in_seconds: 180} |
| support.outbox | {} | {items: store.Outbox()} |

Unit e drafts mantêm o contrato de `Models.cs`/`SicStore.cs`, inclusive os campos
fiscais. Não inventar outra camada de estoque. Credenciais de nuvem nunca passam
à interface. Formulário reutiliza request_id numa nova tentativa da mesma operação
e não confirma duas vezes por clique duplo. Confirmação de venda existe apenas
na ponte desktop confiável; não adicionar endpoint à API do celular.

Validar origem exata das mensagens; bloquear navegação externa, novas janelas e
permissões do WebView; allowlist de ações. Não remover o bloqueio de Origin da
LocalApi nem liberar CORS para contornar a integração. A interface em navegador
sem host deve explicar que o desktop é necessário, sem dados fictícios automáticos.

## Divisão de arquivos

- Agente frontend: `desktop/frontend/**`, seus testes e capturas; usa o contrato
  acima. Não altera Program.cs, scripts de build ou a ponte host.
- Agente host: nova ponte .NET, host WebView2, Program.cs, scripts de dependências,
  build e testes .NET da ponte. Não altera `desktop/frontend/**`.
- Coordenador: revisão integrada, documentação final e conferência do executável.

Testes usam laboratório novo `LINEBOARD_LAB*`, nunca fixtures no banco de trabalho
LINEBOARD_LAB e nunca escrita no SICNET original. Conservar backup/executável antigo
para reversibilidade. Não comitar, publicar ou instalar SDK/sistema sem necessidade.

Referências consultadas:
- https://mantine.dev/core/app-shell/
- https://mantine.dev/form/use-form/
- https://learn.microsoft.com/en-us/microsoft-edge/webview2/get-started/winforms
- https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/working-with-local-content
