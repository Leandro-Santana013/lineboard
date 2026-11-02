import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:lineboard_mobile/domain.dart';
import 'package:lineboard_mobile/pending_store.dart';
import 'package:lineboard_mobile/repository.dart';

Future<SupabaseClient> sessionClient(
  MockClient transport, {
  String user = 'user-a',
}) async {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'public-test-key',
    httpClient: transport,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await client.auth.setInitialSession(
    jsonEncode({
      'access_token': 'test-token',
      'token_type': 'bearer',
      'refresh_token': 'test-refresh',
      'expires_in': 3600,
      'user': {
        'id': user,
        'app_metadata': {},
        'user_metadata': {},
        'aud': 'authenticated',
        'created_at': '2026-01-01T00:00:00Z',
      },
    }),
  );
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test(
    'pending requests survive SQLite close/reopen, scoped by user and store',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lineboard-pending-',
      );
      final path = '${directory.path}/operations.db';
      final store = await PendingStore.open(path: path);
      final operation = PendingSale(
        key: 'same-key',
        lines: [
          {'barcode': 'SLB-000000000001', 'quantity': 2},
        ],
        reference: 'receipt',
      );
      await store.put(
        'lineboard.user-a.org-a.pending_sale',
        jsonEncode(operation.toJson()),
      );
      await store.database.close();
      final reopened = await PendingStore.open(path: path);
      expect(
        PendingSale.fromJson(
          jsonDecode(reopened.get('lineboard.user-a.org-a.pending_sale')!),
        ).key,
        'same-key',
      );
      expect(reopened.get('lineboard.user-b.org-a.pending_sale'), isNull);
      expect(reopened.get('lineboard.user-a.org-b.pending_sale'), isNull);
      await reopened.remove('lineboard.user-a.org-a.pending_sale');
      expect(reopened.get('lineboard.user-a.org-a.pending_sale'), isNull);
      await reopened.database.close();
      await directory.delete(recursive: true);
    },
  );
  test('failed sync preserves prior offline catalog and timestamp, sale does not report success', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final transport = MockClient(
      (request) async => throw const SocketException('offline'),
    );
    final client = await sessionClient(transport);
    final store = await PendingStore.open(path: inMemoryDatabasePath);
    final repo = Repository(client, prefs, store);
    final rows = [
      {
        'barcode': 'SLB-000000000001',
        'name': 'Leash',
        'tracking': 'quantity',
        'product_id': 'p',
      },
    ];
    await prefs.setString(repo.scope('org-a', 'catalog'), jsonEncode(rows));
    await prefs.setString(
      repo.scope('org-a', 'synced_at'),
      '2026-10-22T10:00:00Z',
    );
    await expectLater(
      repo.syncCatalog('org-a'),
      throwsA(isA<SocketException>()),
    );
    expect(repo.cachedCatalog('org-a').single.name, 'Leash');
    expect(repo.syncTime('org-a')!.year, 2026);
    final sale = PendingSale(
      key: 'same-key',
      lines: [
        {'barcode': 'SLB-000000000001', 'quantity': 1},
      ],
      reference: '',
    );
    await repo.savePendingSale('org-a', sale);
    await expectLater(
      repo.sendSale('org-a', sale),
      throwsA(isA<SocketException>()),
    );
    expect(repo.pendingSale('org-a')!.key, 'same-key');
    await store.database.close();
    await client.dispose();
    transport.close();
  });
  test('shared cart detects a store with multiple desktops without selecting a phone target', () async {
    SharedPreferences.setMockInitialValues({});
    final transport = MockClient((request) async {
      expect(request.url.path, endsWith('/sic_connections'));
      expect(request.url.queryParameters['limit'], '1');
      expect(request.url.queryParameters['organization_id'], 'eq.org-a');
      return http.Response(
        '[{"instance_id":"desktop-a"}]',
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    final client = await sessionClient(transport);
    final store = await PendingStore.open(path: inMemoryDatabasePath);
    final repo = Repository(
      client,
      await SharedPreferences.getInstance(),
      store,
    );
    expect(await repo.usesSharedCart('org-a'), isTrue);
    await store.database.close();
    await client.dispose();
    transport.close();
  });
  test('a failed shared scan retries the exact request and never submits a sale or targets a desktop', () async {
    SharedPreferences.setMockInitialValues({});
    final requests = <Map<String, dynamic>>[];
    final transport = MockClient((request) async {
      expect(request.url.path, endsWith('/rpc/update_sic_cart'));
      final body = Map<String, dynamic>.from(jsonDecode(request.body));
      requests.add(body);
      expect(body.containsKey('p_instance_id'), isFalse);
      expect(body['p_org'], 'org-a');
      if (requests.length == 1) throw const SocketException('lost reply');
      return http.Response(
        '{"state":"saved"}',
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    final client = await sessionClient(transport);
    final store = await PendingStore.open(path: inMemoryDatabasePath);
    final repo = Repository(
      client,
      await SharedPreferences.getInstance(),
      store,
    );
    await expectLater(
      repo.changeSharedCart('org-a', 'SLB-900000000022'),
      throwsA(isA<SocketException>()),
    );
    await repo.changeSharedCart('org-a', 'SLB-900000000022');
    expect(requests[0], requests[1]);
    expect(store.get(repo.scope('org-a', 'cart_add.SLB-900000000022')), isNull);
    await store.database.close();
    await client.dispose();
    transport.close();
  });
  test('a connection lookup failure is not disguised as an unbound cloud-only store', () async {
    SharedPreferences.setMockInitialValues({});
    final transport = MockClient(
      (request) async => throw const SocketException('offline'),
    );
    final client = await sessionClient(transport);
    final store = await PendingStore.open(path: inMemoryDatabasePath);
    final repo = Repository(
      client,
      await SharedPreferences.getInstance(),
      store,
    );
    await expectLater(
      repo.usesSharedCart('org-a'),
      throwsA(isA<SocketException>()),
    );
    await store.database.close();
    await client.dispose();
    transport.close();
  });
  test(
    'sale retry sends identical key and payload to the transactional RPC',
    () async {
      SharedPreferences.setMockInitialValues({});
      final requests = <Map<String, dynamic>>[];
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/sic_connections')) {
          return http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        expect(request.url.path, contains('/rpc/record_physical_sale'));
        requests.add(jsonDecode(request.body));
        return http.Response(
          jsonEncode({'sale_id': 'receipt', 'replayed': requests.length > 1}),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      final client = await sessionClient(transport);
      final store = await PendingStore.open(path: inMemoryDatabasePath);
      final repo = Repository(
        client,
        await SharedPreferences.getInstance(),
        store,
      );
      final pending = PendingSale(
        key: 'stable-key',
        lines: [
          {'barcode': 'SLB-000000000001', 'quantity': 2},
        ],
        reference: 'POS-1',
      );
      await repo.savePendingSale('org-a', pending);
      await repo.sendSale('org-a', pending);
      final replay = await repo.sendSale('org-a', repo.pendingSale('org-a')!);
      expect(requests[0], requests[1]);
      expect(replay['replayed'], isTrue);
      await store.database.close();
      await client.dispose();
      transport.close();
    },
  );
}
