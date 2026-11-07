# Gerenciamento SIC / Lineboard

Implementação Windows com interface React/Mantine no WebView2, conector
C#/.NET Framework 4.8 e API para o Flutter na rede local. O único executável
do produto é `desktop/bin/Lineboard.exe`; ele abre o `SICNET` local por padrão.
O laboratório continua disponível somente com `start.ps1 -Lab`. Em 31/10/2026, uma importação controlada
levou 57 produtos e seus recebimentos para a base demonstrativa `SICNET`, com
backup COPY_ONLY; isso não habilita emissão fiscal.

## Entrega para o computador da loja

O computador da loja não precisa de Node.js, npm, PowerShell de configuração,
compilador C# ou código-fonte. Gere o instalador em um Windows de build com o
Inno Setup 6 instalado e com o bootstrapper oficial do WebView2 disponível:

```powershell
.\desktop\scripts\package-installer.ps1 `
  -Server '.\SQLEXPRESS' `
  -WebView2Bootstrapper '.\vendor\MicrosoftEdgeWebView2Setup.exe'
```

O arquivo `dist\Lineboard-Setup.exe` instala o executável, a interface React,
`schema.sql`, as DLLs WebView2, o atalho no menu Iniciar/desktop e o WebView2
Runtime. A configuração é gravada em `%ProgramData%\Lineboard\config.json` e
preservada durante atualizações; não é necessário criar variáveis de ambiente.
Para levar também a sincronização cloud, passe `-ConfigFile` com uma cópia
local preenchida a partir de `installer\config.example.json`. Esse arquivo
contém credenciais privadas e não deve entrar no Git ou ser enviado junto do
repositório.

O instalador pressupõe que o computador já tenha o SICNET e o SQL Server
acessíveis pela conta Windows que abrirá o Lineboard. Ele instala o cliente;
não substitui o banco do SIC nem cria uma base de produção. Antes da
apresentação, valide a conexão e deixe o atalho **Lineboard** abrir diretamente
`Lineboard.exe`.

## Abrir nesta máquina

O banco `LINEBOARD_LAB` foi preparado a partir de um backup COPY_ONLY do SIC
demonstrativo. A cópia `SICNET` recebeu os produtos importados pelo script
controlado; o executável normal abre `SICNET`.

```powershell
# Na raiz do projeto:
Push-Location desktop/frontend
npm ci
Pop-Location
.\desktop\scripts\build.ps1
.\desktop\scripts\start.ps1
```

O `desktop/scripts/build.ps1` compila a interface e o executável em uma pasta
separada, verifica o comando de envio de JPG e instala o conjunto completo
somente depois que todas as etapas passam. Feche o Lineboard antes de instalar;
`build.ps1 -PrepareOnly` prepara uma cópia sem alterar a versão em uso. O pacote
anterior fica preservado em `.local/desktop-build` para recuperação. Um build
somente do frontend gera `desktop/obj/ui`, sem modificar a instalação em `desktop/bin`.
O pacote local fixado `Microsoft.Web.WebView2` 1.0.4314.35 é
baixado uma vez para `.local/webview2`, verificado por SHA-256 e reduzido às
assemblies `net462` e ao `WebView2Loader.dll` x64 em `desktop/bin`. O runtime
Evergreen WebView2 precisa estar instalado no Windows; esta máquina usa
`C:\Program Files (x86)\Microsoft\EdgeWebView\Application\156.0.4314.50`.

O executável abre a interface React na mesma janela e exige a origem virtual
`https://lineboard.local/`. `--render-web-preview` (também aceito como
`--render-preview`) carrega o WebView2 real e grava uma captura com
`CapturePreviewAsync`; `--web-self-test` executa a ponte real pelo
`WebMessageReceived`, verifica bootstrap, cadastro, atualização sem recarregar,
navegação interna e uma única janela, e grava a captura. O teste reproduzível
é `.\desktop\scripts\test-web.ps1`, depois de gerar o frontend. O host legado
somente pode ser escolhido explicitamente com `--legacy-ui`; sua captura antiga
usa `--render-legacy-preview`.

