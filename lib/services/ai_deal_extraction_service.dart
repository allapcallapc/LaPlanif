import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_call_log.dart';
import '../models/deal_item.dart';
import '../models/flyer_page.dart';
import '../utils/error_formatting.dart';
import 'ai_call_activity.dart';
import 'ai_call_log_repository.dart';
import 'ai_config_repository.dart';
import 'model_fallback_controller.dart';

/// Turns raw per-page flyer alt text into structured deal items using the
/// Google AI (Gemini) API - no local splitting/parsing heuristics. Every
/// call (success or failure) is recorded via [AiCallLogRepository] so usage
/// can be reviewed later.
class AiDealExtractionService {
  AiDealExtractionService({
    http.Client? client,
    String? model,
    AiCallLogRepository? logRepository,
    this.retryDelay = const Duration(seconds: 2),
    this.imageDownloadTimeout = const Duration(seconds: 15),
  }) : model = model ?? AiConfigRepository.defaultModels.first,
       _client = client ?? http.Client(),
       _logRepository = logRepository ?? AiCallLogRepository();

  static const _apiBase = 'https://generativelanguage.googleapis.com/v1beta/models';

  /// Flyers can run to dozens of pages; callers should split a store's pages
  /// into chunks of at most this many before calling [extractItems] rather
  /// than sending an entire flyer in one request - kept small enough that
  /// even a dense flyer (many items per page) stays well under
  /// maxOutputTokens. A batch that's too large gets its function-call JSON
  /// truncated mid-response, which Gemini reports as finishReason
  /// MALFORMED_FUNCTION_CALL rather than MAX_TOKENS.
  ///
  /// Chunking lives with the caller (not inside this method) so that when
  /// one chunk of a multi-chunk store fails, only that chunk needs retrying
  /// - a caller that retried the whole (unchunked) page list would silently
  /// discard already-extracted chunks and re-pay for them.
  static const maxPagesPerCall = 10;

  /// The most page *images* (see [FlyerPage.imageUrl]) to send in one call.
  /// A whole flyer page read from its image yields far more items than a
  /// short alt text, and every image adds to the request size, so batches
  /// containing images are kept much smaller than [maxPagesPerCall].
  static const maxImagePagesPerCall = 3;

