/// The ISO 8601 week identifier (e.g. "2026-W34") for [date]'s week -
/// Monday-to-Sunday, with a week belonging to whichever year owns its
/// Thursday. Used as the stable key for one history entry per week: saving
/// twice in the same week must resolve to the same id regardless of which
/// day within the week the save happened on.
String isoWeekId(DateTime date) {
  final utcDate = DateTime.utc(date.year, date.month, date.day);
  final thursday = utcDate.add(Duration(days: 4 - utcDate.weekday));
  final jan1 = DateTime.utc(thursday.year, 1, 1);
  final weekNumber = (thursday.difference(jan1).inDays / 7).floor() + 1;
  return '${thursday.year}-W${weekNumber.toString().padLeft(2, '0')}';
}
