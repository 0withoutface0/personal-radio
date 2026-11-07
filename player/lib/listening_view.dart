import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'listening_range.dart';
import 'radio_controller.dart';

enum _SongRank {
  time('Time listened', 'top_songs'),
  plays('Most played', 'most_played'),
  likes('Liked', 'liked_songs');

  const _SongRank(this.label, this.key);
  final String label, key;
}

String _timeLabel(num seconds) {
  if (seconds <= 0) return '0 min';
  final whole = seconds.round();
  if (whole == 0) return '<1 sec';
  if (whole < 60) return '$whole sec';
  final hours = whole ~/ 3600;
  final minutes = whole ~/ 60 % 60;
  if (hours == 0) return '$minutes min';
  return minutes == 0 ? '$hours h' : '$hours h $minutes min';
}

class ListeningView extends StatefulWidget {
  const ListeningView({super.key, required this.radio});
  final RadioController radio;

  @override
  State<ListeningView> createState() => _ListeningViewState();
}

class _ListeningViewState extends State<ListeningView> {
  ListeningPeriod period = ListeningPeriod.week;
  DateTime anchor = DateTime.now();
  DateTime? firstPlayed;
  ListeningRange? shownRange;
  Map<String, dynamic>? stats;
  String? error;
  bool loading = false,
      oldServer = false,
      moreSongs = false,
      moreArtists = false;
  int requestId = 0;
  RadioApi? client;
  _SongRank rank = _SongRank.time;

