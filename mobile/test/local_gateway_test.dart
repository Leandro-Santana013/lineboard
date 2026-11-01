import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lineboard_mobile/local_app.dart';
import 'package:lineboard_mobile/local_gateway.dart';
import 'package:lineboard_mobile/pending_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MemoryCredentials implements LocalCredentials {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String data) async {
    value = data;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class DirectNetwork extends HttpOverrides {}

LocalGateway testGateway(PendingStore pending, LocalCredentials credentials) =>
    LocalGateway(
      pending,
      credentials,
      client: DirectNetwork().createHttpClient(null),
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  const instance = 'a73e80e0-3679-4d99-a0cb-2bbcaa95a608';

  test(
    'only direct local addresses are accepted, without embedded credentials',
    () {
      expect(
        LocalGateway.localAddress('http://192.168.1.5:47831').host,
        '192.168.1.5',
      );
      for (final address in [
        'http://example.com',
        'http://8.8.8.8',
        'https://192.168.1.5',
        'http://user:password@192.168.1.5',
        'http://192.168.1.5/api',
        'http://192.168.1.5?token=x',
      ]) {
        expect(
          () => LocalGateway.localAddress(address),
          throwsA(isA<LocalApiError>()),
        );
      }
    },
  );

  test('product retry survives SQLite reopen and reuses exact request and unit codes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Map<String, dynamic>>[];
    final token = List.filled(64, 'a').join();
    var fail = true;
    server.listen((request) async {
      final body = request.method == 'POST'
          ? Map<String, dynamic>.from(
              jsonDecode(await utf8.decoder.bind(request).join()),
            )
          : <String, dynamic>{};
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('X-Lineboard-Instance', instance);
      if (request.uri.path == '/api/pair') {
        request.response.write(
          jsonEncode({
            'token': token,
            'instance_id': instance,
            'mode': 'sandbox',
          }),
        );
      } else {
        expect(request.headers.value('authorization'), 'Bearer $token');
        expect(request.uri.path, '/api/products');
        requests.add(body);
        if (fail) {
          request.response.statusCode = 500;
          request.response.write('{"error":"LOCAL_OPERATION_FAILED"}');
        } else {
          request.response.write(
            jsonEncode({
              'product_id': 'p',
              'units': [
                {'barcode': 'SLB-900000000001'},
              ],
              'replayed': true,
            }),
          );
        }
      }
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'lineboard-local-retry-',
    );
    final path = '${directory.path}/operations.db';
    final credentials = MemoryCredentials();
    var pending = await PendingStore.open(path: path);
    var gateway = testGateway(pending, credentials);
    try {
      await gateway.pair('http://127.0.0.1:${server.port}', '123456');
      await expectLater(
        gateway.createProduct({
          'name': 'Camiseta',
          'variants': [
            {'color': 'Preta', 'size': 'M', 'quantity': 1},
          ],
        }),
        throwsA(isA<LocalApiError>()),
      );
      expect(gateway.pendingRequest('product'), isNotNull);
      expect(
        pending.values.values.any((value) => value.contains(token)),
        isFalse,
      );
      gateway.close();
      await pending.database.close();
      pending = await PendingStore.open(path: path);
      gateway = testGateway(pending, credentials);
      await gateway.restore();
      fail = false;
      final result = await gateway.retryProduct();
      expect((result['units'] as List).single['barcode'], 'SLB-900000000001');
      expect(requests.length, 2);
      expect(requests[0], requests[1]);
      expect(gateway.pendingRequest('product'), isNull);
    } finally {
      gateway.close();
      await pending.database.close();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test(
    'scanner retries the same request and never calls a sale endpoint',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      final bodies = <Map<String, dynamic>>[];
      var fail = true;
      server.listen((request) async {
        paths.add(request.uri.path);
        bodies.add(
          Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(request).join()),
          ),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('X-Lineboard-Instance', instance);
        request.response.statusCode = fail ? 500 : 200;
        request.response.write(
          fail
              ? ' {"error":"LOCAL_OPERATION_FAILED"}'
              : '{"added":"SLB-900000000001","version":1}',
        );
        await request.response.close();
      });
      final credentials = MemoryCredentials()
        ..value = jsonEncode({
          'address': 'http://127.0.0.1:${server.port}',
          'token': List.filled(64, 'a').join(),
          'instance_id': instance,
        });
      final pending = await PendingStore.open(path: inMemoryDatabasePath);
      final gateway = testGateway(pending, credentials);
      await gateway.restore();
      try {
        await expectLater(
          gateway.addCode('slb-900000000001'),
          throwsA(isA<LocalApiError>()),
        );
        await expectLater(
          gateway.addCode('SLB-900000000002'),
          throwsA(isA<LocalApiError>()),
        );
        fail = false;
        await gateway.retryScan();
        expect(paths, ['/api/cart/items', '/api/cart/items']);
        expect(bodies[0], bodies[1]);
        expect(bodies[0]['barcode'], 'SLB-900000000001');
        expect(gateway.pendingRequest('scan'), isNull);
      } finally {
        gateway.close();
        await pending.database.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'response from a different desktop instance does not clear pending scan',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('X-Lineboard-Instance', 'wrong-instance');
        request.response.write('{}');
        await request.response.close();
      });
      final credentials = MemoryCredentials()
        ..value = jsonEncode({
          'address': 'http://127.0.0.1:${server.port}',
          'token': List.filled(64, 'a').join(),
          'instance_id': instance,
        });
      final pending = await PendingStore.open(path: inMemoryDatabasePath);
      final gateway = testGateway(pending, credentials);
      await gateway.restore();
      try {
        await expectLater(
          gateway.addCode('SLB-900000000001'),
          throwsA(
            isA<LocalApiError>().having(
              (e) => e.code,
              'code',
              'WRONG_INSTANCE',
            ),
          ),
        );
        expect(gateway.pendingRequest('scan'), isNotNull);
      } finally {
        gateway.close();
        await pending.database.close();
        await server.close(force: true);
      }
    },
  );

  testWidgets(
    'local mode pairs with a desktop without a stock dashboard or mobile sale confirmation',
    (tester) async {
      final pending = (await tester.runAsync(
        () => PendingStore.open(path: inMemoryDatabasePath),
      ))!;
      final gateway = LocalGateway(pending, MemoryCredentials());
      await tester.pumpWidget(LocalLineboardApp(gateway));
      expect(find.text('Conecte seu celular ao caixa'), findsOneWidget);
      expect(find.text('Confirmar venda'), findsNothing);
      expect(find.text('Registrar saída'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      gateway.close();
      await tester.runAsync(() => pending.database.close());
    },
  );
}
