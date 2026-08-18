import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/flyer_page.dart';
import 'package:laplanif/services/ai_call_log_repository.dart';
import 'package:laplanif/services/ai_deal_extraction_service.dart';

http.Response _successResponse({
  int inputTokens = 100,
  int outputTokens = 50,
  required List<Map<String, dynamic>> items,
}) {
  return http.Response(
    jsonEncode({
      'content': [
        {
          'type': 'tool_use',
          'name': 'record_items',
          'input': {'items': items},
        },
      ],
      'usage': {'input_tokens': inputTokens, 'output_tokens': outputTokens},
    }),
    200,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const pages = [FlyerPage(pageNumber: 1, altText: 'Poulet entier 3,99 \$ la lb.')];

  test('parses items from the tool_use response and logs a successful call', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(request.headers['x-api-key'], 'sk-test');
      expect(request.headers['anthropic-dangerous-direct-browser-access'], 'true');

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final tools = body['tools'] as List;
      expect(tools.length, 1);
      expect((tools.single as Map)['name'], 'record_items');
      // No web search tool must ever be included in the request.
      expect(request.body.contains('web_search'), isFalse);

      return _successResponse(
        items: [
          {'name': 'Poulet entier', 'price': '3.99\$', 'unit': 'lb', 'category': 'Protein', 'page': 1},
        ],
      );
    });

    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    final items = await service.extractItems(apiKey: 'sk-test', storeName: 'IGA', pages: pages);

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
    expect(logs[0].inputTokens, 100);
    expect(logs[0].outputTokens, 50);
  });

  test('throws and logs a failure when the HTTP call fails', () async {
    final client = MockClient((request) async => http.Response('nope', 500));
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    await expectLater(
      service.extractItems(apiKey: 'sk-test', storeName: 'Metro', pages: pages),
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
      service.extractItems(apiKey: 'sk-test', storeName: 'Metro', pages: pages),
      throwsException,
    );

    expect((await logRepository.loadAll()).single.success, isFalse);
  });

  test('throws and logs a failure when the response body is not valid JSON', () async {
    final client = MockClient((request) async => http.Response('not json', 200));
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    await expectLater(
      service.extractItems(apiKey: 'sk-test', storeName: 'Metro', pages: pages),
      throwsException,
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('Invalid JSON'));
  });

  test('throws and logs a failure when the response has no tool_use block', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'content': [
            {'type': 'text', 'text': 'Sorry, nothing found.'},
          ],
          'usage': {'input_tokens': 10, 'output_tokens': 5},
        }),
        200,
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = AiDealExtractionService(client: client, logRepository: logRepository);

    await expectLater(
      service.extractItems(apiKey: 'sk-test', storeName: 'Maxi', pages: pages),
      throwsA(anything),
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    // Usage is still recorded even though parsing the output failed.
    expect(log.inputTokens, 10);
    expect(log.outputTokens, 5);
  });

  test('splits more than 15 pages into multiple calls and aggregates the results', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final userMessage = (body['messages'] as List).single as Map<String, dynamic>;
      final pageCount = 'Page '.allMatches(userMessage['content'] as String).length;
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

    final items = await service.extractItems(apiKey: 'sk-test', storeName: 'IGA', pages: pagesList);

    expect(callCount, 2);
    expect(items.length, 20);
    expect((await logRepository.loadAll()).length, 2);
  });
}