  RadioController get radio => widget.radio;
  ColorScheme get colors => Theme.of(context).colorScheme;
  MaterialLocalizations get dates => MaterialLocalizations.of(context);
  ListeningRange get range => ListeningRange(
    period,
    period == ListeningPeriod.allTime ? DateTime.now() : anchor,
    firstPlayed: firstPlayed,
  );
  List<Map<String, dynamic>> rows(String key) =>
      ((oldServer ? radio.report : stats)?[key] as List? ?? [])
          .cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(ListeningView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(client, radio.api)) unawaited(_load(clear: true));
  }

  Future<void> _load({bool clear = false}) async {
    final request = ++requestId;
    final selected = range;
    final api = radio.api;
    client = api;
    setState(() {
      if (clear) stats = null;
      error = null;
      oldServer = false;
      loading = api != null && radio.ready;
    });
    if (!loading || api == null) return;
    try {
      final result = Map<String, dynamic>.from(
        await api.call(
          '/api/listening',
          body: selected.toRequest(),
          timeout: const Duration(seconds: 12),
        ),
      );
      if (!mounted || request != requestId || !identical(api, radio.api)) {
        return;
      }
      setState(() {
        stats = result;
        shownRange = selected;
        firstPlayed = DateTime.tryParse(result['first_played_at'] ?? '')
            ?.toLocal();
      });
    } catch (failure) {
      if (!mounted || request != requestId) return;
      setState(() {
        oldServer = failure is ApiFailure && failure.status == 404;
        error = oldServer
            ? 'Update the radio server to see listening charts and date ranges.'
            : stats == null
            ? 'Could not load listening statistics. Try refreshing.'
            : 'Could not refresh. Showing the previous results for this period.';
      });
    } finally {
      if (mounted && request == requestId) setState(() => loading = false);
    }
  }

  Future<void> _refresh() async {
    await Future.wait([_load(), radio.refreshReport()]);
  }

  Future<void> _sync() async {
    await radio.sync();
    if (mounted) await _refresh();
  }

  void _select(ListeningPeriod next, DateTime date) {
    setState(() {
      period = next;
      anchor = date;
      moreSongs = moreArtists = false;
    });
    unawaited(_load(clear: true));
  }

  Future<void> _pickDate() async {
    final today = calendarDay(DateTime.now());
    final first = firstPlayed == null
        ? DateTime(2000)
        : calendarDay(firstPlayed!);
    final minimum = first.isAfter(today) ? today : first;
    final initial = calendarDay(anchor);
    final selected = await showDatePicker(
      context: context,
      firstDate: minimum,
      lastDate: today,
      initialDate: initial.isBefore(minimum)
          ? minimum
          : initial.isAfter(today)
          ? today
          : initial,
    );
    if (mounted && selected != null) _select(period, selected);
  }

  String _rangeLabel(ListeningRange value) => switch (value.period) {
    ListeningPeriod.day => dates.formatFullDate(value.start),
    ListeningPeriod.week =>
      '${dates.formatShortDate(value.start)} – ${dates.formatShortDate(DateTime(value.end.year, value.end.month, value.end.day - 1))}',
    ListeningPeriod.month => dates.formatMonthYear(value.start),
    ListeningPeriod.year => '${value.start.year}',
    ListeningPeriod.allTime =>
      firstPlayed == null
          ? 'All recorded listening'
          : 'Since ${dates.formatShortDate(firstPlayed!)}',
  };

  Widget _periodControls() {
    final selected = range;
    final canGoBack =
        firstPlayed != null &&
        selected.start.isAfter(calendarDay(firstPlayed!));
    final canGoForward = !selected.end.isAfter(calendarDay(DateTime.now()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 7,
          runSpacing: 5,
          children: [
            for (final option in ListeningPeriod.values)
              ChoiceChip(
                label: Text(option.label),
                selected: period == option,
                onSelected: (_) {
                  if (period != option) _select(option, DateTime.now());
                },
              ),
          ],
        ),
        if (period == ListeningPeriod.allTime)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _rangeLabel(selected),
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          )
        else
          Row(
            children: [
              IconButton(
                tooltip: 'Previous ${period.label.toLowerCase()}',
                onPressed: canGoBack
                    ? () => _select(period, selected.step(-1))
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: TextButton(
                  onPressed: _pickDate,
                  child: Text(
                    _rangeLabel(selected),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next ${period.label.toLowerCase()}',
                onPressed: canGoForward
                    ? () => _select(period, selected.step(1))
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
      ],
    );
  }

  Widget _summary(Map totals) {
    final theme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              colors: [colors.primaryContainer, colors.surfaceContainerHigh],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.headphones_rounded, color: colors.onPrimaryContainer),
              const SizedBox(height: 8),
              Text(
                _timeLabel(totals['listened_seconds'] as num? ?? 0),
                style: theme.headlineLarge?.copyWith(
                  color: colors.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Time listened',
                style: theme.bodyMedium?.copyWith(
                  color: colors.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metric(
              Icons.play_circle_outline,
              totals['plays'] ?? totals['occurrences'],
              'Plays',
            ),
            _metric(Icons.music_note_rounded, totals['songs'], 'Songs'),
            _metric(Icons.group_outlined, totals['artists'], 'Artist credits'),
          ],
        ),
      ],
    );
  }

  Widget _metric(IconData icon, Object? value, String label) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Column(
            children: [
              Icon(icon, size: 18, color: colors.primary),
              const SizedBox(height: 3),
              Text(
                '${value ?? '—'}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _rankingRow(
    Map<String, dynamic> row,
    int index,
    num maximum, {
    bool artist = false,
  }) {
    final plays = row['plays'] as int?;
    final seconds = row['listened_seconds'] as num;
    final value = !artist && !oldServer && rank == _SongRank.plays
        ? plays ?? 0
        : seconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: colors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (artist ? row['artist'] : row['title']) as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (!artist)
                  Text(
                    row['artist'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: maximum == 0 ? 0 : (value / maximum).clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: colors.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
          if (row['liked'] == true)
            Padding(
              padding: const EdgeInsets.only(left: 7),
              child: Tooltip(
                message: 'Liked in Personal Radio',
                child: Icon(Icons.favorite, size: 14, color: colors.primary),
              ),
            ),
          const SizedBox(width: 9),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_timeLabel(seconds)),
              if (plays != null)
                Text(
                  '$plays ${plays == 1 ? 'play' : 'plays'}',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _rankings({required bool artist}) {
    final entries = rows(
      artist
          ? 'top_artists'
          : oldServer
          ? 'top_songs'
          : rank.key,
    );
    final visible = artist ? moreArtists : moreSongs;
    final count = visible ? entries.length : math.min(5, entries.length);
    final maximum = entries.isEmpty
        ? 0
        : entries.first[!artist && !oldServer && rank == _SongRank.plays
                  ? 'plays'
                  : 'listened_seconds']
              as num;
    return _panel(
      title: artist ? 'Top artists' : 'Top songs',
      children: [
        if (!artist && !oldServer)
          Wrap(
            spacing: 6,
            children: [
              for (final option in _SongRank.values)
                ChoiceChip(
                  label: Text(option.label),
                  selected: rank == option,
                  onSelected: (_) => setState(() {
                    rank = option;
                    moreSongs = false;
                  }),
                ),
            ],
          ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              rank == _SongRank.likes && !artist
                  ? 'No songs you liked in the app were played in this period.'
                  : 'Your rankings will appear after you listen.',
            ),
          ),
        for (var i = 0; i < count; i++)
          _rankingRow(entries[i], i, maximum, artist: artist),
        if (entries.length > 5)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() {
                if (artist) {
                  moreArtists = !visible;
                } else {
                  moreSongs = !visible;
                }
              }),
              child: Text(visible ? 'Show less' : 'Show all ${entries.length}'),
            ),
          ),
      ],
    );
  }

  Widget _rankingPanels() => LayoutBuilder(
    builder: (context, constraints) {
      final songs = _rankings(artist: false);
      final artists = _rankings(artist: true);
      if (constraints.maxWidth < 620) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [songs, artists],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: songs),
          const SizedBox(width: 10),
          Expanded(child: artists),
        ],
      );
    },
  );

  Widget _panel({required String title, required List<Widget> children}) =>
      Card(
        margin: const EdgeInsets.only(top: 10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  Widget _reporting() {
    final submissions = (radio.report?['submissions'] as List? ?? []).reversed
        .take(30);
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.sync),
            title: Text('${radio.outbox.length} events waiting on this device'),
            trailing: TextButton(
              onPressed: radio.ready ? _sync : null,
              child: const Text('Sync now'),
            ),
          ),
          ExpansionTile(
            title: const Text('Activity reporting'),
            subtitle: const Text('YouTube Recap remains unverified'),
            children: [
              if (submissions.isEmpty)
                const ListTile(
                  subtitle: Text(
                    'Plays become eligible after 30 seconds of listening or completion of a shorter track.',
                  ),
                ),
              for (final row in submissions)
                ListTile(
                  leading: Icon(
                    row['state'] == 'visible'
                        ? Icons.check_circle_outline
                        : row['state'] == 'uncertain'
                        ? Icons.help_outline
                        : Icons.schedule,
                  ),
                  title: Text(
                    '${row['provider'] == 'tidal' || row['kind'].toString().startsWith('tidal_favorite')
                        ? 'Tidal favorite'
                        : row['kind'].toString().startsWith('rating')
                        ? 'YouTube rating'
                        : 'YouTube history'} · ${row['state']}',
                  ),
                  subtitle: Text(row['detail'] ?? ''),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totals = stats?['totals'] as Map?;
    final repeat = rows('most_played').firstOrNull;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'YOUR LISTENING',
                  style: TextStyle(
                    color: colors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.4,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Refresh listening data',
                onPressed: loading ? null : _refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          Text(
            'Listening activity',
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (!oldServer) _periodControls(),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(error!),
              contentPadding: EdgeInsets.zero,
            ),
          if (!radio.ready)
            const ListTile(
              title: Text('Connect your server to see listening activity.'),
            ),
          if (oldServer && radio.report?['totals'] is Map) ...[
            _summary(radio.report!['totals'] as Map),
            _rankingPanels(),
          ],
          if (totals != null) ...[
            _summary(totals),
            _panel(
              title: 'Listening over time',
              children: [
                if ((totals['listened_seconds'] as num) == 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('No listening in this period.'),
                  )
                else
                  _ListeningChart(
                    key: ValueKey((
                      shownRange!.period,
                      shownRange!.start,
                      shownRange!.bucket,
                    )),
                    buckets: rows('buckets'),
                    unit: shownRange!.bucket,
                  ),
              ],
            ),
            if (repeat != null && (repeat['plays'] as int) > 1)
              Card(
                margin: const EdgeInsets.only(top: 10),
                child: ListTile(
                  leading: Icon(Icons.repeat_rounded, color: colors.primary),
                  title: Text(
                    repeat['title'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    'On repeat · ${repeat['plays']} plays · ${repeat['artist']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            _rankingPanels(),
          ],
          _reporting(),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

class _ListeningChart extends StatefulWidget {
  const _ListeningChart({super.key, required this.buckets, required this.unit});
  final List<Map<String, dynamic>> buckets;
  final ListeningBucket unit;

  @override
  State<_ListeningChart> createState() => _ListeningChartState();
}

class _ListeningChartState extends State<_ListeningChart> {
  int? selected;

  String _label(Map<String, dynamic> row, {bool short = false}) {
    if (row['start'] == null) return short ? 'Prior' : 'Earlier listening';
    final date = DateTime.parse(row['start'] as String).toLocal();
    final local = MaterialLocalizations.of(context);
    return switch (widget.unit) {
      ListeningBucket.hour =>
        short
            ? '${date.hour}'
            : '${local.formatTimeOfDay(TimeOfDay.fromDateTime(date))} ${date.timeZoneName}',
      ListeningBucket.day =>
        short ? '${date.day}' : local.formatMediumDate(date),
      ListeningBucket.month =>
        short
            ? '${date.month}/${date.year % 100}'
            : local.formatMonthYear(date),
      ListeningBucket.year => '${date.year}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final buckets = widget.buckets;
    if (buckets.isEmpty) return const SizedBox.shrink();
    final seconds = buckets
        .map((row) => row['listened_seconds'] as num)
        .toList();
    final peak = seconds.indexOf(seconds.reduce(math.max));
    final active = selected == null || selected! >= buckets.length
        ? peak
        : selected!;
    final maximum = math.max(seconds[peak], 1);
    final colors = Theme.of(context).colorScheme;
    final activeLabel = _label(buckets[active]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${selected == null ? 'Peak · ' : ''}$activeLabel · ${_timeLabel(seconds[active])}',
          style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final minimum = switch (widget.unit) {
              ListeningBucket.month || ListeningBucket.year => 42.0,
              _ => 20.0,
            };
            final slot = math.max(
              constraints.maxWidth / buckets.length,
              minimum,
            );
            final step = math.max(1, (buckets.length / 7).ceil());
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: slot * buckets.length,
                child: Stack(
                  children: [
                    Positioned.fill(
                      bottom: 24,
                      child: IgnorePointer(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: List.generate(
                            4,
                            (_) => Divider(
                              color: colors.outlineVariant,
                              thickness: 1,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < buckets.length; i++)
                          SizedBox(
                            width: slot,
                            child: Tooltip(
                              message:
                                  '${_label(buckets[i])} · ${_timeLabel(seconds[i])}',
                              child: Semantics(
                                selected: i == active,
                                button: true,
                                child: InkWell(
                                  onTap: () => setState(() => selected = i),
                                  borderRadius: BorderRadius.circular(5),
                                  child: Column(
                                    children: [
                                      SizedBox(
                                        height: 108,
                                        child: Align(
                                          alignment: Alignment.bottomCenter,
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                              milliseconds: 180,
                                            ),
                                            width: math.min(35, slot * .66),
                                            height: math.max(
                                              2,
                                              seconds[i] / maximum * 104,
                                            ),
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                    top: Radius.circular(5),
                                                  ),
                                              color: i == active
                                                  ? colors.primary
                                                  : seconds[i] > 0
                                                  ? colors.secondary
                                                  : colors.outlineVariant,
                                            ),
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        height: 23,
                                        child: i % step == 0 || i == active
                                            ? Center(
                                                child: Text(
                                                  _label(
                                                    buckets[i],
                                                    short: true,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.clip,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .labelSmall,
                                                ),
                                              )
                                            : null,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        Text(
          'By ${widget.unit.name} · Tap a bar to explore',
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}
