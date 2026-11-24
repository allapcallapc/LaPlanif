import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/utils/recipe_deal_items.dart';

DealItem _deal(
  String name,
  String store, {
  DealCategory category = DealCategory.vegetables,
  DealPreference? preference,
}) => DealItem(
  name: name,
  price: '1.99',
  unit: '',
  category: category,
  storeName: store,
  pageIndex: 2,
  preference: preference ?? DealPreference.neutral,
);

MealComponent _component(String name, [List<AnchorItem> dealItems = const []]) => MealComponent(
  type: MealComponentType.simpleSide,
  name: name,
  usesWeeklyDeal: dealItems.isNotEmpty,
  dealItems: dealItems,
);

MealSlotFull _recipe({
  List<AnchorItem> protein = const [],
  List<AnchorItem> carb = const [],
  List<AnchorItem> vegetable = const [],
}) => MealSlotFull(
  mealType: MealType.supper,
  protein: 'meat',
  count: 3,
  portionsPerMeal: 2,
  proteinComponent: _component('Roast chicken', protein),
  carbComponent: _component('Rice', carb),
  vegetableComponent: _component('Green beans', vegetable),
);

const _chicken = AnchorItem(name: 'Chicken thighs', store: 'IGA');
const _broccoli = AnchorItem(name: 'Brocoli', store: 'Metro');

final _deals = [
  _deal('Chicken thighs', 'IGA', category: DealCategory.protein),
  _deal('Brocoli', 'Metro'),
  _deal('Carottes', 'Maxi'),
  _deal('Poivrons', 'IGA', preference: DealPreference.excluded),
];

void main() {
  pantryTests();

  test('attaches a confirmed anchor the recipe left out to the protein component', () {
    final result = reconcileRecipeDealItems(
      recipe: _recipe(protein: const [_chicken]),
      anchors: const [_chicken, _broccoli],
      deals: _deals,
    );

    expect(result.proteinComponent.dealItems.map((d) => d.name), ['Chicken thighs', 'Brocoli']);
    expect(result.proteinComponent.usesWeeklyDeal, isTrue);
    expect(result.dealItemsUsed.map((d) => d.name), containsAll(['Chicken thighs', 'Brocoli']));
  });

  test('leaves an anchor on the side the recipe put it on', () {
    final result = reconcileRecipeDealItems(
      recipe: _recipe(protein: const [_chicken, _broccoli], vegetable: const [_broccoli]),
      anchors: const [_chicken, _broccoli],
      deals: _deals,
    );

    expect(result.proteinComponent.dealItems.map((d) => d.name), ['Chicken thighs']);
    expect(result.vegetableComponent.dealItems.map((d) => d.name), ['Brocoli']);
  });

  test('keeps a real deal item the recipe added, fixing its store from the deal', () {
    final result = reconcileRecipeDealItems(
      recipe: _recipe(
        protein: const [_chicken],
        vegetable: const [AnchorItem(name: 'carottes', store: 'IGA')],
      ),
      anchors: const [_chicken],
      deals: _deals,
    );

    expect(result.vegetableComponent.dealItems.single.name, 'Carottes');
    expect(result.vegetableComponent.dealItems.single.store, 'Maxi');
    expect(addedDealItems(result, const [_chicken]).map((d) => d.name), ['Carottes']);
  });

  test('drops an added deal item that is not on sale this week or was excluded', () {
    final result = reconcileRecipeDealItems(
      recipe: _recipe(
        protein: const [_chicken],
        carb: const [AnchorItem(name: 'Basmati rice', store: 'IGA')],
        vegetable: const [AnchorItem(name: 'Poivrons', store: 'IGA')],
      ),
      anchors: const [_chicken],
      deals: _deals,
    );

    expect(result.carbComponent.usesWeeklyDeal, isFalse);
    expect(result.carbComponent.dealItems, isEmpty);
    expect(result.vegetableComponent.usesWeeklyDeal, isFalse);
    expect(addedDealItems(result, const [_chicken]), isEmpty);
  });

  test('keeps an anchor even when it is not in the deal list', () {
    const custom = AnchorItem(name: 'Something else', store: 'IGA');
    final result = reconcileRecipeDealItems(recipe: _recipe(), anchors: const [custom], deals: _deals);

    expect(result.proteinComponent.dealItems.single.name, 'Something else');
  });
}

void pantryTests() {
  test('never lists a pantry carb as a deal item, even when the recipe does', () {
    const quinoa = AnchorItem.pantry('Quinoa');
    final result = reconcileRecipeDealItems(
      recipe: _recipe(protein: const [_chicken], carb: const [AnchorItem(name: 'Quinoa', store: 'Pantry')]),
      anchors: const [_chicken, quinoa],
      deals: _deals,
    );

    expect(result.carbComponent.usesWeeklyDeal, isFalse);
    expect(result.proteinComponent.dealItems.map((d) => d.name), ['Chicken thighs']);
    expect(addedDealItems(result, const [_chicken, quinoa]), isEmpty);
  });

  test('keeps a deal the recipe names differently from the flyer, under the flyer\'s name', () {
    final deals = [..._deals, _deal('Brocoli en couronne (Produit du Canada)', 'Metro')];
    final result = reconcileRecipeDealItems(
      recipe: _recipe(
        protein: const [_chicken],
        vegetable: const [AnchorItem(name: 'Brocoli en couronne', store: 'Metro')],
      ),
      anchors: const [_chicken],
      deals: deals,
    );

    expect(result.vegetableComponent.usesWeeklyDeal, isTrue);
    expect(result.vegetableComponent.dealItems.single.name, 'Brocoli en couronne (Produit du Canada)');
  });

  test('a reworded confirmed ingredient counts as that ingredient, not as a missing one', () {
    const longBroccoli = AnchorItem(name: 'Brocoli en couronne (Produit du Canada)', store: 'Metro');
    final deals = [..._deals, _deal('Brocoli en couronne (Produit du Canada)', 'Metro')];
    final result = reconcileRecipeDealItems(
      recipe: _recipe(
        protein: const [_chicken],
        vegetable: const [AnchorItem(name: 'brocoli en couronne', store: 'Metro')],
      ),
      anchors: const [_chicken, longBroccoli],
      deals: deals,
    );

    expect(result.vegetableComponent.dealItems.single.name, longBroccoli.name);
    // Not attached to the protein as if the recipe had dropped it.
    expect(result.proteinComponent.dealItems.map((d) => d.name), ['Chicken thighs']);
  });
}