  /// Splits [pages] (in order) into chunks for [extractItems]: at most
  /// [maxPagesPerCall] pages each, of which at most [maxImagePagesPerCall]
  /// carry an image.
  static List<List<FlyerPage>> chunkPages(List<FlyerPage> pages) {
    final chunks = <List<FlyerPage>>[];
    var current = <FlyerPage>[];
    var imagesInCurrent = 0;
    for (final page in pages) {
      final isImage = page.imageUrl != null;
      if (current.length == maxPagesPerCall || (isImage && imagesInCurrent == maxImagePagesPerCall)) {
        chunks.add(current);
        current = <FlyerPage>[];
        imagesInCurrent = 0;
      }
      current.add(page);
      if (isImage) imagesInCurrent++;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  /// Largest page image (raw bytes) sent inline. With [maxImagePagesPerCall]
  /// images and base64's ~33% overhead this keeps a request around 20 MB at
  /// most; a bigger image is left out rather than risking the whole call.
  static const maxImageBytes = 5 * 1024 * 1024;

  /// Image formats the Gemini API accepts as inline data.
  static const _supportedImageTypes = {'image/png', 'image/jpeg', 'image/webp', 'image/heic', 'image/heif'};

  final http.Client _client;
  final AiCallLogRepository _logRepository;
  final String model;

  /// Delay before the single retry attempt on an HTTP 503 ("model
  /// overloaded", a documented transient Gemini signal). Injectable so
  /// tests don't have to wait for it.
  final Duration retryDelay;

  /// How long to wait for a flyer page image to download before leaving it
  /// out of the request.
  final Duration imageDownloadTimeout;

  /// Recently downloaded page images (URL -> inline part, or null if the
  /// image couldn't be used), so a retry of the same chunk - same model on a
  /// 503 / malformed response, or another model via ModelFallbackController -
  /// doesn't download every image again. Kept small: only the current chunk's
  /// images are ever needed again.
  final _imageCache = <String, Future<Map<String, dynamic>?>>{};

  /// Extracts deal items from [pages] in a single API call. [pages] should
  /// be one chunk from [chunkPages] - see [maxPagesPerCall]'s doc comment for
  /// why chunking a larger page list is the caller's responsibility.
  Future<List<DealItem>> extractItems({
    required String apiKey,
    required String storeName,
    required List<FlyerPage> pages,
    String? model,
  }) async {
    final effectiveModel = model ?? this.model;
    final activityId = AiCallActivity.start(storeName: storeName, model: effectiveModel);
    try {
      return await _extractBatchTracked(apiKey: apiKey, storeName: storeName, pages: pages, model: effectiveModel);
    } finally {
      AiCallActivity.finish(activityId);
    }
  }

  Future<List<DealItem>> _extractBatchTracked({
    required String apiKey,
    required String storeName,
    required List<FlyerPage> pages,
    required String model,
  }) async {
    // Gemini occasionally produces an invalid function call under forced
    // function calling (finishReason MALFORMED_FUNCTION_CALL) - a
    // documented, non-deterministic quirk worth a single full retry, same
    // as the HTTP 503 case.
    final body = jsonEncode(_buildRequestBody(await _buildUserParts(pages)));
    for (var attempt = 1;; attempt++) {
      final http.Response response;
      try {
        response = await _postWithRetry(apiKey: apiKey, storeName: storeName, pages: pages, model: model, body: body);
      } catch (_) {
        await _log(
          storeName: storeName,
          model: model,
          success: false,
          errorMessage: 'Could not reach the AI API',
          pages: pages,
        );
        throw Exception('Could not reach the AI API');
      }

      if (response.statusCode == 429) {
        await _log(
          storeName: storeName,
          model: model,
          success: false,
          errorMessage: 'AI API HTTP 429',
          pages: pages,
        );
        throw RateLimitedException(model);
      }

      if (response.statusCode != 200) {
        await _log(
          storeName: storeName,
          model: model,
          success: false,
          errorMessage: 'AI API HTTP ${response.statusCode}',
          pages: pages,
        );
        throw Exception('AI API HTTP ${response.statusCode}');
      }

      final Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        await _log(
          storeName: storeName,
          model: model,
          success: false,
          errorMessage: 'Invalid JSON from the AI API',
          pages: pages,
        );
        throw Exception('Invalid JSON from the AI API');
      }

      final usage = decoded['usageMetadata'] as Map<String, dynamic>?;
      final inputTokens = (usage?['promptTokenCount'] as num?)?.toInt() ?? 0;
      final outputTokens = (usage?['candidatesTokenCount'] as num?)?.toInt() ?? 0;

      try {
        final items = _parseItems(decoded, storeName);
        await _log(
          storeName: storeName,
          model: model,
          success: true,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          pages: pages,
        );
        return items;
      } catch (e) {
        final detail = _errorDetail(e);
        await _log(
          storeName: storeName,
          model: model,
          success: false,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          errorMessage: 'Could not parse structured output from the AI response: $detail',
          pages: pages,
        );
        if (attempt == 1 && detail.contains('MALFORMED_FUNCTION_CALL')) {
          await Future<void>.delayed(retryDelay);
          continue;
        }
        rethrow;
      }
    }
  }

  /// Sends the request, retrying once after [retryDelay] if the API returns
  /// HTTP 503 - Google's documented "model overloaded, try again" signal.
  /// HTTP 429 (rate limited) is deliberately NOT retried here: that flow -
  /// wait, retry, then ask the user whether to keep retrying or fall back to
  /// another model - lives in [ModelFallbackController], one level up.
  Future<http.Response> _postWithRetry({
    required String apiKey,
    required String storeName,
    required List<FlyerPage> pages,
    required String model,
    required String body,
  }) async {
    final uri = Uri.parse('$_apiBase/$model:generateContent');
    final headers = {'x-goog-api-key': apiKey, 'content-type': 'application/json'};

    final response = await _client.post(uri, headers: headers, body: body);
    if (response.statusCode != 503) {
      return response;
    }
    await _log(storeName: storeName, model: model, success: false, errorMessage: 'AI API HTTP 503', pages: pages);
    await Future<void>.delayed(retryDelay);
    return _client.post(uri, headers: headers, body: body);
  }

  String _errorDetail(Object error) => stripExceptionPrefix(error);

  Future<void> _log({
    required String storeName,
    required String model,
    required bool success,
    int inputTokens = 0,
    int outputTokens = 0,
    String? errorMessage,
    List<FlyerPage> pages = const [],
  }) {
    return _logRepository.add(
      AiCallLog(
        timestamp: DateTime.now(),
        storeName: storeName,
        model: model,
        success: success,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        errorMessage: errorMessage,
        pageSample: _pageSample(pages),
      ),
    );
  }

  /// Summarizes what was actually scraped for this call: page count,
  /// average alt-text length per page, and a snippet of the first page's
  /// alt text - enough to tell "the flyer had nothing to extract" apart
  /// from "the AI missed something that was there" at a glance.
  String? _pageSample(List<FlyerPage> pages) {
    if (pages.isEmpty) return null;
    final totalChars = pages.fold<int>(0, (sum, p) => sum + p.altText.length);
    final avgChars = (totalChars / pages.length).round();
    final first = pages.first;
    final snippet = first.altText.length > 300 ? '${first.altText.substring(0, 300)}…' : first.altText;
    final imagePages = pages.where((p) => p.imageUrl != null).length;
    final imageNote = imagePages > 0 ? ' ($imagePages with images)' : '';
    return '${pages.length} page(s)$imageNote, avg $avgChars chars/page. Page ${first.pageNumber}: "$snippet"';
  }

  /// The user turn's parts: each page's "Page N:" label and alt text, plus
  /// the page image itself for pages whose alt text is only a label (see
  /// [FlyerPage.imageUrl]). Consecutive text is merged into one part. Images
  /// are downloaded in parallel; one that can't be used is left out (and
  /// noted in the text) so it never fails the pages around it.
  Future<List<Map<String, dynamic>>> _buildUserParts(List<FlyerPage> pages) async {
    final images = await Future.wait(
      pages.map((p) => p.imageUrl == null ? Future<Map<String, dynamic>?>.value() : _cachedImagePart(p.imageUrl!)),
    );

    final parts = <Map<String, dynamic>>[];
    final text = StringBuffer();
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (text.isNotEmpty) text.write('\n\n');
      text.write('Page ${page.pageNumber}:\n${page.altText}');
      if (page.imageUrl == null) continue;
      final image = images[i];
      if (image == null) {
        text.write('\n(The page image could not be loaded.)');
        continue;
      }
      text.write('\n(The page image follows.)');
      parts.add({'text': text.toString()});
      text.clear();
      parts.add(image);
    }
    if (text.isNotEmpty) parts.add({'text': text.toString()});
    return parts;
  }

