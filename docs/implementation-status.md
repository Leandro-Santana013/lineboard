# Estado da implementação

## Interface desktop React/Mantine — 31/10/2026

- Interface migrada para React 19 e componentes Mantine 9, embutidos no
  `desktop/bin/Lineboard.exe` pelo WebView2. Assets são locais; o aplicativo
  não exige servidor Node, CDN nem conexão à internet para renderizar as telas.
- Uma janela mantém menu e navegação. Estoque, Novo produto, histórico,
  etiquetas e configurações são vistas internas. Edição e ajuste usam painéis
  laterais. A interface WinForms anterior exige `--legacy-ui` explicitamente.
- Estoque com busca, filtros e situação por peça; caixa com total, pagamento,
  remoção e confirmação. As listas têm rolagem interna para preservar as ações.
- Vendas e saídas em uma tela interna com filtros de semana, mês e ano, marca,
  tipo de peça, pagamento e busca por produto/código. O relatório mostra
  faturamento, quantidade de vendas, peças baixadas, ticket médio, agrupamentos
  e detalhamento por venda.
- Novo produto implementado com ficha, grade de cor/tamanho/quantidade,
  resumo simultâneo e informações adicionais recolhidas. Marca e tipo de peça
  ficam no cadastro para alimentar estoque e relatórios; cor e tamanho aceitam
  texto livre. Cada peça recebe seu código ao cadastrar. O rascunho permanece
  ao consultar outra área e voltar; Cancelar descarta o rascunho explicitamente.
- Edição individual preserva revisão e dados fiscais. Cadastro, edição e venda
  reaproveitam a identificação da solicitação ao tentar novamente após falha.
  Leituras do celular aparecem na tela sem recarregar a aplicação.
- Nenhum menu Conexões nem botão de sincronização manual na operação diária.
  A configuração técnica fica fora do fluxo do cliente; o sistema mostra apenas
  o estado amigável da operação automática. A fila persistente interrompe
  tentativas em caso de conflito. Publicação remota segue pendente.
- O host usa uma ponte de comandos com origem e payloads validados. O conector
  C#, as transações SIC e a API autenticada do celular foram preservados.
  Não foi criado endpoint de confirmação de venda para o celular.
- 12 testes React aprovados; build Vite concluído. 20 testes da ponte aprovados
  em nova cópia SQL, incluindo cadastro de três variações/quatro peças,
  idempotência, edição, caixa, venda e preservação do SIC original.
- 11 verificações no WebView2 real aprovadas: mensagens à ponte, cadastro,
  atualização sem recarregar, tratamento de erro, preenchimento do formulário,
  relatório de vendas, capturas e navegação com uma única janela. A tela de estoque foi inspecionada
  em 1224 × 794; o código aparece sob o nome quando não cabe em coluna própria.
  Capturas reais: [estoque](images/desktop-react-2026-10-31.png) e
  [Novo produto](images/novo-produto-react-2026-10-31.png).
- Os testes foram executados no próprio host WebView2, com SQL em laboratório
  dedicado. Isso não substitui aceitação manual na loja nem validação fiscal.
- 20 cenários de estoque/nuvem aprovados novamente. Os 41 testes do conector
  passaram nesta sessão antes da migração visual. Os 32 testes WinForms
  anteriores foram preservados em `test-legacy-ui.ps1` como histórico.
- Cópia anterior da GUI preservada em `.local/desktop-backups`. O banco de
  trabalho não recebeu dados demonstrativos. A migração visual continua em
  laboratório e não habilita emissão fiscal nem uso no SIC operacional.

## Diagnóstico fiscal — 31/10/2026

- Usuário solicitou NF-e modelo 55 e NFC-e modelo 65 para loja em SP.
  Há impressora física informada, mas o usuário ainda não sabe se a saída
  atual é nota autorizada ou somente comprovante.
- SIC 6.0.184.1968 localizado. Emissores adicionais não encontrados nas pastas
  e programas SICNET pesquisados; base `SICNET` continua demonstrativa.
  A tabela `TABNFCE` existe e contém zero registros na inspeção.
