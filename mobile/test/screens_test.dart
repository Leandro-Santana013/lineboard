import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lineboard_mobile/app.dart';
import 'package:lineboard_mobile/domain.dart';
import 'package:lineboard_mobile/scan_label.dart';

void main() {
  test('scanner selects a valid Lineboard code after an invalid detection', () {
    final result = selectBarcode([
      null,
      'another-code',
      ' slb-000000000001 ',
    ]);

    expect(result.sawValue, isTrue);
    expect(result.code, 'SLB-000000000001');
  });

  test('scanner reports a visible but unsupported code', () {
    final result = selectBarcode(['7891234567890']);

    expect(result.sawValue, isTrue);
    expect(result.code, isNull);
  });

  test('scanner ignores captures without decoded values', () {
    final result = selectBarcode([null, '', '   ']);

    expect(result.sawValue, isFalse);
    expect(result.code, isNull);
  });

  test('scanner deterministically selects the first valid code', () {
    final result = selectBarcode([
      'SLB-000000000002',
      'SLB-000000000003',
    ]);

    expect(result.code, 'SLB-000000000002');
  });

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
