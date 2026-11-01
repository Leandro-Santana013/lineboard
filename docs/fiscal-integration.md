# Integração fiscal SIC / Lineboard — 31/10/2026

## Escopo confirmado

- Loja em São Paulo; integrar NF-e modelo 55 e NFC-e modelo 65.
- A nova interface Lineboard será o ponto de operação da emissão fiscal. O SIC
  permanece como retaguarda comercial/estoque quando necessário; o operador não
  precisa abrir a tela antiga para pedir a nota.
- O usuário informou que há uma impressora ao lado do computador. Ainda não
  foi confirmado se os documentos atuais são notas autorizadas ou comprovantes.
  A existência da impressora não confirma que a emissão esteja configurada.

## Inspeção desta máquina

- SIC 6.0.184.1968 encontrado em `C:\SICNET\SIC\sic.exe`.
- Nenhum executável dos módulos emissores foi localizado nas pastas SIC
  pesquisadas nem no cadastro de programas da SICNET do Windows.
- A conexão `SICNET` aponta à base demonstrativa. A tabela `TABNFCE` existe,
  com referência à venda em `lkest3a`, chave, ambiente, XML, recibo, flags de
  emissão/cancelamento e `cstat`. Sua existência não prova emissão automática.
- Nenhum certificado vigente com chave privada foi encontrado nos repositórios
  pessoais do Windows consultados. Isso não verifica arquivos PFX externos,
  tokens desconectados nem certificados configurados em outra máquina.
- A consulta de impressoras nesta sessão ficou indisponível; isso não contradiz
  a presença física informada pelo usuário.
- As ferramentas de inspeção da janela do SIC falharam por indisponibilidade do
  helper do Windows. Não houve simulação de cliques nem alteração da configuração.
- O SIC original permaneceu somente leitura. Nenhuma transmissão fiscal ocorreu.

Diagnóstico repetível, inclusive na instalação da loja:

```powershell
.\desktop\scripts\probe-fiscal.ps1 -Output .local\fiscal-readiness.json
# Se os programas estiverem em outra pasta:
.\desktop\scripts\probe-fiscal.ps1 -AdditionalRoots 'D:\PastaDoEmissor'
```

O diagnóstico não exporta certificados, senhas, CSC, XML nem dados de clientes.
Nomes de executáveis são apenas candidatos; é necessário confirmar a interface
suportada pelo fabricante antes de implementar o acionamento.

## Caminho necessário para emissão real

1. Confirmar certificado, credenciamento, CSC/ID da NFC-e e parâmetros da
   empresa. A loja deve confirmar os dados tributários com seu contador; o
   Lineboard não deve inventá-los.
2. Escolher o transporte fiscal local que a nova interface acionará: um
   adaptador próprio para a SEFAZ ou o emissor licenciado já usado pela loja.
   Nenhuma API fiscal nem contrato de automação foi confirmado nesta inspeção.
3. Implementar o adaptador local e o acompanhamento persistente da solicitação,
   sem enviar certificado ou segredo ao Supabase.
   Uma resposta perdida fica pendente de consulta; não dispara outra nota.
4. Validar em homologação a emissão, rejeição, consulta, recuperação após
   interrupção e obtenção de chave/protocolo/XML/DANFE para os dois modelos.
5. Liberar produção somente com a instalação real configurada e o fluxo
   comprovado. Neste momento, o executável continua restrito a laboratório.

## Comportamento esperado no Lineboard

- O checkout já permite escolher NFC-e (modelo 65) ou NF-e (modelo 55). A venda
  fica com `fiscal_status=pending_adapter` até o adaptador fiscal local retornar
  autorização; isso não representa uma nota autorizada.
- O operador escolhe o documento apropriado à operação; escolher suporte aos
  dois modelos não significa emitir os dois automaticamente para cada venda.
- Cada solicitação tem identificação persistente vinculada à venda e ao modelo.
- Distinguir venda registrada, nota solicitada, autorização pendente, autorizada,
  rejeitada e cancelada. Um comprovante não será apresentado como DANFE.
- Mostrar autorização somente após receber e conferir o resultado do emissor.
  Reiniciar o aplicativo não deve duplicar nota nem movimentação de estoque.
- Certificado e segredos ficam com o emissor local; a emissão não é transferida
  para o Supabase. Publicar funções no Supabase não habilita emissão fiscal.

## Referências oficiais consultadas

- NF-e e download do módulo: https://www.sicnet.com.br/nfe/
- NFC-e e download do módulo: https://www.sicnet.com.br/nfce/
- Configuração da NFC-e em SP: https://www.sicnet.com.br/sat/
- Suporte e módulos: https://www.sicnet.com.br/suporte/faq/

**Estado: interface de solicitação implementada; transmissão e autorização fiscal ainda não implementadas.**
