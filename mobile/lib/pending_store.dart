import 'package:sqflite/sqflite.dart';

// Critical request keys/payloads are committed to SQLite before touching the API.
// The in-memory index only provides synchronous reads for the operation screens.
class PendingStore {
  PendingStore._(this.database, this.values);
  final Database database;
  final Map<String, String> values;
  static Future<PendingStore> open({String? path}) async {
    final database = await openDatabase(
      path ?? '${await getDatabasesPath()}/lineboard_operations.db',
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE pending (scope TEXT PRIMARY KEY, payload TEXT NOT NULL)',
      ),
    );
    final rows = await database.query('pending');
    return PendingStore._(database, {
      for (final row in rows) row['scope'] as String: row['payload'] as String,
    });
  }

  String? get(String scope) => values[scope];
  Future<void> put(String scope, String payload) async {
    await database.insert('pending', {
      'scope': scope,
      'payload': payload,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    values[scope] = payload;
  }

  Future<void> remove(String scope) async {
    await database.delete('pending', where: 'scope = ?', whereArgs: [scope]);
    values.remove(scope);
  }
}
