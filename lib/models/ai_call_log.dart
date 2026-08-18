class AiCallLog {
  const AiCallLog({
    required this.timestamp,
    required this.storeName,
    required this.model,
    required this.success,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.errorMessage,
  });

  final DateTime timestamp;
  final String storeName;
  final String model;
  final bool success;
  final int inputTokens;
  final int outputTokens;
  final String? errorMessage;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'storeName': storeName,
    'model': model,
    'success': success,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'errorMessage': errorMessage,
  };

  factory AiCallLog.fromJson(Map<String, dynamic> json) => AiCallLog(
    timestamp: DateTime.parse(json['timestamp'] as String),
    storeName: json['storeName'] as String,
    model: json['model'] as String,
    success: json['success'] as bool,
    inputTokens: json['inputTokens'] as int? ?? 0,
    outputTokens: json['outputTokens'] as int? ?? 0,
    errorMessage: json['errorMessage'] as String?,
  );
}
