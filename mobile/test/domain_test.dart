import 'package:flutter_test/flutter_test.dart';
import 'package:lineboard_mobile/domain.dart';

CatalogItem item(String code, String tracking) =>
    CatalogItem({'barcode': code, 'name': 'Prancha', 'tracking': tracking});
void main() {
  test(
    'repeated variant scans increase sale quantity, individual scans do not',
    () {
      final basket = SaleBasket();
      final variant = item('SLB-000000000001', 'quantity');
      basket.add(variant);
      basket.add(variant);
      expect(basket.lines.single.quantity, 2);
      final unit = item('SLB-000000000002', 'individual');
      basket.add(unit);
      expect(() => basket.add(unit), throwsStateError);
      expect(basket.lines.last.quantity, 1);
    },
  );
  test('pending sale preserves key and payload on recovery', () {
    final pending = PendingSale(
      key: 'same-key',
      lines: [
        {'barcode': 'SLB-000000000001', 'quantity': 2},
      ],
      reference: 'PDV-1',
    );
    final recovered = PendingSale.fromJson(pending.toJson());
    expect(recovered.key, pending.key);
    expect(recovered.lines, pending.lines);
    expect(recovered.reference, 'PDV-1');
  });
  test('only internal Code 128 values pass validation', () {
    expect(validBarcode('slb-000000000001'), isTrue);
    expect(validBarcode('SLB-1'), isFalse);
    expect(validBarcode('1234567890123'), isFalse);
    expect(validBarcode('https://example.com'), isFalse);
  });
}
