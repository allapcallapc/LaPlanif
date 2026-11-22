class AiCallLog {
  const AiCallLog({
    required this.timestamp,
    required this.storeName,
    required this.model,
    required this.success,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.errorMessage,
    this.pageSample,
    this.details,
  });

  final DateTime timestamp;
  final String storeName;
  final String model;
  final bool success;
  final int inputTokens;
  final int outputTokens;
  final String? errorMessage;

  /// A short, human-readable summary of the raw flyer pages sent in this
  /// call (page count, average alt-text length, and a snippet of the first
  /// page) - lets the AI Usage screen show what was actually scraped
  /// without needing browser devtools, which is otherwise the only way to
  /// tell "the AI found nothing" apart from "there was nothing to find".
  final String? pageSample;

  /// Free-form diagnostic text about the call, shown alongside
  /// [pageSample] on the AI Usage screen - e.g. the meal plan preview's
  /// instructionCheck, the model's own account of how it applied the
  /// user's standing instructions.
  final String? details;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'storeName': storeName,
    'model': model,
    'success': success,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'errorMessage': errorMessage,
    'pageSample': pageSample,
    'details': details,
  };

  factory AiCallLog.fromJson(Map<String, dynamic> json) => AiCallLog(
    timestamp: DateTime.parse(json['timestamp'] as String),
    storeName: json['storeName'] as String,
    model: json['model'] as String,
    success: json['success'] as bool,
    inputTokens: json['inputTokens'] as int? ?? 0,
    outputTokens: json['outputTokens'] as int? ?? 0,
    errorMessage: json['errorMessage'] as String?,
    pageSample: json['pageSample'] as String?,
    details: json['details'] as String?,
  );
}
