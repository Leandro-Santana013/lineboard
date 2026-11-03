# Fotos de produtos no desktop e no aplicativo

## Comportamento

- Uma imagem opcional por produto, compartilhada pelas cores, tamanhos e peças.
- Selecionar, visualizar, substituir e remover a foto ao cadastrar ou editar.
- JPG/JPEG (`.jpg` e `.jpeg`), PNG e WebP, até 5 MB. No celular, galeria ou câmera.
- Envio online ao bucket privado `product-photos` já existente. Referências estáveis
  `organizacao/arquivo.ext` ficam nos cadastros; URLs temporárias servem somente à exibição.
- No desktop e no celular pareado, a credencial de integração fica no processo nativo.
  O frontend recebe somente a referência e a URL temporária da foto.
- Sem foto ou sem conexão, consulta e etiquetas continuam disponíveis. A etiqueta
  de código de barras não passa a incluir a imagem do produto.
- Não apagar imagens antigas automaticamente: respostas incertas e operações em
  recuperação podem continuar usando essas referências.

## Etapas

1. Armazenamento e autorização: upload autenticado pelo desktop, validação de
   arquivo, URLs assinadas e proteção entre organizações.
2. Cadastro e sincronização: preservar `photo_path` no comando mobile/SIC;
   publicar a imagem no catálogo e propagar trocas/remoções aos desktops.
3. Interface desktop: seletor de arquivo, prévia e remoção no cadastro/edição.
4. Interface mobile: reutilizar seleção/upload, adicionar prévia e edição;
   oferecer o mesmo fluxo ao celular pareado.
5. Verificação: testes de contrato, frontend, Flutter e SQL reais em ambiente
   isolado, sem cadastrar produtos na base operacional.

## Publicação e aceite

Aplicar a nova migration e publicar `sic-sync` no Supabase antes de distribuir
os binários atualizados. Depois validar seleção/câmera em Android e o fluxo
desktop → aplicativo → desktop com duas sessões da mesma loja. Compilação e
testes locais não comprovam armazenamento remoto nem câmera física.

Ordem de publicação:

1. Aplicar `202611020005_product_photos.sql` com as migrations anteriores.
2. Publicar `supabase functions deploy sic-sync --use-api`.
3. Executar `desktop/scripts/build.ps1` com o Lineboard fechado. O script compila
   a interface e o executável e instala o conjunto completo. A cópia de validação inicial foi compilada separadamente em
   `.local/product-photos-desktop/Lineboard.exe` porque a instalação atual estava aberta.
4. Compilar e instalar o aplicativo atualizado no modo cloud. A escolha de imagens
   no modo pareado também precisa do desktop atualizado e da integração configurada.
5. Testar cadastro com foto, troca, remoção e sincronização entre dispositivos da
   mesma loja. Confirmar que outra loja não consegue ler a imagem.

## Validação local em 02/11/2026

- 36 testes Node/SQL passaram, incluindo isolamento, limites de upload,
  projeção no catálogo, remoção, repetição e foto trocada durante sincronização inicial.
- 18 testes React passaram; build de produção do frontend concluído com Node 24.
- 24 testes Flutter passaram e `flutter analyze --no-pub` terminou sem problemas.
- 36 verificações C# passaram no SQL Express, em `LINEBOARD_LAB_BRIDGE2bc9e52ffd88`.
  A suíte confirmou que o SICNET original permaneceu inalterado.
- Executável Windows compilado na cópia de validação; `deno check` de `sic-sync` passou.

Não houve publicação no Supabase, instalação de APK ou aceite em aparelho físico.
O limite dos subagentes interrompeu a revisão independente; o agente principal
revisou e integrou o código e executou as verificações acima.

## Correção e publicação em 02/11/2026

O erro `UNKNOWN_ACTION` ao escolher um JPG foi reproduzido no executável antigo
de `desktop/bin`, usando o mesmo arquivo informado pelo usuário. A interface
fora atualizada sozinha, enquanto o processo nativo ainda era da versão anterior.

- O build independente do frontend agora escreve em `desktop/obj/ui`.
- `build.ps1` prepara interface, dependências e executável juntos, testa o comando
  `photo.upload`, exige o programa fechado e preserva a instalação anterior.
- A instalação anterior está em
  `.local/desktop-build/856708e4c2c74c8fa879218b571fab96/previous`.
- Após autorização do usuário, a migração `202611020005` foi aplicada em uma
  transação e somente `sic-sync` foi publicada no projeto `isktnezzanqpcrkkqldw`.
  As funções anteriores foram salvas em `.local/photo-fix-publication-backup`.
- O desktop foi instalado no caminho normal e reiniciado com os mesmos argumentos.
- 22 testes React e 36 testes Node/SQL passaram. O teste isolado do comando nativo
  passou tanto com o JPG do usuário quanto com o JPEG gerado pela suíte.
- Após autorização específica para enviar o arquivo, o teste online pelo código
  nativo instalado confirmou upload de 452.996 bytes, download assinado com
  SHA-256 idêntico e bloqueio do acesso anônimo. Nenhum produto foi alterado.

O teste reproduzível é `desktop/scripts/test-photo-upload.ps1 -ImagePath CAMINHO`,
que usa o comando nativo real e substitui somente o transporte remoto. A evidência
do teste online está em `.local/photo-fix-live-check.json`, sem URLs assinadas nem
credenciais. Atualização do APK e aceite da câmera física continuam separados.
