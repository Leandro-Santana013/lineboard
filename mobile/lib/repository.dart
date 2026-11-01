import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'domain.dart';
import 'pending_store.dart';

class Repository {
  Repository(this.client, this.prefs, this.pendingStore)
    : _sessionUserId = client.auth.currentUser?.id;
  final SupabaseClient client;
  final SharedPreferences prefs;
  final PendingStore pendingStore;
  final String? _sessionUserId;
  String get userId => _sessionUserId ?? client.auth.currentUser!.id;
  Repository forCurrentSession() => Repository(client, prefs, pendingStore);
  void _checkSession() {
    if (client.auth.currentUser?.id != userId) {
      throw StateError('SESSION_CHANGED');
    }
  }

  String scope(String org, String kind) => 'lineboard.$userId.$org.$kind';
  String get _membersKey => 'lineboard.$userId.memberships';
  bool cachedMemberships = false;

  Future<Map<String, dynamic>?> _boundConnection(String org) async {
    try {
      final row = await client
          .from('sic_connections')
          .select('instance_id')
          .eq('organization_id', org)
          .eq('enabled', true)
          .maybeSingle()
          .timeout(const Duration(seconds: 12));
      return row == null ? null : Map<String, dynamic>.from(row);
    } catch (_) {
      // Older deployments and offline test doubles do not expose the bridge
      // table yet; keep the existing transactional RPC path in that case.
      return null;
    }
  }

  Future<Map<String, dynamic>> _commandRow(
    String org,
    String commandId,
  ) async => Map<String, dynamic>.from(
    await client
        .from('sic_commands')
        .select('command_id,status,result,error_code')
        .eq('organization_id', org)
        .eq('command_id', commandId)
        .single()
        .timeout(const Duration(seconds: 12)),
  );

