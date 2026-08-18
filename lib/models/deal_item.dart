class DealItem {
  const DealItem({
    required this.name,
    required this.price,
    required this.storeName,
    required this.pageIndex,
    this.isCoverPage = false,
    this.unitPrice,
  });

  final String name;
  final String price;
  final String storeName;
  final int pageIndex;
  final bool isCoverPage;
  final String? unitPrice;
}