  Future<Map<String, dynamic>?> _cachedImagePart(String imageUrl) {
    final cached = _imageCache[imageUrl];
    if (cached != null) return cached;
    while (_imageCache.length >= maxImagePagesPerCall * 2) {
      _imageCache.remove(_imageCache.keys.first);
    }
    return _imageCache[imageUrl] = _downloadImagePart(imageUrl);
  }

  /// Downloads the image in-app and returns it as an inline part, or null if
  /// it can't be used (network/CORS failure, timeout, non-200, too large, or
  /// a format Gemini doesn't accept). Inline rather than a URL reference:
  /// the browser can already reach the flyer site (it just fetched the
  /// HTML), whereas Gemini's own URL fetcher may be refused by the site's
  /// bot protection - and a refused URL fails the whole request.
  Future<Map<String, dynamic>?> _downloadImagePart(String imageUrl) async {
    try {
      final response = await _client.get(Uri.parse(imageUrl)).timeout(imageDownloadTimeout);
      final bytes = response.bodyBytes;
      if (response.statusCode != 200 || bytes.isEmpty || bytes.length > maxImageBytes) return null;
      final mimeType = _imageMimeType(response.headers['content-type'], bytes);
      if (mimeType == null) return null;
      return {
        'inlineData': {'mimeType': mimeType, 'data': base64Encode(bytes)},
      };
    } catch (_) {
      return null;
    }
  }

  /// The image's MIME type if Gemini accepts it: the Content-Type header when
  /// it names a supported format, otherwise sniffed from the file's magic
  /// bytes (CDNs often send `application/octet-stream`).
  static String? _imageMimeType(String? contentTypeHeader, List<int> bytes) {
    final header = contentTypeHeader?.split(';').first.trim().toLowerCase();
    if (header != null && _supportedImageTypes.contains(header)) return header;
    bool startsWith(List<int> signature, [int offset = 0]) {
      if (bytes.length < offset + signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[offset + i] != signature[i]) return false;
      }
      return true;
    }

