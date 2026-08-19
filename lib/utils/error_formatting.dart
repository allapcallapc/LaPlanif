/// Strips the redundant "Exception: " prefix Dart's default [Exception]
/// adds to its [toString], so error messages read cleanly in logs and UI.
String stripExceptionPrefix(Object error) => error.toString().replaceFirst('Exception: ', '');