Também é possível abrir `desktop/bin/Lineboard.exe`; o executável, sem argumentos,
atende somente em `localhost:47831`. Para celular, use `start.ps1`, que escolhe o
IPv4 da conexão com gateway, ou informe `-HostAddress IP_LOCAL`. Em máquinas com
VPN ou várias interfaces, informe o endereço da rede Wi-Fi da loja explicitamente.
O processo precisa de permissão para escutar nesse endereço pelo HTTP.sys.
Nenhuma reserva de URL nem regra de firewall é alterada automaticamente.

Por padrão, o aplicativo conecta à base `SICNET` na instância local
`.\SQLEXPRESS` usando a conta Windows atual. Para outra instância, inicie o
executável com `--server NOME_DO_SERVIDOR`; a conta precisa ter acesso à base.

Para executar a versão já compilada nesta máquina, basta abrir o executável.
Mantenha a pasta `ui`, as DLLs WebView2 e `schema.sql` junto dele; não copie apenas
o arquivo `.exe`. As etapas npm acima são necessárias somente para recompilar.

O mesmo `desktop/bin/Lineboard.exe` é usado no modo de produção:

```powershell
.\desktop\scripts\start.ps1
```

O script escolhe `SICNET` automaticamente. Cadastro,
edicao, ajuste e venda sao gravados nas tabelas nativas do SICNET e no controle
do Lineboard dentro da mesma transacao SQL. Se uma etapa falhar, tudo e desfeito;
nao existe uma importacao posterior para concluir a operacao.

O comando simples `.\desktop\scripts\start.ps1` agora abre a loja em
producao automaticamente. O laboratorio fica restrito a testes explicitos com
`.\desktop\scripts\start.ps1 -Lab`.

Esse modo grava no SQL Server `SICNET` local. O script aplica automaticamente
`--production --confirm-production` para liberar as escritas no `SICNET`.

Estoque, cadastro, vendas e saídas, histórico, etiquetas e configurações navegam dentro da mesma
janela. Edição e ajuste usam painéis laterais. O cadastro mantém o rascunho ao
navegar para outra área; **Cancelar** descarta os dados não cadastrados.

## Fluxo implementado

1. **Novo produto**: nome, marca, tipo de peça, custo, preço, localização, referência da foto,
   observações, código interno e campos fiscais; grade de cor/tamanho/quantidade.
   Cinco peças geram cinco códigos e cinco registros independentes em `TABEST1`.
2. **Editar peça**: altera somente aquela ficha, com controle de revisão e auditoria.
   O código gerado permanece fixo; GTIN fiscal fica em campo separado.
3. **Adicionar ao caixa** ou leitura pelo celular: salva no carrinho persistente;
   não altera estoque. A mesma peça não entra duas vezes.
4. **Registrar venda e solicitar documento fiscal**: a nova interface permite
   escolher NFC-e (65) ou NF-e (55), grava `TABEST3A`, `TABEST3B`, `TABEST3R`,
   baixa o saldo e registra histórico/fila em uma única transação. A forma de
   pagamento é somente registrada; não há cobrança de cartão, Pix ou Google Pay.
5. **Entrada / ajuste**: saldo individual 0/1, motivo obrigatório e histórico.
   Não representa estorno financeiro nem cancelamento fiscal.
6. **Etiquetas**: exporta HTML autocontido com Code 128 vetorial e margens de
   silêncio, para imprimir ou salvar em PDF pelo navegador. Tamanho inicial
   50 × 30 mm. O equipamento e o formato físico ainda serão definidos pela loja.
7. **Atualização automática**: eventos persistentes são enviados em segundo plano
   imediatamente após cada transação confirmada e ao abrir o aplicativo. Mudanças
   externas do carrinho chegam pelo Supabase Realtime e disparam uma única
   reconciliação; falhas usam somente retry do evento que falhou, sem leitura
   periódica do banco. Falhas preservam os eventos para a próxima tentativa;
   conflitos interrompem o envio. Nenhuma ação de sincronização é exigida do
   operador. O estado da configuração fica em **Configurações**; o diagnóstico
   detalhado continua disponível pela CLI (`--health` e `--export-outbox`).
   Um recebimento sem identificação correspondente não marca o evento como enviado.
