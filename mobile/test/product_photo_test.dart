import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lineboard_mobile/product_photo.dart';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=',
  );
  test('content headers determine format, independent of a filename', () {
    expect(ProductPhoto(png).contentType, 'image/png');
    expect(
      ProductPhoto(Uint8List.fromList([255, 216, 255, 224])).extension,
      'jpg',
    );
    expect(
      ProductPhoto(Uint8List.fromList(utf8.encode('RIFF0000WEBP'))).contentType,
      'image/webp',
    );
    for (final invalid in [
      Uint8List(0),
      Uint8List.fromList(utf8.encode('<svg>')),
      Uint8List.fromList(utf8.encode('RIFF0000WAVE')),
    ]) {
      expect(() => ProductPhoto(invalid), throwsFormatException);
    }
  });
  test('photo size limit applies before upload', () {
    final oversized = Uint8List(ProductPhoto.maxBytes + 1)
      ..setRange(0, png.length, png);
    expect(
      () => ProductPhoto(oversized),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          'PHOTO_TOO_LARGE',
        ),
      ),
    );
  });
  testWidgets('selected image has preview and can be removed', (tester) async {
    var photos = [ProductPhotoSelection.local(ProductPhoto(png))];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ProductPhotoField(
              photos: photos,
              onChanged: (value) => setState(() => photos = value),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('1/6'), findsOneWidget);
    expect(find.text('Escolher imagem'), findsOneWidget);
    expect(find.text('Tirar foto'), findsOneWidget);
    await tester.tap(find.text('Remover 1'));
    await tester.pump();
    expect(photos, isEmpty);
    expect(find.byType(Image), findsNothing);
    expect(find.text('Remover 1'), findsNothing);
  });
}
