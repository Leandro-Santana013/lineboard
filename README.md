# Lineboard

## Baixar o Lineboard para Windows

A página pública de download fica em
`https://leandro-santana013.github.io/lineboard/`. O instalador oficial é
publicado nas [GitHub Releases](https://github.com/Leandro-Santana013/lineboard/releases)
e o botão da página sempre aponta para a versão estável mais recente.

Para publicar uma nova versão, crie uma tag semântica, por exemplo:

```bash
git tag v1.0.0
git push origin v1.0.0
```

O workflow do GitHub Actions compila o instalador em Windows e anexa
`Lineboard-Setup.exe` à release. A página é publicada automaticamente a cada
alteração em `main`.

### Versão 0.2.5 (Windows)

A ativação salva a configuração na pasta do usuário quando o Windows bloqueia
a gravação em ProgramData. A gravação é atômica e preserva o arquivo anterior
se ocorrer uma falha. Não é necessário executar o aplicativo como administrador.

### Versão 0.2.4 (Windows)

O caixa recebe as leituras do celular automaticamente mesmo nas instalações
sem chave Realtime. Uma consulta leve verifica a versão do carrinho a cada
3 segundos e solicita a sincronização quando houver mudanças. Instale a nova
versão sobre a anterior para preservar a ativação e a configuração da loja.
O APK Android continua na versão 0.2.3.

### Versão 0.2.3

Inclui desconto em porcentagem ou reais no pagamento, com total líquido no
SICNET e nos eventos sincronizados; etiquetas ampliadas; confirmação de reversão
dentro da interface; e melhorias de fotos no desktop e no celular. O APK Android
ARM64 também está disponível na página de download. Instaladores e APKs ficam
nas Releases; credenciais, bases locais e relatórios temporários de build não
fazem parte do código versionado.

Gerenciamento Windows integrado ao banco local do SIC, com Flutter Android/iOS
para cadastro, etiquetas e leitura remota do caixa, e sincronização com Supabase.
Cada peça física possui um código interno Code 128 exclusivo. O celular envia
leituras ao carrinho; a confirmação e a baixa acontecem no desktop.

**Estado em 31/10/2026:** desktop React/Mantine integrado ao conector SIC em
um único executável, `desktop/bin/Lineboard.exe`. Ele abre o `SICNET` local por
padrão; `desktop/scripts/start.ps1 -Lab` usa o mesmo executável com
`LINEBOARD_LAB`. Uma importação controlada levou os 57 produtos e seus recebimentos
da cópia `LINEBOARD_LAB` para a base demonstrativa `SICNET`, com backup COPY_ONLY
antes da gravação. A ponte Supabase foi ativada para esta instalação; o
acionamento fiscal continua dependente de homologação própria.

Instruções completas e limites em [desktop/README.md](desktop/README.md).

```powershell
# Na raiz, nesta máquina (LINEBOARD_LAB já preparado):
.\desktop\scripts\build.ps1
.\desktop\scripts\start.ps1

# O modo padrao usa o SICNET; para laboratorio use -Lab.

# Em outro PC, uma unica vez: pede o token sem exibi-lo, configura o usuario
# do Windows e importa todos os registros atuais do Supabase.
.\desktop\scripts\configure-cloud.ps1

# Nova cópia isolada e testes SQL Server reais:
.\desktop\scripts\test.ps1

cd mobile
flutter run --dart-define=LINEBOARD_MODE=cloud --dart-define-from-file=config.json
```

## Adaptador Linux

O cliente Linux fica em [linux/README.md](linux/README.md). Ele autentica uma
instalação cloud, importa o snapshot por `sic-sync` e reage ao Supabase Realtime
sem polling. Por enquanto é um adaptador cloud/read-only: o conector SICNET,
escrita fiscal e confirmação de venda continuam no desktop Windows.

No modo de producao, cada cadastro e venda entra diretamente no `SICNET` local
em uma transacao atomica; a importacao inicial dos produtos nao e repetida para
as operacoes novas.

```mermaid
flowchart LR
  M[Flutter no Wi-Fi: cadastro e leitura] --> W[Windows: conector e caixa]
  W --> S[(SQL Server local do SIC)]
  SIC[SIC original] --> S
  W --> Q[Fila persistente e sincronização]
  Q --> B[(Supabase)]
  E[E-commerce futuro] --> B
```

## Executar o fluxo Supabase anterior (modo cloud)

Requisitos: Flutter 3.47.1 / Dart 3.13.1 (versões usadas neste projeto), Android
SDK 36 e Java 17. Para iOS: macOS, Xcode e assinatura Apple; alvo iOS 15+.
O Flutter usado aqui solicita NDK `28.2.13676358`.

Se o novo Android CLI no Windows mostrar `Package ndk not found` durante a
instalação automática, instale a versão antes de compilar:

```powershell
& "$env:ANDROID_HOME\cmdline-tools\latest\bin\android.exe" --sdk $env:ANDROID_HOME sdk install ndk/28.2.13676358
```

```powershell
cd mobile
flutter pub get
Copy-Item config.example.json config.json
# Preencha a URL e a chave publishable/pública no config.json.
flutter run --dart-define=LINEBOARD_MODE=cloud --dart-define-from-file=config.json
```

Sem configuração, o app abre uma tela explicando a conexão pendente, sem catálogo
de demonstração ou operações falsas. `config.json` é ignorado pelo Git. A chave
`service_role` fica apenas nas funções do Supabase, nunca no Flutter.

## Preparar Supabase

1. Crie um projeto dedicado. Execute `supabase login`,
   `supabase link --project-ref SEU_PROJECT_REF` e `supabase db push` na raiz.
   Alternativamente, execute a migration de `supabase/migrations` no editor SQL.
2. Desative cadastro público em Authentication. Configure a URL de redirecionamento
   `io.lineboard.mobile://login-callback` na lista permitida.
3. O app aceita o código ou o link de login aberto no próprio celular. No plano
   Free com provedor de e-mail padrão, mantenha os templates padrão: o Supabase
   recusa personalização. Os templates de `supabase/templates` podem ser usados
   depois de configurar SMTP próprio. O provedor padrão restringe envio aos
   membros da equipe do projeto; SMTP para os demais usuários segue pendente.
4. Convide o primeiro administrador no painel Authentication > Users e execute
   `docs/bootstrap.sql`, substituindo o e-mail e o nome da loja. Repita apenas para
   novas empresas. O app não oferece criação pública de empresas.
5. Publique `supabase functions deploy invite-member commerce sic-sync sic-command-ack activate-desktop product-photos --use-api`
   e aplique também a migration `202610310001_sic_command_bridge.sql`.
   As chaves internas padrão do Supabase
   são disponibilizadas pelo runtime (`SUPABASE_PUBLISHABLE_KEYS` e
   `SUPABASE_SECRET_KEYS`); nenhum segredo precisa ir para o app. Runtimes locais
   antigos que usam `SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY` também funcionam.
6. Preencha `mobile/config.json` com a URL e a chave pública do projeto. Entre com
   o administrador e convide operadores no ícone de equipe.

### Ativação automática do desktop

Depois de aplicar a migration `202611070001_desktop_activation.sql` e publicar
`activate-desktop`, o administrador gera um código temporário para cada
computador. O código bruto aparece somente uma vez e não é salvo no banco:

O jeito mais simples no Windows é usar o script PowerShell abaixo. Ele não
exige Node.js, npm nem instalação de pacotes: faz o login por código de e-mail
e gera o código de ativação no próprio computador administrativo. Não precisa
ser executado no computador da loja.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\create-activation.ps1
```

O script pede somente a chave pública do Supabase na primeira execução, o
e-mail do administrador e o código recebido por e-mail. O `ADMIN_ACCESS_TOKEN`
fica apenas na memória durante a execução e não é salvo em arquivo.

No Linux, use a versão Bash, também sem Node.js:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Leandro-Santana013/lineboard/main/scripts/create-activation.sh \
  -o /tmp/lineboard-create-activation.sh
bash /tmp/lineboard-create-activation.sh
```

```bash
SUPABASE_URL="https://<projeto>.supabase.co" \
SUPABASE_PUBLISHABLE_KEY="<chave-publica>" \
ADMIN_ACCESS_TOKEN="<JWT-do-administrador>" \
ORGANIZATION_ID="<id-da-loja>" \
node scripts/create-activation.mjs "Computador do caixa" 1 24
```

No instalador novo, abra **Configurações**, informe o código e reinicie o
Lineboard. A aplicação grava a configuração no Windows, cria a credencial da
instalação e importa automaticamente os dados da loja; não é necessário rodar
`configure-cloud.ps1` nessa máquina.

As funções têm `verify_jwt=false` intencionalmente: `invite-member` valida o JWT
com `auth.getUser()` e depois a permissão no banco; `commerce` valida uma
credencial própria por empresa; `sic-command-ack` valida a credencial de
integração do desktop. Todas recusam chamadas sem autenticação válida.

### Fotos no Cloudflare R2

As Edge Functions usam R2 quando os secrets abaixo estao configurados no projeto
Supabase. As chaves nunca entram no APK, no desktop ou no instalador:

```text
R2_ACCOUNT_ID
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
R2_BUCKET
R2_ENDPOINT
R2_REGION=auto
```

Crie temporariamente `.local/r2.env` (esta pasta e ignorada pelo Git) com:

```text
R2_ACCOUNT_ID=<account-id>
R2_ACCESS_KEY_ID=<access-key-id>
R2_SECRET_ACCESS_KEY=<secret-access-key>
R2_BUCKET=<bucket>
R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
R2_REGION=auto
```

Configure os secrets no projeto conectado, publique as duas funcoes e remova o arquivo local:

```powershell
supabase secrets set --env-file .local/r2.env
supabase functions deploy product-photos sic-sync --use-api
Remove-Item -LiteralPath .local/r2.env
```

Sem esses secrets, o fluxo continua usando o bucket privado `product-photos` do
Supabase. Com R2 configurado, novos uploads vao para o bucket R2 e URLs antigas
do Supabase continuam sendo lidas durante a migracao.

## Fluxo operacional no mobile/Supabase

- **Cadastrar produto**: nome, categoria, marca, modelo, custo, preço, cor/medida
  por variante, controle por quantidade ou por unidade, quantidade inicial, foto e
  observações. Em uma loja vinculada ao SIC, o comando vai para `sic_commands`;
  o desktop gera os códigos e devolve as etiquetas após a confirmação local.
- **Etiqueta**: abra um código após o cadastro ou escaneie uma etiqueta existente.
  Compartilhe a imagem PNG pelo Android/iOS para o fluxo de impressão da loja.
- **Editar ficha**: na identificação online, atualize nome, categoria, marca,
  modelo e observações. Códigos, variantes e saldos são preservados.
- **Registrar saída**: escaneie os produtos vendidos, confira quantidades e confirme
  a venda física. Um comprovante só aparece após a confirmação do desktop pela fila.
- **Retomar operação**: em resposta incerta, a solicitação fica em SQLite, separada
  por usuário/empresa. Reenvios usam o mesmo identificador. Reabrir o app e entrar
  com o mesmo usuário permite recuperar o resultado.
- **Identificar offline**: fichas previamente sincronizadas podem ser abertas por
  código sem rede, com aviso de possível desatualização. Não incluem saldo nem
  imagens offline. Cadastro e saída não são confirmados offline; não há fila que
  venda automaticamente depois de reconectar.

Admin e operador podem cadastrar e vender. Só admin convida funcionários e
gerencia credenciais de integração. RLS, FKs compostas por organização e RPCs
com verificação de acesso isolam as lojas. Usuários podem pertencer a mais de uma
loja. Logout apaga fichas locais; operações ainda não resolvidas permanecem
reservadas ao mesmo usuário para recuperação após novo login.

## Integração futura

Contrato, autenticação, exemplos e limites em [docs/commerce-api.md](docs/commerce-api.md).
O desktop local está em `desktop/`; a ponte SIC → Supabase usa a migration
`202610280001_sic_bridge.sql` e a função `sic-sync`, publicadas em 31/10/2026.
O e-commerce terá backend/frontend próprios futuramente e está fora desta
etapa. O retorno de pedidos remotos para o SIC ainda não foi implementado.

## Verificar e compilar

```powershell
# Raiz: executa a migration real num PostgreSQL WASM e testa transações/RLS.
npm ci
npm test
npm run test:postgres

# Funções TypeScript
npx -y deno check --config supabase/functions/deno.json supabase/functions/commerce/index.ts supabase/functions/invite-member/index.ts
npx -y deno test --config supabase/functions/deno.json supabase/functions/_shared/environment_test.ts

cd mobile
flutter analyze
flutter test
flutter build apk --debug --dart-define-from-file=config.json
# Em um Mac:
flutter build ios --no-codesign --dart-define-from-file=config.json
```

A suíte SQL usa PGlite com stubs apenas de `auth`/`storage`; executa as tabelas,
políticas e funções da migration sem reimplementar as regras em JavaScript.
O teste `test:postgres` cria um cluster temporário PostgreSQL nativo e disputa a
última unidade em conexões separadas, além de reenviar a mesma venda em paralelo.
O cluster é encerrado e removido ao finalizar. Não substitui validação de
Auth/SMTP, Storage e dispositivos num Supabase real.
Antes de uso operacional, execute [docs/acceptance.md](docs/acceptance.md) em
Android e iPhone com um projeto configurado. O APK debug sem chaves serve para
verificar a compilação e só mostra a tela de configuração.

Android release ainda usa a chave debug do scaffold; configure um keystore
próprio antes de distribuir pela loja. iOS precisa de assinatura e testes em
Mac/iPhone. Este projeto não inclui pagamento, reservas de checkout, estorno,
reposições, inventário ou faturamento no fluxo Supabase anterior. O novo Windows
oferece ajustes de estoque somente em laboratório, sem processamento de pagamento
ou emissão fiscal.

Referências usadas: [funções PostgreSQL no Supabase](https://supabase.com/docs/guides/database/functions),
[Supabase Flutter](https://pub.dev/packages/supabase_flutter),
[leitura por câmera](https://pub.dev/packages/mobile_scanner) e
[compartilhamento nativo](https://pub.dev/packages/share_plus).
