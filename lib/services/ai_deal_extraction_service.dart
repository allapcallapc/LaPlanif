import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_call_log.dart';
import '../models/deal_item.dart';
import '../models/flyer_page.dart';
import 'ai_call_log_repository.dart';

/// Turns raw per-page flyer alt text into structured deal items using the
/// Google AI (Gemini) API - no local splitting/parsing heuristics. Every
/// call (success or failure) is recorded via [AiCallLogRepository] so usage
/// can be reviewed later.
class AiDealExtractionService {
  AiDealExtractionService({http.Client? client, this.model = _defaultModel, AiCallLogRepository? logRepository})
    : _client = client ?? http.Client(),
      _logRepository = logRepository ?? AiCallLogRepository();

  static const _defaultModel = 'gemini-3.6-flash';
  static const _apiBase = 'https://generativelanguage.googleapis.com/v1beta/models';

  /// Flyers can run to dozens of pages; keep each call to a bounded chunk
  /// rather than sending an entire flyer in one request.
  static const _maxPagesPerCall = 15;

  final http.Client _client;
  final AiCallLogRepository _logRepository;
  final String model;

  Future<List<DealItem>> extractItems({
    required String apiKey,
    required String storeName,
    required List<FlyerPage> pages,
  }) async {
    final items = <DealItem>[];
    for (var start = 0; start < pages.length; start += _maxPagesPerCall) {
      final end = (start + _maxPagesPerCall).clamp(0, pages.length);
      items.addAll(
        await _extractBatch(apiKey: apiKey, storeName: storeName, pages: pages.sublist(start, end)),
      );
    }
    return items;
  }

  Future<List<DealItem>> _extractBatch({
    required String apiKey,
    required String storeName,
    required List<FlyerPage> pages,
  }) async {
    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse('$_apiBase/$model:generateContent'),
        headers: {'x-goog-api-key': apiKey, 'content-type': 'application/json'},
        body: jsonEncode(_buildRequestBody(pages)),
      );
    } catch (_) {
      await _log(storeName: storeName, success: false, errorMessage: 'Could not reach the AI API');
      throw Exception('Could not reach the AI API');
    }

    if (response.statusCode != 200) {
      await _log(storeName: storeName, success: false, errorMessage: 'AI API HTTP ${response.statusCode}');
      throw Exception('AI API HTTP ${response.statusCode}');
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      await _log(storeName: storeName, success: false, errorMessage: 'Invalid JSON from the AI API');
      throw Exception('Invalid JSON from the AI API');
    }

    final usage = decoded['usageMetadata'] as Map<String, dynamic>?;
    final inputTokens = (usage?['promptTokenCount'] as num?)?.toInt() ?? 0;
    final outputTokens = (usage?['candidatesTokenCount'] as num?)?.toInt() ?? 0;

    try {
      final items = _parseItems(decoded, storeName);
      await _log(
        storeName: storeName,
        success: true,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
      );
      return items;
    } catch (_) {
      await _log(
        storeName: storeName,
        success: false,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        errorMessage: 'Could not parse structured output from the AI response',
      );
      rethrow;
    }
  }

  Future<void> _log({
    required String storeName,
    required bool success,
    int inputTokens = 0,
    int outputTokens = 0,
    String? errorMessage,
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
      ),
    );
  }

  Map<String, dynamic> _buildRequestBody(List<FlyerPage> pages) {
    final labeledPages = pages.map((p) => 'Page ${p.pageNumber}:\n${p.altText}').join('\n\n');

    return {
      'systemInstruction': {
        'parts': [
          {'text': _systemPrompt},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': labeledPages},
          ],
        },
      ],
      'tools': [_recordItemsTool],
      'toolConfig': {
        'functionCallingConfig': {
          'mode': 'ANY',
          'allowedFunctionNames': ['record_items'],
        },
      },
      'generationConfig': {'maxOutputTokens': 8192},
    };
  }

  List<DealItem> _parseItems(Map<String, dynamic> decoded, String storeName) {
    final candidates = decoded['candidates'] as List<dynamic>;
    final firstCandidate = candidates.first as Map<String, dynamic>;
    final content = firstCandidate['content'] as Map<String, dynamic>;
    final parts = content['parts'] as List<dynamic>;
    final functionCallPart =
        parts.firstWhere((part) => (part as Map<String, dynamic>).containsKey('functionCall'))
            as Map<String, dynamic>;
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

For every real product deal you find, record:
- name: the cleaned product name. Remove narrative filler and price-connector language (e.g. "pour", "à", "ce qui revient à", "on trouve aussi"), but keep package size, brand, and format intact.
- price: the flat price if that's how it's listed, or the per-unit price if it's listed per unit (e.g. per lb/kg/100g).
- unit: the unit the price applies to (e.g. "lb", "kg", "100g", "each"), or an empty string if it's a flat price.
- category: exactly one of "Protein", "Vegetables", "Carbs", or "Uncategorized" - use "Uncategorized" rather than forcing a bad fit.
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
                  'enum': ['Protein', 'Vegetables', 'Carbs', 'Uncategorized'],
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
