# Aceite operacional com projeto configurado

Os testes automatizados cobrem regras locais; esta lista verifica os serviços e
dispositivos reais. Não marcar como concluído sem executar.

- [ ] Administrador entra por link de convite e código; operador convidado entra
  e é vinculado à empresa certa. Convite expirado não concede acesso.
- [ ] Operador não consegue convidar nem criar integração, inclusive via RPC direta.
- [ ] Cadastrar camiseta com cores/medidas diferentes gera um código por variante.
- [ ] Cadastrar três pranchas individuais gera três códigos diferentes.
- [ ] Conferir produtos, variantes, saldo inicial e histórico no Supabase.
- [ ] Editar a ficha online atualiza o nome/descrição em todas as variantes sem
  alterar código ou quantidade. Edição não está disponível na ficha offline.
- [ ] Reiniciar o app após resposta perdida no cadastro recupera os mesmos códigos.
- [ ] Compartilhar PNG no Android e iPhone; imprimir sem cortar as margens e
  reconhecer o código físico pela câmera dos dois sistemas.
- [ ] Recusar/autorizar câmera, alternar app e voltar; entrada manual funciona.
- [ ] Venda física de várias peças baixa só após confirmação; conferir comprovante,
  `sales`, `sale_lines`, `stock_movements` e saldo final no banco.
- [ ] Derrubar a rede durante envio; reiniciar app e retomar a confirmação. A baixa
  deve existir uma única vez, com a mesma chave de operação.
- [ ] Duas sessões tentam vender a última unidade simultaneamente, uma física e
  outra pela API de e-commerce. Só uma vence; a outra recebe falta de estoque.
- [ ] Repetir a chamada da API com mesma chave/pedido retorna mesmo comprovante;
  outra chave com mesmo pedido deve ser rejeitada, sem novo desconto.
- [ ] Uma linha sem saldo desfaz toda a venda, inclusive linhas com saldo.
- [ ] Loja B não lê, modifica ou vende códigos/fotos da loja A, mesmo enviando IDs conhecidos.
- [ ] Sincronizar fichas, desligar rede e identificar um código: aviso offline sem
  saldo; cadastro e venda não mostram sucesso. Nova sessão sem cache não inventa dados.
- [ ] Logout apaga fichas; outro funcionário não vê operação pendente do anterior.
- [ ] Credencial revogada não consulta catálogo nem registra pedido.
- [ ] Conferir envio SMTP, limites do provedor, assinatura Android de produção e
  assinatura iOS antes de distribuir.
