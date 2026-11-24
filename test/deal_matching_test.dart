import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/utils/deal_matching.dart';

DealItem _deal(String name, String store) =>
    DealItem(name: name, price: '1.99', unit: '', category: DealCategory.vegetables, storeName: store, pageIndex: 1);

void main() {
  final deals = [
    _deal('Brocoli en couronne (Produit du Canada)', 'Metro'),
    _deal('Brocoli en couronne (Produit du Canada)', 'IGA'),
    _deal('Carottes', 'Maxi'),
    _deal('Riz Jasmin Dainty', 'Maxi'),
    _deal('Pois', 'IGA'),
  ];

  test('matches the exact name first, preferring the same store', () {
    expect(findDeal('Carottes', 'IGA', deals)?.storeName, 'Maxi');
    expect(findDeal('brocoli en couronne (produit du canada)', 'IGA', deals)?.storeName, 'IGA');
  });

  test('matches a shortened or longer wording of the flyer name', () {
    expect(findDeal('Brocoli en couronne', 'Metro', deals)?.storeName, 'Metro');
    expect(findDeal('Carottes nantaises', 'Maxi', deals)?.name, 'Carottes');
  });

  test('falls back to the only deal of the same kind of ingredient', () {
    expect(findDeal('Jasmine rice', 'Maxi', deals)?.name, 'Riz Jasmin Dainty');
  });

  test('finds nothing for an unknown item, an ambiguous kind, or a too-short name', () {
    expect(findDeal('Parmesan', 'IGA', deals), isNull);
    expect(findDeal('Broccoli', 'IGA', [deals[0], _deal('Brocoli rabe', 'IGA')]), isNull);
    expect(findDeal('Poi', 'IGA', [_deal('Poivrons', 'IGA')]), isNull);
    expect(findDeal('  ', 'IGA', deals), isNull);
  });
}
