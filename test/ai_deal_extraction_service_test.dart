import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/flyer_page.dart';
import 'package:laplanif/services/ai_call_activity.dart';
import 'package:laplanif/services/ai_call_log_repository.dart';
import 'package:laplanif/services/ai_deal_extraction_service.dart';

http.Response _successResponse({
  int inputTokens = 100,
  int outputTokens = 50,
  required List<Map<String, dynamic>> items,
}) {
  return http.Response(
    jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'functionCall': {
                  'name': 'record_items',
                  'args': {'items': items},
                },
              },
            ],
            'role': 'model',
          },
        },
      ],
      'usageMetadata': {'promptTokenCount': inputTokens, 'candidatesTokenCount': outputTokens},
    }),
    200,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    AiCallActivity.inFlight.value = const [];
  });

  const pages = [FlyerPage(pageNumber: 1, altText: 'Poulet entier 3,99 \$ la lb.')];

  test('parses items from the functionCall response and logs a successful call', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent',
      );
      expect(request.headers['x-goog-api-key'], 'test-key');

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final tools = body['tools'] as List;
      expect(tools.length, 1);
      final declarations = (tools.single as Map)['functionDeclarations'] as List;
      expect(declarations.length, 1);
      expect((declarations.single as Map)['name'], 'record_items');
      expect(body['toolConfig'], isNotNull);
      // No search tool must ever be included in the request.
      expect(request.body.toLowerCase().contains('search'), isFalse);

      return _successResponse(
        items: [
          {'name': 'Poulet entier', 'price': '3.99\$', 'unit': 'lb', 'category': 'Protein', 'page': 1},
        ],
      );
    });

    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    final items = await service.extractItems(apiKey: 'test-key', storeName: 'IGA', pages: pages);

    expect(items.length, 1);
    expect(items[0].name, 'Poulet entier');
    expect(items[0].price, '3.99\$');
    expect(items[0].unit, 'lb');
    expect(items[0].category, DealCategory.protein);
    expect(items[0].storeName, 'IGA');
    expect(items[0].pageIndex, 1);

    final logs = await logRepository.loadAll();
    expect(logs.length, 1);
    expect(logs[0].success, isTrue);
    expect(logs[0].storeName, 'IGA');
    expect(logs[0].model, 'gemini-3.6-flash');
    expect(logs[0].inputTokens, 100);
    expect(logs[0].outputTokens, 50);
  });

  test('throws and logs a failure when the HTTP call fails', () async {
    final client = MockClient((request) async => http.Response('nope', 500));
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    await expectLater(
      service.extractItems(apiKey: 'test-key', storeName: 'Metro', pages: pages),
      throwsException,
    );

    final logs = await logRepository.loadAll();
    expect(logs.length, 1);
    expect(logs[0].success, isFalse);
    expect(logs[0].errorMessage, contains('HTTP 500'));
  });

  test('throws and logs a failure when the connection itself fails', () async {
    final client = MockClient((request) async => throw Exception('network down'));
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    await expectLater(
      service.extractItems(apiKey: 'test-key', storeName: 'Metro', pages: pages),
      throwsException,
    );

    expect((await logRepository.loadAll()).single.success, isFalse);
  });

  test('throws and logs a failure when the response body is not valid JSON', () async {
    final client = MockClient((request) async => http.Response('not json', 200));
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    await expectLater(
      service.extractItems(apiKey: 'test-key', storeName: 'Metro', pages: pages),
      throwsException,
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('Invalid JSON'));
  });

  test('throws and logs a failure when the response has no functionCall part', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Sorry, nothing found.'},
                ],
                'role': 'model',
              },
            },
          ],
          'usageMetadata': {'promptTokenCount': 10, 'candidatesTokenCount': 5},
        }),
        200,
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    await expectLater(
      service.extractItems(apiKey: 'test-key', storeName: 'Maxi', pages: pages),
      throwsA(anything),
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('no functionCall in response'));
    // Usage is still recorded even though parsing the output failed.
    expect(log.inputTokens, 10);
    expect(log.outputTokens, 5);
  });

  test('throws and logs a failure when no candidates are returned', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'candidates': <dynamic>[],
          'promptFeedback': {'blockReason': 'SAFETY'},
          'usageMetadata': {'promptTokenCount': 8, 'candidatesTokenCount': 0},
        }),
        200,
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    await expectLater(
      service.extractItems(apiKey: 'test-key', storeName: 'Metro', pages: pages),
      throwsA(anything),
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('no candidates returned (blockReason: SAFETY)'));
  });

  test('throws and logs a failure when a candidate has no content', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'candidates': [
            {'finishReason': 'MAX_TOKENS'},
          ],
          'usageMetadata': {'promptTokenCount': 8, 'candidatesTokenCount': 0},
        }),
        200,
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    await expectLater(
      service.extractItems(apiKey: 'test-key', storeName: 'Metro', pages: pages),
      throwsA(anything),
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('no content in response (finishReason: MAX_TOKENS)'));
  });

  test('retries once on HTTP 503 and succeeds on the second attempt', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      if (callCount == 1) {
        return http.Response('overloaded', 503);
      }
      return _successResponse(
        items: [
          {'name': 'Poulet entier', 'price': '3.99\$', 'unit': 'lb', 'category': 'Protein', 'page': 1},
        ],
      );
    });

    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(
      client: client,
      logRepository: logRepository,
      retryDelay: Duration.zero,
    );

    final items = await service.extractItems(apiKey: 'test-key', storeName: 'Maxi', pages: pages);

    expect(callCount, 2);
    expect(items.length, 1);
    final log = (await logRepository.loadAll()).single;
    expect(log.success, isTrue);
  });

  test('does not retry more than once on repeated HTTP 503', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      return http.Response('still overloaded', 503);
    });

    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(
      client: client,
      logRepository: logRepository,
      retryDelay: Duration.zero,
    );

    await expectLater(
      service.extractItems(apiKey: 'test-key', storeName: 'Maxi', pages: pages),
      throwsException,
    );

    expect(callCount, 2);
    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('HTTP 503'));
  });

  test('registers the call as in-flight while pending and clears it afterwards', () async {
    final requestStarted = Completer<void>();
    final releaseResponse = Completer<void>();
    final client = MockClient((request) async {
      requestStarted.complete();
      await releaseResponse.future;
      return _successResponse(
        items: [
          {'name': 'Poulet entier', 'price': '3.99\$', 'unit': 'lb', 'category': 'Protein', 'page': 1},
        ],
      );
    });

    final service = AiDealExtractionService(client: client, logRepository: AiCallLogRepository());

    expect(AiCallActivity.inFlight.value, isEmpty);
    final future = service.extractItems(apiKey: 'test-key', storeName: 'IGA', pages: pages);

    await requestStarted.future;
    expect(AiCallActivity.inFlight.value.length, 1);
    expect(AiCallActivity.inFlight.value.single.storeName, 'IGA');

    releaseResponse.complete();
    await future;

    expect(AiCallActivity.inFlight.value, isEmpty);
  });

  test('splits more than 15 pages into multiple calls and aggregates the results', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final userContent = (body['contents'] as List).single as Map<String, dynamic>;
      final text = ((userContent['parts'] as List).single as Map<String, dynamic>)['text'] as String;
      final pageCount = 'Page '.allMatches(text).length;
      return _successResponse(
        items: List.generate(
          pageCount,
          (i) => {
            'name': 'Item $callCount-$i',
            'price': '1.00\$',
            'unit': '',
            'category': 'Uncategorized',
            'page': i + 1,
          },
        ),
      );
    });

    final pagesList = List.generate(20, (i) => FlyerPage(pageNumber: i + 1, altText: 'Item $i 1,00 \$.'));
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    final items = await service.extractItems(apiKey: 'test-key', storeName: 'IGA', pages: pagesList);

    expect(callCount, 2);
    expect(items.length, 20);
    expect((await logRepository.loadAll()).length, 2);
  });
}
