import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/utils/grocery_category.dart';

void main() {
  test('categorizeIngredient matches produce', () {
    expect(categorizeIngredient('Broccoli'), GroceryCategory.produce);
    expect(categorizeIngredient('yellow onion, diced'), GroceryCategory.produce);
    expect(categorizeIngredient('bell pepper'), GroceryCategory.produce);
  });

  test('categorizeIngredient matches meat & seafood', () {
    expect(categorizeIngredient('Boneless skinless chicken breasts'), GroceryCategory.meatAndSeafood);
    expect(categorizeIngredient('ground beef'), GroceryCategory.meatAndSeafood);
    expect(categorizeIngredient('shrimp'), GroceryCategory.meatAndSeafood);
  });

  test('categorizeIngredient matches dairy & eggs', () {
    expect(categorizeIngredient('shredded mozzarella cheese'), GroceryCategory.dairyAndEggs);
    expect(categorizeIngredient('large eggs'), GroceryCategory.dairyAndEggs);
  });

  test('categorizeIngredient matches bakery', () {
    expect(categorizeIngredient('flour tortillas'), GroceryCategory.bakery);
  });

  test('categorizeIngredient matches pantry, including a compound spice phrase that would otherwise read as produce', () {
    expect(categorizeIngredient('soy sauce'), GroceryCategory.pantry);
    expect(categorizeIngredient('white rice'), GroceryCategory.pantry);
    // Contains "pepper" but should match pantry's "black pepper", not
    // produce's bare "pepper" (which is for the vegetable).
    expect(categorizeIngredient('black pepper, to taste'), GroceryCategory.pantry);
  });

  test('categorizeIngredient matches frozen', () {
    expect(categorizeIngredient('frozen peas'), GroceryCategory.frozen);
  });

  test('categorizeIngredient falls back to other for unrecognized ingredients', () {
    expect(categorizeIngredient('kombucha starter culture'), GroceryCategory.other);
  });

  test('categorizeIngredient is case-insensitive', () {
    expect(categorizeIngredient('CHICKEN THIGHS'), GroceryCategory.meatAndSeafood);
  });

  test('label has a display string for every category', () {
    expect(GroceryCategory.produce.label, 'Produce');
    expect(GroceryCategory.meatAndSeafood.label, 'Meat & Seafood');
    expect(GroceryCategory.dairyAndEggs.label, 'Dairy & Eggs');
    expect(GroceryCategory.bakery.label, 'Bakery');
    expect(GroceryCategory.pantry.label, 'Pantry');
    expect(GroceryCategory.frozen.label, 'Frozen');
    expect(GroceryCategory.other.label, 'Other');
  });
}