- Nenhum certificado vigente com chave privada encontrado nos repositórios
  Windows consultados; arquivos PFX externos/tokens não foram inspecionados.
  A consulta de impressoras nesta sessão ficou indisponível.
- Criado e executado `desktop/scripts/probe-fiscal.ps1`, somente leitura.
  Resultado em `.local/fiscal-readiness.json`; não instala, não altera a
  configuração fiscal e não transmite documentos.
- O acionamento dos emissores, retorno de autorização e homologação continuam
  pendentes. O checkout da nova interface agora permite selecionar NF-e/NFC-e e
  registra `fiscal_status=pending_adapter`; isso ainda não é uma autorização
  fiscal. Descobertas, requisitos e referências em
  [fiscal-integration.md](fiscal-integration.md).

## Publicação Supabase — 31/10/2026

- CLI autenticada e vinculada ao mesmo projeto do mobile, `isktnezzanqpcrkkqldw`.
  Projeto confirmado `ACTIVE_HEALTHY` após concluir sua inicialização.
- Migration `202610280001_sic_bridge.sql` aplicada; as tabelas da ponte estão
  com RLS. A migration base já constava no histórico remoto e foi preservada.
- `invite-member`, `commerce` e `sic-sync` publicadas e confirmadas `ACTIVE`.
  Chamadas POST sem credencial receberam HTTP 401 nas três funções.
- 20 testes locais de estoque/nuvem passaram; 10 verificações remotas adicionais
  passaram usando uma organização temporária: importação autenticada,
  repetição sem duplicação, rejeição de payload alterado, venda e baixa única.
  As fixtures remotas foram removidas; a loja existente permaneceu sem produtos.
- Primeiro administrador criado pelo Auth Admin API e vinculado à organização
  existente. Nenhuma mensagem enviada e nenhuma confirmação de e-mail simulada.
  A identidade deverá ser confirmada pelo próprio usuário ao entrar no aplicativo.
- Cadastro público desativado e callback `io.lineboard.mobile://login-callback`
  configurado. Templates personalizados foram retirados do config automático:
  o plano Free com SMTP padrão recusou a alteração. Templates padrão preservados;
  SMTP próprio e envio de login pelo usuário ainda não foram validados.
- Scripts reproduzíveis: `scripts/bootstrap-admin.ps1` (prepara conta sem enviar
  e-mail) e `scripts/test-supabase-live.ps1` (fixtures isoladas com limpeza).
  Chaves de servidor são obtidas pela CLI apenas em memória e não entram no app.
- O receptor Realtime do desktop está implementado em `desktop/src/RealtimeBridge.cs`.
  Ele mantém heartbeat, recupera comandos pendentes após reconexão, filtra pela
  instância e confirma cada operação pela função `sic-command-ack`; a aplicação
  local continua idempotente e não toca a base original do SIC.
- A migration `202610310001_sic_command_bridge.sql`, a função
  `supabase/functions/sic-command-ack` e a configuração `verify_jwt=false` já
  estão no repositório. A publicação remota desta nova migration/função e o
  registro da instância precisam ser executados antes de ativar a ponte em uma
  loja. O mobile deve ser compilado com `LINEBOARD_MODE=cloud` para usar essa fila.

## Importação controlada para SICNET — 31/10/2026

- O catálogo da cópia `LINEBOARD_LAB` foi conferido e importado para `SICNET`:
  57 registros em `TABEST1`, 2 recebimentos em `TABEST2A`, 57 linhas em
  `TABEST2B`, 57 unidades Lineboard e 57 movimentos iniciais. Vendas não foram
  importadas.
- O schema `lineboard` foi preparado no alvo, a sequência de códigos ficou em
  `SLB-900000000058` para o próximo cadastro e o marcador de instância recebeu
  um novo identificador. A consulta posterior retornou 57 produtos, 57 unidades
  e zero vendas.
