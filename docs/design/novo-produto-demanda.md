# Demanda aprovada: cadastro de Novo produto

Usuário aprovou a proposta visual em `novo-produto-aprovado.png` e pediu delegar
a implementação a um modelo Luna. A imagem é a referência principal de composição.

## Resultado esperado

Implementar o cadastro desktop conforme a imagem: dados básicos, grade e resumo
visíveis juntos. O operador informa produto, preços, cores, tamanhos e quantidades;
os códigos individuais são gerados pelo sistema ao salvar. Não exigir conhecimento
de banco, infraestrutura ou momento de sincronização.

- Manter o visual azul escuro, fundo claro e ações em verde petróleo do desktop.
- Cadastro principal: nome, marca opcional, código interno opcional, custo e venda.
- Grade editável: cor, tamanho e quantidade, adicionar/remover variação e controles
  simples de quantidade; salvar o valor da célula em edição antes de validar.
- Resumo em tempo real: nome, preço por peça, número de variações e total de peças.
  Uma grade com Preta/M/2, Preta/G/1, Branca/M/1 mostra 3 variações e 4 peças.
- Explicar que cada peça recebe seu próprio código. Não consumir uma sequência
  nem cadastrar registros para desenhar a prévia. A etiqueta ilustrativa deve ser
  identificada como exemplo e não representar um código emitido antecipadamente.
- Informações adicionais recolhidas: localização, referência de foto existente,
  observações e os campos fiscais suportados. Preservar todos os campos do modelo.
- Ações claras: cancelar/voltar sem gravar; cadastrar usando os serviços existentes.
- Evitar perda de campos se trocar seções ou recolher os adicionais.
- Dados reais apenas ao salvar uma solicitação válida; preservar idempotência,
  códigos fixos por peça, preço brasileiro e validações de campos/quantidades.
- Adaptar o layout à janela do usuário (aproximadamente 1224 × 794). Campos não
  podem desaparecer atrás das ações. Usar rolagem onde necessário.

## Código e limites

Workspace Windows: `C:\Users\Santana\Documents\GitHub\skus-lineboard`.
Aplicativo WinForms/.NET Framework, compilado com csc do Windows, sem instalar SDK.
Fontes em `desktop/src`; tema em `DesktopTheme.cs`; `DesktopForm.cs` contém
`FieldsDialog`, chamado por `Create()` e `Edit()`. Pode extrair o cadastro para um
arquivo próprio para manter a manutenção clara. Preservar a edição individual.

O desktop, SIC e API LAN já existem. Não substituir por site, Flutter, Tauri ou
outro backend. Não mudar `SicStore`/schema sem uma necessidade comprovada.
Banco operacional SICNET é somente leitura para este trabalho. Testes de escrita
usam cópias guardadas `LINEBOARD_LAB*`, criadas pelo script existente. O banco de
trabalho LINEBOARD_LAB está vazio e não deve receber os produtos de demonstração.

O menu Conexões já foi removido: configurações secundárias guardam o pareamento
do celular e suporte. `BackgroundSync.cs` faz atualização automática com novas
tentativas; não reintroduzir sincronização manual no fluxo do operador. Integração
remota e emissão fiscal continuam pendentes; não alegar que estão publicadas.

## Verificação e entrega

1. Inspecionar a imagem aprovada antes de implementar.
2. Executar `desktop/scripts/test-ui.ps1`, adaptando os testes relevantes ao novo
   cadastro. Atualmente são 32 verificações, incluindo menu e atualização automática.
3. Validar criação real em laboratório dedicado com a grade de 3 variações / 4
   peças; comparar resumo, quatro códigos distintos e dados persistidos. Verificar
   cancelamento, campos inválidos, campos fiscais e edição individual.
4. Renderizar e inspecionar a tela preenchida e vazia, em tamanho normal e reduzido.
   Usar o próprio WinForms/DrawToBitmap; o helper de controle interativo do Windows
   está indisponível (`native pipe is unavailable`). Não alegar teste manual.
5. Compilar somente `desktop/bin/Lineboard.exe` com `desktop/scripts/build.ps1`.
   O executável entregue é `desktop/bin/Lineboard.exe`. Não comitar/publicar por
   conta própria; este diretório atualmente nem tem metadados Git.
6. Atualizar `docs/implementation-status.md` e documentação do fluxo se necessário.
   Informar arquivos alterados, resultados, captura e limitações ao agente principal.

Os 41 testes do conector passaram nesta sessão antes desta demanda; repetir se a
implementação modificar contratos ou comportamento de persistência. A GUI atual
foi recompilada e a versão anterior preservada em `.local/desktop-backups`.