  Future<Map<String, dynamic>> _waitForCommand(
    String org,
    String commandId,
  ) async {
    final current = await _commandRow(org, commandId);
    if (current['status'] != 'pending' && current['status'] != 'processing') {
      return current;
    }
    final channel = client.channel('sic-command-$commandId');
    final done = Completer<Map<String, dynamic>>();
    void accept(Map<String, dynamic> row) {
      final status = row['status'];
      if (status == 'pending' || status == 'processing' || done.isCompleted) {
        return;
      }
      done.complete(row);
    }
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'sic_commands',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'command_id',
        value: commandId,
      ),
      callback: (payload) => accept(payload.newRecord),
    );
    channel.subscribe();
    try {
      accept(await _commandRow(org, commandId));
      return await done.future.timeout(const Duration(seconds: 45));
    } finally {
      await client.removeChannel(channel);
    }
  }

  Future<Map<String, dynamic>?> _queueForSic(
    String org,
    String requestId,
    String kind,
    Map<String, dynamic> payload,
  ) async {
    final binding = await _boundConnection(org);
    if (binding == null) return null;
    final queued = Map<String, dynamic>.from(
      await client.rpc(
        'queue_sic_command',
        params: {
          'p_org': org,
          'p_request_id': requestId,
          'p_instance_id': binding['instance_id'],
          'p_kind': kind,
          'p_payload': payload,
        },
      ).timeout(const Duration(seconds: 15)),
    );
    return _waitForCommand(org, queued['command_id'] as String);
  }

  Future<List<Map<String, dynamic>>> memberships() async {
    try {
      await client
          .rpc('accept_invitations')
          .timeout(const Duration(seconds: 12));
      final result = await client
          .from('memberships')
          .select('organization_id, role, organizations(name)')
          .eq('user_id', userId)
          .timeout(const Duration(seconds: 12));
      await prefs.setString(_membersKey, jsonEncode(result));
      cachedMemberships = false;
      return List<Map<String, dynamic>>.from(result);
    } on PostgrestException {
      rethrow; // Revoked membership/auth is not an offline session.
    } catch (_) {
      final saved = prefs.getString(_membersKey);
      if (saved == null) rethrow;
      cachedMemberships = true;
      return List<Map<String, dynamic>>.from(jsonDecode(saved));
    }
  }

  List<CatalogItem> cachedCatalog(String org) {
    final saved = prefs.getString(scope(org, 'catalog'));
    if (saved == null) return [];
    return (jsonDecode(saved) as List)
        .map((e) => CatalogItem(Map<String, dynamic>.from(e)))
        .toList();
  }

  DateTime? syncTime(String org) =>
      DateTime.tryParse(prefs.getString(scope(org, 'synced_at')) ?? '');
  Future<void> syncCatalog(String org) async {
    final rows = <Map<String, dynamic>>[];
    String cursor = '';
    while (true) {
      final page = await client
          .from('mobile_catalog')
          .select()
          .eq('organization_id', org)
          .gt('barcode', cursor)
          .order('barcode')
          .limit(500)
          .timeout(const Duration(seconds: 15));
      rows.addAll(page);
      if (page.length < 500) break;
      cursor = page.last['barcode'] as String;
    }
    await prefs.setString(scope(org, 'catalog'), jsonEncode(rows));
    await prefs.setString(
      scope(org, 'synced_at'),
      DateTime.now().toIso8601String(),
    );
  }

  Future<CatalogItem> lookup(String org, String code) async {
    if (!validBarcode(code)) throw const FormatException('INVALID_BARCODE');
    final row = await client
        .from('mobile_catalog')
        .select()
        .eq('organization_id', org)
        .eq('barcode', canonicalBarcode(code))
        .maybeSingle()
        .timeout(const Duration(seconds: 12));
    if (row == null) throw StateError('BARCODE_NOT_FOUND');
    return CatalogItem(row);
  }

  Future<List<CatalogItem>> productLabels(String org, String product) async {
    final rows = <CatalogItem>[];
    String cursor = '';
    while (true) {
      final page = await client
          .from('mobile_catalog')
          .select()
          .eq('organization_id', org)
          .eq('product_id', product)
          .gt('barcode', cursor)
          .order('barcode')
          .limit(500)
          .timeout(const Duration(seconds: 15));
      rows.addAll(page.map(CatalogItem.new));
      if (page.length < 500) return rows;
      cursor = page.last['barcode'] as String;
    }
  }

  Future<void> updateProduct(
    CatalogItem item,
    Map<String, String> fields,
  ) async {
    _checkSession();
    await client
        .rpc(
          'update_product',
          params: {
            'p_org': item.data['organization_id'],
            'p_product_id': item.productId,
            'p_fields': fields,
          },
        )
        .timeout(const Duration(seconds: 15));
  }

  Map<String, dynamic>? pendingProduct(String org) {
    final saved = pendingStore.get(scope(org, 'pending_product'));
    return saved == null ? null : Map<String, dynamic>.from(jsonDecode(saved));
  }

  Future<void> savePendingProduct(
    String org,
    String key,
    Map<String, dynamic> product,
  ) async {
    await pendingStore.put(
      scope(org, 'pending_product'),
      jsonEncode({'key': key, 'product': product}),
    );
  }

  Future<Map<String, dynamic>> sendProduct(
    String org,
    Map<String, dynamic> pending,
  ) async {
    _checkSession();
    final queued = await _queueForSic(
      org,
      pending['key'] as String,
      'product.create',
      Map<String, dynamic>.from(pending['product'] as Map),
    );
    if (queued != null) {
      final result = queued['result'];
      if (queued['status'] != 'completed' || result is! Map || result['product_id'] == null) {
        throw StateError(queued['error_code'] as String? ?? 'SIC_COMMAND_FAILED');
      }
      return Map<String, dynamic>.from(result);
    }
    final productId = await client
            .rpc(
              'create_product',
              params: {
                'p_org': org,
                'p_request_id': pending['key'],
                'p_product': pending['product'],
              },
            )
            .timeout(const Duration(seconds: 25))
        as String;
    return {'product_id': productId};
  }

  Future<void> clearPendingProduct(String org) async {
    await pendingStore.remove(scope(org, 'pending_product'));
  }

  PendingSale? pendingSale(String org) {
    final saved = pendingStore.get(scope(org, 'pending_sale'));
    return saved == null
        ? null
        : PendingSale.fromJson(Map<String, dynamic>.from(jsonDecode(saved)));
  }

  Future<void> savePendingSale(String org, PendingSale sale) async {
    await pendingStore.put(
      scope(org, 'pending_sale'),
      jsonEncode(sale.toJson()),
    );
  }

  Future<Map<String, dynamic>> sendSale(String org, PendingSale sale) async {
    _checkSession();
    final queued = await _queueForSic(
      org,
      sale.key,
      'cart.confirm',
      {
        'lines': sale.lines,
        'reference': sale.reference,
      },
    );
    if (queued != null) {
      final result = queued['result'];
      if (queued['status'] != 'completed' || result is! Map) {
        throw StateError(queued['error_code'] as String? ?? 'SIC_COMMAND_FAILED');
      }
      return Map<String, dynamic>.from(result);
    }
    return Map<String, dynamic>.from(
      await client
          .rpc(
            'record_physical_sale',
            params: {
              'p_org': org,
              'p_key': sale.key,
              'p_lines': sale.lines,
              'p_reference': sale.reference,
            },
          )
          .timeout(const Duration(seconds: 25)),
    );
  }

  Future<void> clearPendingSale(String org) async {
    await pendingStore.remove(scope(org, 'pending_sale'));
  }

  Future<void> logout() async {
    // Keep unresolved requests for recovery by this same user, never another user.
    final prefix = 'lineboard.$userId.';
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      if (!key.endsWith('.pending_sale') && !key.endsWith('.pending_product')) {
        await prefs.remove(key);
      }
    }
    await client.auth.signOut(scope: SignOutScope.local);
  }
}