- Backups COPY_ONLY ficaram em `.local/LINEBOARD_PREIMPORT_20261031_181603.bak`
  e `.local/LINEBOARD_PREPARE_20261031_181847.bak`. O script reproduzível é
  `desktop/scripts/import-lab-products.ps1` para a carga de tabelas e
  `desktop/scripts/prepare-sicnet-lineboard.ps1` para o metadata Lineboard.
- O executável padrão continua no laboratório. O modo de produção exige a
  confirmação explícita `--production --confirm-production`; emissão fiscal,
  regras nativas do SIC e sincronização remota ainda não foram homologadas.

## Gerenciamento SIC local — 28/10/2026 (histórico)

- Criados conector SQL Server e executável Windows em `desktop/`. Usam .NET
  Framework disponível nesta máquina, sem instalar SDK ou servidor adicional.
- Criado `LINEBOARD_LAB` por backup COPY_ONLY + RESTORE com arquivos em `.local`.
  Não houve detach, cópia a quente do MDF nem alteração da conexão do SIC original.
- 41 verificações passaram no SQL Server real: cadastro de cinco peças com códigos
  diferentes, edição individual, carrinho sem baixa, recuperação após reinício,
  confirmação concorrente idempotente, falha no segundo item com rollback total,
  histórico, ajustes, detecção de conflito externo, autenticação da LAN, limites
  do scanner e confirmação de recebimento na sincronização.
- Na consulta final anterior à importação, o original `SICNET` retornou zero
  produtos, zero vendas e ausência do schema `lineboard`; a importação controlada
  posterior está registrada na seção acima.
- Implementado modo Flutter local como padrão: pareamento, cadastro/etiquetas,
  scanner remoto e operações pendentes em SQLite. Credencial no armazenamento
  seguro; o celular não confirma venda. O modo anterior exige `LINEBOARD_MODE=cloud`.
- `npm test`: 20 cenários aprovados, incluindo sete cenários da ponte com as
  migrations reais no PostgreSQL WASM: importação, revisões, baixa única, ajustes,
  conflito com venda online, autorização e RLS.
- `flutter test`: 13 testes aprovados; `flutter analyze`: sem problemas.
- `deno check` da função `sic-sync`: aprovado.
- APK Android debug do modo local compilado em 28/10/2026, com 208.815.766 bytes.
  SHA-256: `d9869e05f4634420aa376a4a584b9af4a078070e3dc8955b1a7c709b2ccedf4b`.
  Não havia aparelho conectado ao ADB; instalação e pareamento físicos pendentes.
- Executável Windows compilado com 110.080 bytes. SHA-256:
  `f97c6c9e315c788a951e22406f627b691557f635aa2399644b1f9ae0bbe6a7be`.
  Os comandos de diagnóstico usam `desktop/bin/Lineboard.Cli.exe`, separado da GUI.
- Prévia da interface gerada pelo próprio renderizador WinForms e inspecionada.
  Isso não substitui teste interativo no Windows nem conferência da venda no SIC.
- A automação da janela nativa SIC falhou com `failed to write kernel assets`;
  a compatibilidade das regras comerciais/fiscais do executável não foi validada.
- Um teste adicional de iniciar/encerrar um processo em segundo plano foi
  rejeitado pela revisão automática. A API HTTP foi validada dentro dos testes
  do próprio conector, sem esse procedimento.
- `supabase projects list` retornou `Access token not provided`; migration e função
  novas não foram aplicadas/publicadas na nuvem. Nenhuma credencial foi incluída
  no aplicativo ou documentação.
- Foto ainda é referência textual; mídia binária pendente. Etiquetas desktop em
  HTML/SVG e mobile em PNG; impressora e leitura física ainda não verificadas.
- Não há aplicação de pedidos remotos no SIC, sincronização automática contínua,
  tratamento completo de devolução financeira nem interface de resolução de
  conflitos. NF-e/NFC-e seguem indisponíveis no protótipo; nenhum XML foi emitido.
- Antes da importação, escritas ficavam restritas a bancos `LINEBOARD_LAB*`. O
  código agora mantém esse padrão por default e só permite `SICNET` com os dois
  argumentos explícitos `--production --confirm-production`.

