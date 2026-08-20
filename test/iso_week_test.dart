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
}
