import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'brand.dart';
import 'repository.dart';
import 'pending_store.dart';
import 'local_app.dart';
import 'local_gateway.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const mode = String.fromEnvironment('LINEBOARD_MODE', defaultValue: 'cloud');
  if (mode == 'local') {
    try {
      final pendingStore = await PendingStore.open();
      final gateway = LocalGateway(pendingStore, SecureLocalCredentials());
      await gateway.restore();
      runApp(LocalLineboardApp(gateway));
    } catch (_) {
      runApp(
        MaterialApp(
          theme: lineboardTheme(),
          home: const Scaffold(
            body: SafeArea(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Não foi possível abrir os dados locais do Lineboard. Reinicie o aplicativo. As operações pendentes não foram apagadas.',
                ),
              ),
            ),
          ),
        ),
      );
    }
    return;
  }
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  if (url.isEmpty || key.isEmpty) {
    runApp(const LineboardApp());
    return;
  }
  try {
    await Supabase.initialize(url: url, publishableKey: key);
    final prefs = await SharedPreferences.getInstance();
    final pendingStore = await PendingStore.open();
    runApp(
      LineboardApp(
        repository: Repository(Supabase.instance.client, prefs, pendingStore),
      ),
    );
  } catch (_) {
    runApp(const LineboardApp());
  }
}
