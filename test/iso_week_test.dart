import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/utils/iso_week.dart';

void main() {
  test('computes the ISO week id for a mid-week date', () {
    // 2026-08-20 is a Thursday.
    expect(isoWeekId(DateTime(2026, 8, 20)), '2026-W34');
  });

  test('every day within the same Mon-Sun week shares the same id', () {
    final monday = DateTime(2026, 8, 17);
    for (var i = 0; i < 7; i++) {
      expect(isoWeekId(monday.add(Duration(days: i))), '2026-W34');
    }
  });

  test('a week spanning the new year attributes to the year owning its Thursday', () {
    // 2023-01-01 is a Sunday, whose week's Thursday (2022-12-29) is in 2022 -
    // that week belongs to ISO week 52 of 2022, not week 1 of 2023.
    expect(isoWeekId(DateTime(2023, 1, 1)), '2022-W52');
    expect(isoWeekId(DateTime(2023, 1, 2)), '2023-W01');
  });

  test('week numbers are zero-padded to two digits', () {
    expect(isoWeekId(DateTime(2026, 1, 5)), '2026-W02');
  });

  test('mondayOfIsoWeek returns the Monday of a mid-year week', () {
    final monday = mondayOfIsoWeek('2026-W34');
    expect(monday.year, 2026);
    expect(monday.month, 8);
    expect(monday.day, 17);
    expect(monday.weekday, DateTime.monday);
  });

  test('mondayOfIsoWeek round-trips with isoWeekId across a full year', () {
    for (var week = 1; week <= 52; week++) {
      final id = '2026-W${week.toString().padLeft(2, '0')}';
      expect(isoWeekId(mondayOfIsoWeek(id)), id);
    }
  });

  test('mondayOfIsoWeek round-trips across a year boundary', () {
    expect(isoWeekId(mondayOfIsoWeek('2022-W52')), '2022-W52');
    expect(isoWeekId(mondayOfIsoWeek('2023-W01')), '2023-W01');
  });
}
