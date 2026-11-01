import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lineboard_mobile/app.dart';
import 'package:lineboard_mobile/domain.dart';
import 'package:lineboard_mobile/scan_label.dart';

void main() {
  testWidgets('missing configuration has an honest setup screen', (
    tester,
  ) async {
    await tester.pumpWidget(const LineboardApp());
    expect(find.text('Lineboard'), findsOneWidget);
    expect(find.textContaining('conectado à sua loja'), findsOneWidget);
    expect(find.text('Registrar saída'), findsNothing);
  });
  testWidgets('label has product identity and barcode, no stock balance', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LabelCard(
            CatalogItem({
              'name': 'Leash Pro',
              'barcode': 'SLB-000000000001',
              'color': 'Azul',
              'size': '7 pés',
              'tracking': 'quantity',
            }),
          ),
        ),
      ),
    );
    expect(find.text('Leash Pro'), findsOneWidget);
    expect(find.text('Azul · 7 pés'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
