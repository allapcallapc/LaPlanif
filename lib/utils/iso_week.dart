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

/// The Monday of the ISO week identified by [weekId] (e.g. "2026-W34") -
/// the inverse of [isoWeekId], used to seed a date picker on the date
/// already assigned to a saved week rather than defaulting to today. Jan 4
/// always falls in ISO week 1 of its year, so week 1's Monday is Jan 4
/// walked back to the start of its own week.
DateTime mondayOfIsoWeek(String weekId) {
  final parts = weekId.split('-W');
  final year = int.parse(parts[0]);
  final week = int.parse(parts[1]);
  final jan4 = DateTime.utc(year, 1, 4);
  final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
  return week1Monday.add(Duration(days: (week - 1) * 7));
}
