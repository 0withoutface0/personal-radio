enum ListeningPeriod {
  day('Day'),
  week('Week'),
  month('Month'),
  year('Year'),
  allTime('All time');

  const ListeningPeriod(this.label);
  final String label;
}

enum ListeningBucket { hour, day, month, year }

DateTime calendarDay(DateTime date) =>
    DateTime(date.year, date.month, date.day);

/// Use local calendar constructors for days and months. A day can contain
/// 23 or 25 elapsed hours, and adding 24 hours does not always reach midnight.
class ListeningRange {
  ListeningRange(this.period, this.anchor, {DateTime? firstPlayed}) {
    final day = calendarDay(anchor);
    switch (period) {
      case ListeningPeriod.day:
        bucket = ListeningBucket.hour;
        start = day;
        end = DateTime(day.year, day.month, day.day + 1);
      case ListeningPeriod.week:
        bucket = ListeningBucket.day;
        start = DateTime(day.year, day.month, day.day - (day.weekday - 1));
        end = DateTime(start.year, start.month, start.day + 7);
      case ListeningPeriod.month:
        bucket = ListeningBucket.day;
        start = DateTime(day.year, day.month);
        end = DateTime(day.year, day.month + 1);
      case ListeningPeriod.year:
        bucket = ListeningBucket.month;
        start = DateTime(day.year);
        end = DateTime(day.year + 1);
      case ListeningPeriod.allTime:
        final first = firstPlayed == null || firstPlayed.isAfter(day)
            ? day
            : calendarDay(firstPlayed);
        final days = DateTime.utc(
          day.year,
          day.month,
          day.day,
        ).difference(DateTime.utc(first.year, first.month, first.day)).inDays;
        final months = (day.year - first.year) * 12 + day.month - first.month;
        if (firstPlayed != null && days < 31) {
          bucket = ListeningBucket.day;
          start = first;
          end = DateTime(day.year, day.month, day.day + 1);
        } else if (months < 24) {
          bucket = ListeningBucket.month;
          start = firstPlayed == null
              ? DateTime(day.year, day.month - 11)
              : DateTime(first.year, first.month);
          end = DateTime(day.year, day.month + 1);
        } else {
          bucket = ListeningBucket.year;
          start = DateTime(first.year);
          end = DateTime(day.year + 1);
          yearStep = ((day.year - first.year + 1) / 24).ceil();
        }
    }
  }

  final ListeningPeriod period;
  final DateTime anchor;
  late final ListeningBucket bucket;
  late final DateTime start, end;
  int yearStep = 1;

  DateTime _next(DateTime value) => switch (bucket) {
    ListeningBucket.hour => value.add(const Duration(hours: 1)),
    ListeningBucket.day => DateTime(value.year, value.month, value.day + 1),
    ListeningBucket.month => DateTime(value.year, value.month + 1),
    ListeningBucket.year => DateTime(value.year + yearStep),
  };

  List<DateTime> get boundaries => [
    for (var date = start; date.isBefore(end); date = _next(date)) date,
    end,
  ];

  DateTime step(int direction) {
    if (direction > 0) return end;
    return DateTime(start.year, start.month, start.day - 1);
  }

  Map<String, dynamic> toRequest() => {
    'boundaries': boundaries.map((d) => d.toUtc().toIso8601String()).toList(),
    'all_time': period == ListeningPeriod.allTime,
  };
}