    if (startsWith([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (startsWith([0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (startsWith('RIFF'.codeUnits) && startsWith('WEBP'.codeUnits, 8)) return 'image/webp';
    return null;
  }

  Map<String, dynamic> _buildRequestBody(List<Map<String, dynamic>> userParts) {
    return {
      'systemInstruction': {
        'parts': [
          {'text': _systemPrompt},
        ],
      },
      'contents': [
        {'role': 'user', 'parts': userParts},
      ],
      'tools': [_recordItemsTool],
      'toolConfig': {
        'functionCallingConfig': {
          'mode': 'ANY',
          'allowedFunctionNames': ['record_items'],
        },
      },
      'generationConfig': {'maxOutputTokens': 32768},
    };
  }

  List<DealItem> _parseItems(Map<String, dynamic> decoded, String storeName) {
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      final blockReason = (decoded['promptFeedback'] as Map<String, dynamic>?)?['blockReason'];
      throw Exception('no candidates returned${blockReason != null ? ' (blockReason: $blockReason)' : ''}');
    }

    final firstCandidate = candidates.first as Map<String, dynamic>;
    final finishReason = firstCandidate['finishReason'] as String?;
    final reasonSuffix = finishReason != null ? ' (finishReason: $finishReason)' : '';

    final content = firstCandidate['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null) {
      throw Exception('no content in response$reasonSuffix');
    }

    Map<String, dynamic>? functionCallPart;
    for (final part in parts) {
      final map = part as Map<String, dynamic>;
      if (map.containsKey('functionCall')) {
        functionCallPart = map;
        break;
      }
    }
    if (functionCallPart == null) {
      throw Exception('no functionCall in response$reasonSuffix');
    }

    final functionCall = functionCallPart['functionCall'] as Map<String, dynamic>;
    final args = functionCall['args'] as Map<String, dynamic>;
    final rawItems = args['items'] as List<dynamic>;

    return rawItems.map((raw) {
      final map = raw as Map<String, dynamic>;
      return DealItem(
        name: (map['name'] as String).trim(),
        price: (map['price'] as String).trim(),
        unit: (map['unit'] as String? ?? '').trim(),
        category: DealCategoryLabel.fromLabel(map['category'] as String? ?? ''),
        storeName: storeName,
        pageIndex: (map['page'] as num).toInt(),
      );
    }).toList();
  }
}

const _systemPrompt = '''
You are extracting real grocery deals from OCR-style descriptions of grocery flyer pages. Each page's description is prose, not a delimited list, and may describe several items in one passage.

Some pages have no description, only their "Page N" label, followed by an image of the flyer page itself. For those, read the deals directly from the image and attribute them to that page number. If such a page says its image could not be loaded, record nothing for it.

For every real product deal you find, record:
- name: the cleaned product name. Remove narrative filler and price-connector language (e.g. "pour", "à", "ce qui revient à", "on trouve aussi"), but keep package size, brand, and format intact.
- price: the flat price if that's how it's listed, or the per-unit price if it's listed per unit (e.g. per lb/kg/100g).
- unit: the unit the price applies to (e.g. "lb", "kg", "100g", "each"), or an empty string if it's a flat price.
- category: exactly one of "Protein", "Vegetables", "Fruit", "Carbs", or "Uncategorized" - use "Uncategorized" rather than forcing a bad fit. Fruit (e.g. watermelon, apples, berries) is its own category, separate from Vegetables, even when sold in the produce section.
- page: the page number exactly as labeled in the input ("Page N:").

Skip:
- Page intros, theme, or promotional descriptions with no actual product or price.
- Duplicate mentions of the same item appearing more than once within the same page's description.

Call the record_items function with every item you find.
''';

const _recordItemsTool = {
  'functionDeclarations': [
    {
      'name': 'record_items',
      'description': 'Records every real grocery deal item found across the given flyer pages.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'items': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'name': {'type': 'STRING'},
                'price': {'type': 'STRING'},
                'unit': {'type': 'STRING'},
                'category': {
                  'type': 'STRING',
                  'enum': ['Protein', 'Vegetables', 'Fruit', 'Carbs', 'Uncategorized'],
                },
                'page': {'type': 'INTEGER'},
              },
              'required': ['name', 'price', 'unit', 'category', 'page'],
            },
          },
        },
        'required': ['items'],
      },
    },
  ],
};