Guia de execução, contrato LAN e limitações em [desktop/README.md](../desktop/README.md).

## Histórico do fluxo Supabase anterior

Verificado localmente em 23/10/2026:

- 13 cenários SQL em PGlite: variantes, unidades, numeração única, isolamento RLS,
  convites/permissões, edição de ficha, integridade das transações, e-commerce e idempotência.
- 2 cenários em PostgreSQL nativo: disputa da última peça entre físico/online e
  dois envios paralelos da mesma venda. Só uma baixa foi gravada nos dois casos.
- 8 testes Flutter: domínio, telas, recuperação após reabrir SQLite, preservação
  de consulta offline e reenvio com a mesma chave e conteúdo.
- `flutter analyze`: sem problemas.
- `deno check`: duas funções verificadas, sem erros TypeScript.
- 4 testes Deno aprovados para seleção de chaves modernas e compatibilidade local.
- APK Android debug 0.1.0 compilado com sucesso, incluindo a revisão de edição
  de ficha. Android 7.0+ (API 24), alvo API 36; engine presente para ARM64,
  ARMv7 e x86_64. Arquivo: `mobile/build/app/outputs/flutter-apk/app-debug.apk`
  (208.729.330 bytes), configurado com a URL e a chave pública do projeto. SHA-256:
  `69f197a0a25549efda866361c767f3cd3582146b814f2ef313d7345e0bb0e4c4`.
- APK atualizado por USB no aparelho Android 16 conectado; instalação e abertura
  concluídas. A tela real de login foi conferida por captura do aparelho, sem
  encerramento inesperado no log do processo. O primeiro acesso ainda está pendente.

Supabase conectado em 23/10/2026: projeto `isktnezzanqpcrkkqldw`, PostgreSQL 17.11.
A conexão SQL foi validada com TLS e CA Supabase. A migration `202610220001`
foi aplicada em transação e registrada em `supabase_migrations.schema_migrations`.
As 11 tabelas públicas estão com RLS habilitado e o bucket `product-photos` é
privado, com limite de 5 MB. O banco estava sem tabelas do app e sem usuários.
Nenhuma senha de banco foi salva em arquivo ou incluída no aplicativo.
Conferido na nuvem: acesso anônimo ao estoque e à RPC de venda bloqueado;
alteração direta de saldo por usuários e execução da baixa de integração por
funcionários bloqueadas. As views respeitam RLS (`security_invoker=true`).
A API REST respondeu 401 na tentativa anônima de consultar o catálogo, mesmo com
a chave pública válida. O endpoint de configurações Auth respondeu 200 com essa
chave. A conexão SQL foi encerrada.

O arquivo ignorado `mobile/config.json` contém a URL do projeto e a chave
publishable fornecida pelo usuário. A organização `Leandro Santana` foi criada
com ID `c084a7a2-6862-4562-8328-e7cc822c37dc`. Ainda não existe usuário Auth para
o e-mail indicado, portanto o vínculo de administrador não foi criado.
Ainda faltam a configuração Auth remota, o convite do primeiro administrador e
o deploy das funções `invite-member` e `commerce` (atualmente retornam 404).
Os modelos locais de e-mail mostram o código de acesso e o link para abrir o app.
A autorização da CLI pelo titular da conta Supabase está pendente; a senha SQL
não concede acesso à API de gerenciamento do Supabase. O cadastro público remoto
ainda está habilitado e precisa ser desabilitado conforme a configuração local.
Não houve teste de login, SMTP, envio de fotos ou vendas pelo celular contra a nuvem.
As funções suportam as chaves modernas do runtime, além das variáveis legadas.

A verificação física de câmera, etiquetas impressas e compartilhamento em
Android/iPhone está pendente. O build iOS precisa de macOS/Xcode; o fluxo de CI
inclui compilação iOS sem assinatura. O aplicativo Windows e o conector de uma
plataforma de e-commerce específica não fazem parte deste entregável.
