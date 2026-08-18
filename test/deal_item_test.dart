import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/models/deal_item.dart';

void main() {
  test('exposes the fields it was constructed with', () {
    const item = DealItem(name: 'Poulet', price: '3.99\$', storeName: 'IGA', pageIndex: 2);

    expect(item.name, 'Poulet');
    expect(item.price, '3.99\$');
    expect(item.storeName, 'IGA');
    expect(item.pageIndex, 2);
  });
}
