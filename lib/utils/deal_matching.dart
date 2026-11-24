import '../models/deal_item.dart';
import 'ingredient_kind.dart';

String _key(String name) => name.trim().toLowerCase();

/// The deal in [deals] an AI-written [name] (and [store]) refers to, or null.
///
/// The AI often shortens or rewords a flyer name ("Brocoli en couronne" for
/// "Brocoli en couronne (Produit du Canada)"), so this tries, in order: the
/// exact name; a deal name containing the AI's wording, then one contained
/// in it (both at least 4 characters, so short words don't match
/// everything), the closest in length first; then
/// the only deal of the same [ingredientKind]. Among equally good matches it
/// prefers the same [store].
DealItem? findDeal(String name, String store, Iterable<DealItem> deals) {
  final key = _key(name);
  if (key.isEmpty) return null;
  final all = deals.toList();

  DealItem? pick(List<DealItem> matches) {
    if (matches.isEmpty) return null;
    final sameStore = matches.where((deal) => _key(deal.storeName) == _key(store));
    return sameStore.isNotEmpty ? sameStore.first : matches.first;
  }

  final exact = pick(all.where((deal) => _key(deal.name) == key).toList());
  if (exact != null) return exact;

  // The AI usually shortens a flyer name, so a deal whose name contains the
  // AI's wording ("Brocoli en couronne" -> "Brocoli en couronne (Produit du
  // Canada)") beats one merely contained in it (plain "Brocoli"); within
  // each group the closest length wins, then the same store.
  bool longEnough(String a, String b) => (a.length < b.length ? a : b).length >= 4;
  final extended = all.where((deal) => _key(deal.name).contains(key) && longEnough(_key(deal.name), key)).toList();
  final shortened = all.where((deal) => key.contains(_key(deal.name)) && longEnough(_key(deal.name), key)).toList();
  for (final group in [extended, shortened]) {
    if (group.isEmpty) continue;
    int distance(DealItem deal) => (_key(deal.name).length - key.length).abs();
    final closest = group.map(distance).reduce((a, b) => a < b ? a : b);
    return pick(group.where((deal) => distance(deal) == closest).toList());
  }

  final kind = ingredientKind(name);
  if (kind == null) return null;
  final sameKind = all.where((deal) => ingredientKind(deal.name) == kind).toList();
  return sameKind.length == 1 ? sameKind.single : null;
}
