import 'package:flutter/foundation.dart';

/// One AI extraction call currently in flight.
class AiInFlightCall {
  const AiInFlightCall({required this.id, required this.storeName, required this.model, required this.startedAt});

  final int id;
  final String storeName;
  final String model;
  final DateTime startedAt;
}

/// Process-wide, in-memory-only registry of AI extraction calls currently in
/// flight, so the AI usage screen can show "running now" alongside the
/// persisted history. Never written to disk - a page refresh clears it, same
/// as the in-flight calls themselves.
class AiCallActivity {
  AiCallActivity._();

  static final ValueNotifier<List<AiInFlightCall>> inFlight = ValueNotifier(const []);

  static int _nextId = 0;

  static int start({required String storeName, required String model}) {
    final id = _nextId++;
    inFlight.value = [
      ...inFlight.value,
      AiInFlightCall(id: id, storeName: storeName, model: model, startedAt: DateTime.now()),
    ];
    return id;
  }

  static void finish(int id) {
    inFlight.value = inFlight.value.where((call) => call.id != id).toList();
  }
}