8. **Vendas e saídas**: consulta semana, mês ou ano com filtros de marca, tipo de
   peça, pagamento e busca por produto/código. O resultado reúne faturamento,
   peças baixadas, ticket médio e o detalhamento das linhas vendidas.

Os campos de nome/marca seguem os limites reais do SIC (50/20 caracteres).
Foto é, nesta etapa, uma referência textual; upload, cópia do binário para `foto`
do SIC e sincronização de mídia ainda não foram implementados.

## Celular

O Flutter usa o Supabase por padrão. O computador da loja mantém uma conexão
Realtime de saída e recebe a fila de comandos sem exigir que o cliente conheça
endereço, porta ou momento de sincronização. A operação só aparece como
concluída no celular depois da confirmação do desktop.

O modo local e o pareamento por código continuam disponíveis apenas para
laboratório e troubleshooting, com `--dart-define=LINEBOARD_MODE=local`.

Este laboratório usa HTTP somente em endereços locais, com credencial de
pareamento. Isso não fornece criptografia de transporte na LAN. TLS com
pareamento de certificado é requisito antes de uma distribuição operacional.
Android permite HTTP para este fluxo e o cliente valida endereços privados e
recusa redirecionamentos. iOS declara uso da rede local e exceções ATS restritas
a IPv4 privados/loopback; falta validação em iPhone. A configuração segue a
[documentação Apple](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

Para abrir o fluxo Supabase no Flutter:

Empresas vinculadas ao SIC têm as RPCs antigas de cadastro e confirmação física
bloqueadas na nuvem; isso evita contornar o caixa ou criar um estoque independente.
Empresas sem vínculo mantêm o comportamento anterior.

```powershell
cd mobile
flutter run --dart-define=LINEBOARD_MODE=cloud --dart-define-from-file=config.json
```

## Supabase

Migrations `202610280001_sic_bridge.sql`, `202610310001_sic_command_bridge.sql`,
`202611020001_cloud_bootstrap.sql` e `202611020002_rotate_sic_instance.sql`
aplicadas; a função `sic-sync` está publicada no projeto mobile existente.
A CLI desta máquina foi autenticada e vinculada ao projeto.
As verificações remotas passaram em organizações temporárias, removidas
ao terminar: credencial, importação, idempotência, conflito, venda e baixa única.
O cadastro público está desativado e o retorno do login aponta para o aplicativo.

O primeiro administrador foi preparado e vinculado à loja existente, sem
confirmar o e-mail em nome do usuário nem enviar mensagens. Os modelos padrão
de e-mail foram mantidos: projetos Free com provedor padrão recusam templates
personalizados. SMTP próprio não foi configurado.

O `Lineboard.exe` registra automaticamente a instalação na primeira
sincronização, puxa o snapshot cloud e depois envia a fila local. A credencial
fica somente no Windows do desktop, nas variáveis de ambiente
`LINEBOARD_SYNC_URL` e `LINEBOARD_SYNC_TOKEN`; nunca no Flutter, em documentos
ou no controle de versão. A URL deve ser HTTPS e terminar em
`/functions/v1/sic-sync` no domínio do projeto Supabase. `--sync-now` executa
o mesmo ciclo imediatamente para diagnóstico ou carga inicial.

O campo `LINEBOARD_SIC_SERVER` representa a instância/servidor do SQL Server,
não o nome do banco. Se ele não estiver configurado ou apontar para uma
instância indisponível, o desktop procura automaticamente o LocalDB padrão,
outras instâncias LocalDB, SQL Express e instâncias registradas no Windows.
Assim, computadores com nomes diferentes de servidor não precisam de ajuste
manual. O catálogo do SIC continua sendo `SICNET`, que é o banco esperado pelo
conector atual.

Em uma nova máquina, abra o PowerShell como Administrador e execute uma vez
`.\desktop\scripts\configure-cloud.ps1`. Se o SIC estiver no SQL Express,
informe a instância, por exemplo: `.\desktop\scripts\configure-cloud.ps1 -Server '.\SQLEXPRESS'`.
O script pede o token em campo oculto, configura as variáveis na máquina para
todos os usuários do Windows e executa o bootstrap inicial. O token não é gravado no projeto,
no Git nem em arquivo de log; depois disso, basta abrir o `Lineboard.exe`.

Para instalações novas usando o instalador com ativação, o administrador pode
gerar um código temporário com `node scripts/create-activation.mjs`. Abra
**Configurações** no Lineboard, informe o código no cartão **Ativar este
computador** e reinicie o aplicativo. A credencial e as URLs são gravadas em
`C:\ProgramData\Lineboard\config.json`; nenhum token precisa ser digitado no
PowerShell. O código é de uso único por padrão e expira em 24 horas.

O servidor deriva a organização da credencial e registra cada instalação da loja.
Todos os computadores dessa organização leem o mesmo estoque e o mesmo carrinho
persistido no Supabase. O celular envia a leitura ao carrinho da loja sem escolher
um computador; a leitura não baixa estoque. A confirmação final é feita no desktop.
Os desktops recebem pelo Supabase Realtime o evento de mudança do carrinho central;
cada evento dispara uma reconciliação única, enquanto alterações locais disparam
envio imediato. Computadores fechados recuperam o estado ao abrir ou ao reconectar.

O novo aplicativo mobile inclui uma ação para encaminhar ao carrinho compartilhado
os itens de uma tentativa antiga que exibia `DESKTOP_CONFIRMATION_REQUIRED`.
Atualize o APK e o `Lineboard.exe` em todos os computadores para usar este fluxo.
Uma confirmação solicita um bloqueio central antes da transação local, impedindo
duas confirmações simultâneas da mesma compra nos desktops atualizados. Se um
resultado local ficar incerto, o bloqueio é mantido para reconciliação, sem expirar
automaticamente e liberar a peça para outra venda.

Cada organização mantém seu estoque e carrinho isolados. O modo atual compartilha
o carrinho dentro da loja; roteamento para caixas específicos requer uma configuração
própria futura e não usa o usuário do Windows como identidade da empresa.

O snapshot central
preserva IDs, revisões e referências das peças e aplica a mesma operação de baixa
transacional usada pelo estoque central. Ao abrir uma instalação nova, o snapshot
é importado em uma transação local do SIC. Repetir um evento retorna seu resultado.
Se o saldo da nuvem já mudou, o evento fica em conflito e interrompe a fila;
não ressuscita estoque nem repete uma venda. Os dados financeiros e fiscais por
peça ficam em `sic_unit_links.snapshot`, protegidos por RLS, e não são públicos.

O carrinho compartilhado continua usando as RPCs `read_sic_cart` e `update_sic_cart`
no celular e o snapshot autenticado da Edge Function `sic-sync` nos desktops. O
Realtime apenas sinaliza que a versão mudou; ele não substitui nem duplica a
fonte canônica. Para receber mudanças externas sem polling, o desktop precisa das
variáveis `LINEBOARD_REALTIME_*` configuradas no Windows.

A ponte opcional de comandos `sic_commands`/Supabase Realtime continua disponível
para comandos direcionados, como cadastro pelo adaptador, com resposta pela Edge
Function `sic-command-ack`. O comando mobile `cart.confirm` foi recusado no servidor:
o celular prepara o carrinho e a compra só é confirmada pelo operador no desktop.
O e-commerce continua fora desta etapa.

A ponte bidirecional precisa da migration `202610310001_sic_command_bridge.sql`
e da função `supabase/functions/sic-command-ack` publicadas no projeto. Depois
de registrar a instalação com `register_sic_connection`, configure no computador
da loja, sem colocar esses valores no Flutter:

```powershell
$env:SUPABASE_URL = 'https://<projeto>.supabase.co'
$env:LINEBOARD_REALTIME_URL = 'wss://<projeto>.supabase.co/realtime/v1/websocket'
$env:LINEBOARD_REALTIME_KEY = '<chave de servidor/Realtime>'
$env:LINEBOARD_SYNC_URL = 'https://<projeto>.supabase.co/functions/v1/sic-sync'
$env:LINEBOARD_SYNC_TOKEN = 'slb_live_<token da integração>'
```

`LINEBOARD_REALTIME_KEY` fica somente no Windows do desktop e nunca deve ser
publicada no aplicativo ou em documentação. O mobile usa o modo cloud com
`--dart-define=LINEBOARD_MODE=cloud`; quando a instalação estiver registrada,
cadastros e vendas do celular aguardam a confirmação do computador pela fila.

Os códigos `SLB-9XXXXXXXXXXX` são o intervalo experimental deste laboratório.
Não habilitar várias instalações independentes emitindo esse mesmo intervalo.
A atribuição definitiva de intervalos por instalação deve preceder produção.

## Validação reproduzível

```powershell
.\desktop\scripts\test.ps1
.\desktop\scripts\test-bridge.ps1
.\desktop\scripts\test-ui.ps1
.\desktop\scripts\test-web.ps1
npm test
cd mobile
flutter analyze
flutter test
flutter build apk --debug --dart-define=LINEBOARD_MODE=local
```

O teste desktop cria uma NOVA cópia isolada, executa as operações reais no SQL
Server, disputa a mesma confirmação em conexões paralelas e injeta uma falha no
segundo item para verificar rollback integral. Preserva a cópia e o backup como
evidência; não apaga bancos. O teste recusa uma cópia que já tenha peças.
Os testes de nuvem executam as duas migrations reais no PostgreSQL WASM/PGlite.

`test-ui.ps1` executa a suíte React; com `-WithWebView2`, também chama
`test-web.ps1` para o WebView2 real. A antiga verificação de controles WinForms
foi preservada em `test-legacy-ui.ps1` como histórico e não valida a migração.

Migração conferida em 31/10/2026: 11 testes React, 18 verificações da ponte SQL
e 9 verificações no WebView2 real aprovados. O teste integrado cadastra três
variações/quatro peças em uma cópia dedicada, preenche o rascunho de Novo produto,
verifica a atualização sem recarregar e confirma uma única janela durante a
navegação. Capturas reais: [estoque](../docs/images/desktop-react-2026-10-31.png)
e [Novo produto](../docs/images/novo-produto-react-2026-10-31.png).

## Limite de compatibilidade SIC

Para NF-e 55 e NFC-e 65 em São Paulo, o diagnóstico e o caminho de integração
estão em [docs/fiscal-integration.md](../docs/fiscal-integration.md). Execute
`desktop/scripts/probe-fiscal.ps1` para localizar os programas e verificar os
pré-requisitos disponíveis, sem emitir documentos nem alterar o SIC.

Os nomes/tipos foram conferidos no SIC 6.0.184.1968. Os testes comprovam os dados
gravados e a integridade do conector, mas não comprovam que todas as regras do
executável SIC foram reproduzidas. Não existem procedures/triggers de negócio
nessa base. Tipo de entrada, custo médio, baixas de lotes, caixa, contas a receber,
comissões, usuário responsável e abertura da venda na tela nativa ainda devem
ser comparados com uma operação gerada pelo SIC original em laboratório.

Por isso, o executável recusa bancos fora de `LINEBOARD_LAB*`, exige marcador e
arquivos dentro de `.local/sic-lab`, e não possui opção de contornar essa proteção.
NF-e/NFC-e não são emitidas por esta implementação. Nenhum certificado, série,
numeração fiscal, XML ou credencial foi alterado. A API oficial de e-commerce
não está disponível pronta segundo a SICNET; o acionamento do motor fiscal deve
ser comprovado com mecanismo suportado antes de habilitar uso real.
