import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'domain.dart';
import 'pending_store.dart';

abstract class LocalCredentials {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureLocalCredentials implements LocalCredentials {
  final FlutterSecureStorage storage = const FlutterSecureStorage();
  static const key = 'lineboard.local.pairing';
  @override
  Future<String?> read() => storage.read(key: key);
  @override
  Future<void> write(String value) => storage.write(key: key, value: value);
  @override
  Future<void> clear() => storage.delete(key: key);
}

class LocalApiError implements Exception {
  const LocalApiError(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'PAIRING_REFUSED' =>
      'Código de pareamento inválido ou expirado. Gere outro no desktop.',
    'UNAUTHORIZED' =>
      'O pareamento perdeu a validade. Conecte o celular novamente.',
    'ALREADY_IN_CART' => 'Essa peça já está no carrinho do desktop.',
    'SIC_STOCK_CONFLICT' =>
      'O estoque dessa peça mudou no SIC. Confira no desktop.',
    'INSUFFICIENT_STOCK' => 'Essa peça não está disponível para venda.',
    'BARCODE_NOT_FOUND' => 'Peça não encontrada neste computador.',
    'INVALID_LOCAL_ADDRESS' =>
      'Informe um endereço HTTP da rede local, como http://192.168.1.10:47831.',
    'NOT_PAIRED' => 'Pareie este celular com o desktop.',
    'PENDING_REQUEST' =>
      'Existe uma solicitação pendente. Retome antes de enviar outra.',
    'WRONG_INSTANCE' => 'O endereço está conectado a outra base. Pareie com o computador correto.',
    _ =>
      'A operação não foi confirmada ($code). Confira o desktop antes de reenviar.',
  };
}

class LocalGateway {
  LocalGateway(this.pending, this.credentials, {HttpClient? client})
    : _client = client ?? HttpClient();
  final PendingStore pending;
  final LocalCredentials credentials;
  final HttpClient _client;
  Uri? _base;
  String? _token;
  String? instanceId;
  bool get paired => _base != null && _token != null && instanceId != null;
  String get address => _base?.origin ?? '';

  static Uri localAddress(String value) {
    final uri = Uri.tryParse(value.trim());
    final ip = InternetAddress.tryParse(uri?.host ?? '');
    final bytes = ip?.rawAddress;
    final private =
        uri?.host == 'localhost' ||
        (bytes != null &&
            bytes.length == 4 &&
            (bytes[0] == 127 ||
                bytes[0] == 10 ||
                (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31)));
    if (uri == null ||
        uri.scheme != 'http' ||
        !private ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const LocalApiError('INVALID_LOCAL_ADDRESS');
    }
    return uri.replace(path: '/');
  }

  Future<void> restore() async {
    final saved = await credentials.read();
    if (saved == null) return;
    try {
      final value = jsonDecode(saved) as Map<String, dynamic>;
      _base = localAddress(value['address'] as String);
      _token = value['token'] as String;
      instanceId = value['instance_id'] as String;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(_token!) || instanceId!.isEmpty) {
        throw const FormatException();
      }
    } catch (_) {
      _base = null;
      _token = null;
      instanceId = null;
      await credentials.clear();
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool public = false,
    Uri? base,
    String? expectedInstance,
  }) async {
    final target = base ?? _base;
    if (target == null || (!public && !paired)) {
      throw const LocalApiError('NOT_PAIRED');
    }
    final request = await _client
        .openUrl(method, target.resolve(path))
        .timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    if (!public) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 25));
    if (!public &&
        response.headers.value('x-lineboard-instance') != instanceId) {
      await response.drain<void>();
      throw const LocalApiError('WRONG_INSTANCE');
    }
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 15));
    final value = Map<String, dynamic>.from(jsonDecode(text) as Map);
    if (response.statusCode != 200) {
      throw LocalApiError(
        value['error'] as String? ?? 'LOCAL_OPERATION_FAILED',
      );
    }
    if (expectedInstance != null && value['instance_id'] != expectedInstance) {
      throw const LocalApiError('WRONG_INSTANCE');
    }
    return value;
  }

  Future<void> pair(String address, String pin) async {
    final target = localAddress(address);
    final value = await _request(
      'POST',
      'api/pair',
      public: true,
      base: target,
      body: {
        'pin': pin.trim(),
        'name': Platform.isIOS ? 'Lineboard iPhone' : 'Lineboard Android',
      },
    );
    final token = value['token'] as String;
    final instance = value['instance_id'] as String;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(token) ||
        instance.isEmpty ||
        value['mode'] != 'sandbox') {
      throw const LocalApiError('INVALID_PAIRING_RESPONSE');
    }
    await credentials.write(
      jsonEncode({
        'address': target.origin,
        'token': token,
        'instance_id': instance,
      }),
    );
    _base = target;
    _token = token;
    instanceId = instance;
  }

  Future<void> unpair() async {
    await credentials.clear();
    _base = null;
    _token = null;
    instanceId = null;
  }

  String _key(String kind) {
    if (!paired) throw const LocalApiError('NOT_PAIRED');
    return 'lineboard.local.$instanceId.$kind';
  }

  Map<String, dynamic>? pendingRequest(String kind) {
    if (!paired) return null;
    final saved = pending.get(_key(kind));
    return saved == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(saved) as Map);
  }

  Future<Map<String, dynamic>> createProduct(
    Map<String, dynamic> fields,
  ) async {
    if (pendingRequest('product') != null) {
      throw const LocalApiError('PENDING_REQUEST');
    }
    final value = {...fields, 'request_id': const Uuid().v4()};
    await pending.put(_key('product'), jsonEncode(value));
    return retryProduct();
  }

  Future<Map<String, dynamic>> retryProduct() async {
    final saved = pendingRequest('product');
    if (saved == null) throw const LocalApiError('NO_PENDING_REQUEST');
    final value = await _request('POST', 'api/products', body: saved);
    await pending.remove(_key('product'));
    return value;
  }

  Future<Map<String, dynamic>> addCode(String code) async {
    if (!validBarcode(code)) throw const FormatException('INVALID_BARCODE');
    if (pendingRequest('scan') != null) {
      throw const LocalApiError('PENDING_REQUEST');
    }
    await pending.put(
      _key('scan'),
      jsonEncode({
        'request_id': const Uuid().v4(),
        'barcode': canonicalBarcode(code),
      }),
    );
    return retryScan();
  }

  Future<Map<String, dynamic>> retryScan() async {
    final saved = pendingRequest('scan');
    if (saved == null) throw const LocalApiError('NO_PENDING_REQUEST');
    final value = await _request('POST', 'api/cart/items', body: saved);
    await pending.remove(_key('scan'));
    return value;
  }

  Future<void> discard(String kind) => pending.remove(_key(kind));
  Future<CatalogItem> lookup(String code) async =>
      CatalogItem(await _request('GET', 'api/units/${canonicalBarcode(code)}'));
  Future<Map<String, dynamic>> cart() => _request('GET', 'api/cart');
  void close() => _client.close(force: true);
}
