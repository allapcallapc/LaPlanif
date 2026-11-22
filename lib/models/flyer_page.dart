class FlyerPage {
  const FlyerPage({required this.pageNumber, required this.altText, this.imageUrl});

  final int pageNumber;
  final String altText;

  /// Absolute URL of the page's flyer image, set only when [altText] is a
  /// bare `<Store> - Page N` label with no item descriptions. The site's
  /// alt-text pipeline sometimes skips a whole flyer (Maxi, Nov 2026), so
  /// the image is then the only source of the page's deals.
  final String? imageUrl;
}
