import 'dart:convert';

class CatalogItem {
  const CatalogItem(this.data);
  final Map<String, dynamic> data;
  String get barcode => data['barcode'] as String;
  String get name => data['name'] as String;
  String get tracking => data['tracking'] as String;
  String get variant => [
    data['color'],
    data['size'],
  ].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
  String get productId => data['product_id'] as String;
}

class SaleLine {
  SaleLine(this.item, this.quantity);
  final CatalogItem item;
  int quantity;
  Map<String, dynamic> toJson() => {
    'barcode': item.barcode,
    'quantity': quantity,
  };
}

class SaleBasket {
  final List<SaleLine> lines = [];
  void add(CatalogItem item) {
    final index = lines.indexWhere((e) => e.item.barcode == item.barcode);
    if (index < 0) {
      lines.add(SaleLine(item, 1));
    } else {
      if (item.tracking == 'individual') {
        throw StateError('Esta unidade já está na venda.');
      }
      lines[index].quantity++;
    }
  }

  List<Map<String, dynamic>> toJson() => lines.map((e) => e.toJson()).toList();
}

class PendingSale {
  PendingSale({
    required this.key,
    required this.lines,
    required this.reference,
  });
  final String key;
  final List<Map<String, dynamic>> lines;
  final String reference;
  Map<String, dynamic> toJson() => {
    'key': key,
    'lines': lines,
    'reference': reference,
  };
  factory PendingSale.fromJson(Map<String, dynamic> value) => PendingSale(
    key: value['key'] as String,
    lines: (value['lines'] as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList(),
    reference: value['reference'] as String,
  );
}

bool validBarcode(String value) =>
    RegExp(r'^SLB-\d{12}$').hasMatch(value.trim().toUpperCase());
String canonicalBarcode(String value) => value.trim().toUpperCase();
String encodeJson(Object value) => jsonEncode(value);

String friendlyError(Object error) {
  final message = error.toString();
  const translations = {
    'otp_disabled': 'OTP desativado no Supabase. Ative o provedor de e-mail ou use a ativacao do aparelho.',
    'email_provider_disabled': 'Provedor de e-mail desativado no Supabase. Ative-o antes de solicitar um codigo.',
    'Signups not allowed for otp': 'OTP desativado no Supabase. Ative o provedor de e-mail ou use a ativacao do aparelho.',
    'LOCAL_CATALOG_REQUIRED':
        'Esta loja usa o SIC local. Cadastre pelo modo de conexão ao desktop.',
    'DESKTOP_CONFIRMATION_REQUIRED':
        'Confira e confirme esta venda no aplicativo desktop.',
    'CHECKOUT_IN_PROGRESS':
        'Um computador está confirmando esta compra. Aguarde a conclusão.',
    'CART_CHANGED':
        'O carrinho da loja mudou. Atualize e confira os itens novamente.',
    'SESSION_CHANGED':
        'Sua sessão mudou. Entre novamente antes de retomar a operação.',
    'INSUFFICIENT_STOCK': 'Saída recusada: um dos itens não está disponível. Confira no sistema Windows.',
    'BARCODE_NOT_FOUND': 'Código não encontrado nesta loja.',
    'IDEMPOTENCY_CONFLICT': 'Esta operação já foi enviada com outros dados. Confira antes de tentar novamente.',
    'SIC_COMMAND_FAILED': 'O computador da loja não confirmou a operação. Retome para conferir o resultado.',
    'SIC_STOCK_CONFLICT':
        'O estoque do computador mudou. Confira a operação no desktop.',
    'SIC_CONNECTION_NOT_REGISTERED':
        'O computador da loja ainda não está conectado ao Supabase.',
    'PRICE_REQUIRED': 'Informe um preço de venda antes de concluir.',
    'INVALID_PAYMENT': 'Escolha uma forma de pagamento válida.',
    'FORBIDDEN': 'Seu acesso a esta loja não permite essa operação.',
    'ALREADY_MEMBER': 'Este e-mail já pertence à equipe.',
    'EMAIL_DELIVERY_FAILED':
        'Não foi possível enviar o e-mail. Tente reenviar em instantes.',
    'INVALID_QUANTITY': 'Confira as quantidades informadas.',
    '23505':
        'Registro repetido. Confira as variantes ou a referência da venda.',
    'SocketException': 'Sem conexão. Nenhuma operação foi confirmada.',
    'TimeoutException': 'O servidor não respondeu. Retome a operação para confirmar o resultado com segurança.',
    'invalid_credentials': 'Confira o e-mail e o código de acesso.',
    'otp_expired': 'O código expirou ou é inválido. Solicite outro.',
  };
  for (final entry in translations.entries) {
    if (message.contains(entry.key)) return entry.value;
  }
  return 'Não foi possível concluir. Confira sua conexão e tente novamente.';
}
