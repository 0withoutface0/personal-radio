import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'catalog_view.dart';
import 'models.dart';
import 'radio_controller.dart';
import 'song_actions.dart';

const lime = Color(0xFFD5F887),
    ink = Color(0xFF111410),
    panel = Color(0xFF1C211B);

class RadioApp extends StatelessWidget {
  final RadioController radio;
  const RadioApp({super.key, required this.radio});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Personal Radio',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ink,
      colorScheme: ColorScheme.fromSeed(
        seedColor: lime,
        brightness: Brightness.dark,
      ).copyWith(primary: lime, onPrimary: ink, surface: panel),
      fontFamily: 'Segoe UI',
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
    ),
    home: RadioHome(radio: radio),
  );
}

class RadioHome extends StatefulWidget {
  final RadioController radio;
  const RadioHome({super.key, required this.radio});
  @override
  State<RadioHome> createState() => _RadioHomeState();
}

class _RadioHomeState extends State<RadioHome> {
  RadioController get r => widget.radio;
  int tab = 0;
  final catalogKey = GlobalKey<CatalogViewState>();
  double? draggingPosition;
  final search = TextEditingController(), focus = FocusNode();
  final labels = const ['Discover', 'Stations', 'Queue', 'Listening'];
  final icons = const [
    Icons.search_rounded,
    Icons.radio_rounded,
    Icons.queue_music_rounded,
    Icons.insights_rounded,
  ];
  @override
  void dispose() {
    search.dispose();
    focus.dispose();
    super.dispose();
  }

  void changeTab(int value) {
    setState(() => tab = value);
    if (value == 3) unawaited(r.refreshReport());
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: r,
    builder: (context, _) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          changeTab(0);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) catalogKey.currentState?.focusSearch();
          });
        },
      },
      child: FocusScope(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, size) {
            final wide = size.maxWidth >= 1000;
            return Scaffold(
              body: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: lime,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.graphic_eq, color: ink),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'PERSONAL RADIO',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                          if (wide)
                            Text(
                              r.connectionMessage ?? 'Connect your server',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                            ),
                          IconButton(
                            tooltip: 'Connection settings',
                            onPressed: settings,
                            icon: const Icon(Icons.settings_outlined),
                          ),
                        ],
                      ),
                    ),
                    if (r.error != null)
                      Container(
                        color: const Color(0xFF463421),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                r.error!,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            if (r.error!.contains('Another device'))
                              TextButton(
                                onPressed: r.takeover,
                                child: const Text('Take over'),
                              ),
                            IconButton(
                              onPressed: () {
                                r.error = null;
                                r.update();
                              },
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: !r.ready
                          ? connectScreen()
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (wide) sidebar(),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      24,
                                      18,
                                      24,
                                      12,
                                    ),
                                    child: content(),
                                  ),
                                ),
                                if (wide)
                                  SizedBox(
                                    width: 310,
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        0,
                                        18,
                                        20,
                                        12,
                                      ),
                                      child: nowPlaying(),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    if (r.ready && r.current != null) transport(wide),
                  ],
                ),
              ),
              bottomNavigationBar: !wide && r.ready
                  ? NavigationBar(
                      selectedIndex: tab,
                      onDestinationSelected: changeTab,
                      destinations: List.generate(
                        4,
                        (i) => NavigationDestination(
                          icon: Icon(icons[i]),
                          label: labels[i],
                        ),
                      ),
                    )
                  : null,
            );
          },
        ),
      ),
    ),
  );
  Widget connectScreen() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 530),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.radio_rounded, size: 66, color: lime),
            const SizedBox(height: 24),
            const Text(
              'A radio that knows you.',
              style: TextStyle(
                fontSize: 36,
                height: 1.15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your YouTube Music recommendations, played from Tidal in lossless quality.',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 16,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: settings,
              icon: const Icon(Icons.link),
              label: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Connect your server'),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Use your private server address and device access token. Provider accounts stay on the server.',
              style: TextStyle(color: Colors.white38, height: 1.5),
            ),
          ],
        ),
      ),
    ),
  );
  Widget sidebar() => Container(
    width: 190,
    padding: const EdgeInsets.fromLTRB(16, 22, 12, 20),
    decoration: const BoxDecoration(
      border: Border(right: BorderSide(color: Colors.white10)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...List.generate(
          4,
          (i) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(icons[i]),
              title: Text(labels[i]),
              selected: tab == i,
              selectedColor: lime,
              selectedTileColor: lime.withValues(alpha: .08),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              onTap: () => changeTab(i),
            ),
          ),
        ),
        const Spacer(),
        const Text(
          'YOUTUBE MUSIC\n× TIDAL',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white38,
            letterSpacing: 2,
            height: 1.8,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          r.outbox.isEmpty
              ? 'Listening events synced'
              : '${r.outbox.length} events saved locally',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
    ),
  );
  Widget heading(String eyebrow, String title, [String? subtitle]) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow.toUpperCase(),
          style: const TextStyle(
            color: lime,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.4,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              subtitle,
              style: const TextStyle(color: Colors.white54, height: 1.5),
            ),
          ),
      ],
    ),
  );
  Widget content() => switch (tab) {
    0 => discover(),
    1 => stationList(),
    2 => queueList(),
    _ => listening(),
  };
  Widget discover() =>
      CatalogView(key: catalogKey, radio: r, search: search, focus: focus);
  Widget stationList() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      heading(
        'Made for you',
        'Your stations',
        'Personalized mixes from your signed-in YouTube Music account.',
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: r.loadStations,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh'),
        ),
      ),
      Expanded(
        child: r.stations.isEmpty
            ? const Center(
                child: Text(
                  'No stations found yet. Refresh to check your account.',
                  style: TextStyle(color: Colors.white54),
                ),
              )
            : ListView.builder(
                itemCount: r.stations.length,
                itemBuilder: (context, i) {
                  final s = r.stations[i];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(18),
                      leading: const Icon(Icons.radio, color: lime),
                      title: Text(s['title'] ?? 'Station'),
                      subtitle: Text(s['section'] ?? ''),
                      trailing: const Icon(Icons.play_arrow_rounded),
                      onTap: r.busy ? null : () => r.start(station: s),
                    ),
                  );
                },
              ),
      ),
    ],
  );
  Widget queueList() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      heading(
        r.mode == 'queue'
            ? 'Queue'
            : r.mode == 'autoplay'
            ? 'Autoplay'
            : 'Radio',
        'Coming up',
        r.queueTitle,
      ),
      if (r.entries.isNotEmpty && r.current == null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FilledButton.icon(
            onPressed: r.changingQueue ? null : r.play,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play queue'),
          ),
        ),
      if (r.entries.any((entry) => entry.status == 'skipped'))
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: OutlinedButton.icon(
            onPressed: r.retryingMatches ? null : r.retrySkippedMatches,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(
              r.retryingMatches ? 'Checking matches…' : 'Retry skipped matches',
            ),
          ),
        ),
      Expanded(
        child: r.entries.isEmpty
            ? const Center(
                child: Text(
                  'Start with a song or station.',
                  style: TextStyle(color: Colors.white38),
                ),
              )
            : ListView.builder(
                itemCount: r.entries.length,
                itemBuilder: (context, i) {
                  final entry = r.entries[i];
                  final active = i == r.currentIndex,
                      skipped = entry.status == 'skipped';
                  return Dismissible(
                    key: ValueKey(entry.occurrenceId),
                    direction: r.changingQueue
                        ? DismissDirection.none
                        : DismissDirection.endToStart,
                    background: Container(
                      alignment: AlignmentDirectional.centerEnd,
                      padding: const EdgeInsets.only(right: 24),
                      color: Colors.red.withValues(alpha: .15),
                      child: const Icon(Icons.delete_outline),
                    ),
                    confirmDismiss: (_) async {
                      // The controller saves the deletion before rebuilding.
                      // Returning false avoids dismissing a stale row if busy.
                      await r.removeOccurrence(entry.occurrenceId);
                      return false;
                    },
                    child: SongActions(
                      radio: r,
                      song: entry.song,
                      queueOccurrenceId: entry.occurrenceId,
                      onBrowse: browse,
                      builder: (_) => Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: active ? lime.withValues(alpha: .09) : null,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          leading: active
                              ? const Icon(Icons.graphic_eq, color: lime)
                              : skipped
                              ? const Icon(
                                  Icons.not_interested,
                                  color: Colors.orangeAccent,
                                )
                              : artwork(entry.song, 36),
                          title: Text(
                            entry.song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: active ? lime : null),
                          ),
                          subtitle: Text(
                            skipped
                                ? '${entry.song.artist} · Skipped\n${entry.reason}'
                                : '${entry.song.artist}${entry.addedByUser ? ' · Added by you' : ''}${entry.tidal != null ? ' · Matched' : ''}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              skipped
                                  ? IconButton(
                                      tooltip: 'Save a recording correction',
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 18,
                                      ),
                                      onPressed: () => correct(entry),
                                    )
                                  : IconButton(
                                      tooltip: 'Play this occurrence',
                                      icon: const Icon(Icons.play_arrow),
                                      onPressed: () => r.selectEntry(i),
                                    ),
                              IconButton(
                                tooltip: 'Remove from queue',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: r.changingQueue
                                    ? null
                                    : () => r.removeOccurrence(
                                        entry.occurrenceId,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );
  Widget listening() {
    final report = r.report, totals = r.report?['totals'] as Map?;
    final seconds = (totals?['listened_seconds'] as num? ?? 0).toDouble();
    final submissions = report?['submissions'] as List? ?? [];
    return RefreshIndicator(
      onRefresh: r.refreshReport,
      child: ListView(
        children: [
          heading(
            'Your listening',
            'Every minute counts',
            'Local statistics stay available regardless of YouTube reporting.',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (seconds / 60).toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w300,
                          color: lime,
                        ),
                      ),
                      const Text(
                        'minutes listened',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      Text(
                        '${totals?['occurrences'] ?? 0}',
                        style: const TextStyle(fontSize: 30),
                      ),
                      const Text(
                        'plays started',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          const ListTile(
            leading: Icon(Icons.info_outline, color: lime),
            title: Text('YouTube Recap remains unverified'),
            subtitle: Text(
              'History submission and Recap eligibility are separate results.',
            ),
          ),
          ListTile(
            title: Text('${r.outbox.length} events waiting on this device'),
            trailing: TextButton(
              onPressed: r.sync,
              child: const Text('Sync now'),
            ),
          ),
          const Divider(color: Colors.white10),
          const ListTile(title: Text('Top artists')),
          for (final row in report?['top_artists'] as List? ?? [])
            ListTile(
              title: Text(row['artist']),
              trailing: Text(
                '${((row['listened_seconds'] as num) / 60).toStringAsFixed(1)} min',
              ),
            ),
          const ListTile(title: Text('Top songs')),
          for (final row in report?['top_songs'] as List? ?? [])
            ListTile(
              title: Text(row['title']),
              subtitle: Text(row['artist']),
              trailing: Text(
                '${((row['listened_seconds'] as num) / 60).toStringAsFixed(1)} min',
              ),
            ),
          const Divider(color: Colors.white10),
          const ListTile(title: Text('Activity reporting')),
          if (submissions.isEmpty)
            const ListTile(
              subtitle: Text(
                'Plays become eligible after 30 seconds of actual listening, or completion of a shorter track.',
              ),
            ),
          for (final row in submissions.reversed.take(30))
            ListTile(
              leading: Icon(
                row['state'] == 'visible'
                    ? Icons.check_circle_outline
                    : row['state'] == 'uncertain'
                    ? Icons.help_outline
                    : Icons.schedule,
                color: row['state'] == 'uncertain' ? Colors.orangeAccent : lime,
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
          TextButton.icon(
            onPressed: r.refreshReport,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh listening data'),
          ),
        ],
      ),
    );
  }

  Widget artwork(Song? song, double size) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .16),
    child: Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF64754B), Color(0xFF242E24)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: song?.artwork == null
          ? Icon(Icons.graphic_eq_rounded, color: lime, size: size * .42)
          : Image.network(
              song!.artwork!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  Icon(Icons.graphic_eq_rounded, color: lime, size: size * .42),
            ),
    ),
  );
  Widget quality() {
    final q = r.quality, verified = r.quality?['verified'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: lime.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            verified
                ? 'FLAC  ·  ${q!['bit_depth']}-bit / ${((q['sample_rate'] as num) / 1000).toStringAsFixed(1)} kHz'
                : 'LOSSLESS FLAC',
            style: const TextStyle(
              color: lime,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          verified
              ? 'Verified source stream'
              : 'Source resolution not yet verified',
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }

  void browse(String kind, String id) {
    changeTab(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) catalogKey.currentState?.browse(kind, id);
    });
  }

  Widget nowPlaying({VoidCallback? dismiss}) => SongActions(
    radio: r,
    song: r.current?.song,
    buttonTooltip: 'Now playing options',
    onBrowse: (kind, id) {
      dismiss?.call();
      browse(kind, id);
    },
    builder: (menuButton) => Card(
      margin: EdgeInsets.zero,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'NOW PLAYING',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                menuButton,
              ],
            ),
            const SizedBox(height: 26),
            LayoutBuilder(
              builder: (_, c) => artwork(r.current?.song, c.maxWidth),
            ),
            const SizedBox(height: 26),
            Text(
              r.current?.song.title ?? 'A little room for discovery.',
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              r.current?.song.artist ?? 'Choose a song to begin.',
              style: const TextStyle(color: Colors.white54, height: 1.5),
            ),
            const SizedBox(height: 22),
            quality(),
            if (r.current != null) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  IconButton(
                    tooltip: r.currentRating?.value == 'LIKE'
                        ? 'Remove like from both services'
                        : 'Like on YouTube Music and Tidal',
                    isSelected: r.currentRating?.value == 'LIKE',
                    color: r.currentRating?.value == 'LIKE'
                        ? lime
                        : Colors.white70,
                    onPressed: r.ready && r.current!.tidal != null
                        ? () => r.rate('LIKE')
                        : null,
                    icon: const Icon(Icons.thumb_up_outlined),
                    selectedIcon: const Icon(Icons.thumb_up),
                  ),
                  IconButton(
                    tooltip: r.currentRating?.value == 'DISLIKE'
                        ? 'Remove dislike'
                        : 'Dislike on YouTube Music',
                    isSelected: r.currentRating?.value == 'DISLIKE',
                    color: r.currentRating?.value == 'DISLIKE'
                        ? lime
                        : Colors.white70,
                    onPressed: r.ready && r.current!.tidal != null
                        ? () => r.rate('DISLIKE')
                        : null,
                    icon: const Icon(Icons.thumb_down_outlined),
                    selectedIcon: const Icon(Icons.thumb_down),
                  ),
                  const Spacer(),
                  Text(
                    timeLabel(r.duration),
                    style: const TextStyle(color: Colors.white38),
                  ),
                ],
              ),
              if (r.currentRating != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 0, 8),
                  child: Tooltip(
                    message: r.currentRating!.details,
                    child: Text(
                      r.currentRating!.label,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: r.currentRating!.uncertain
                            ? Colors.orangeAccent
                            : Colors.white54,
                      ),
                    ),
                  ),
                ),
              seekBar(),
            ],
            const SizedBox(height: 14),
            const Divider(color: Colors.white10),
            const SizedBox(height: 14),
            Text(
              r.queueTitle,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget seekBar() => Column(
    children: [
      Slider(
        value: (draggingPosition ?? r.position.inMilliseconds.toDouble()).clamp(
          0,
          r.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
        ),
        max: r.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
        onChanged: (v) => setState(() => draggingPosition = v),
        onChangeEnd: (v) async {
          await r.seek(Duration(milliseconds: v.round()));
          if (mounted) setState(() => draggingPosition = null);
        },
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            timeLabel(r.position),
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          Text(
            timeLabel(r.duration),
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    ],
  );
  Widget transport(bool wide) => SongActions(
    radio: r,
    song: r.current!.song,
    onBrowse: browse,
    builder: (_) => Container(
      decoration: const BoxDecoration(
        color: panel,
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: [
          artwork(r.current!.song, 44),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (sheetContext) => AnimatedBuilder(
                  animation: r,
                  builder: (_, _) => SizedBox(
                    height: MediaQuery.sizeOf(context).height * .8,
                    child: nowPlaying(
                      dismiss: () => Navigator.pop(sheetContext),
                    ),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.current!.song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    r.current!.song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: lime,
              foregroundColor: ink,
            ),
            tooltip: r.playing ? 'Pause' : 'Play',
            onPressed: r.playing ? r.pause : r.play,
            icon: r.buffering
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ink,
                    ),
                  )
                : Icon(
                    r.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
          ),
          IconButton(
            tooltip: 'Skip without disliking',
            onPressed: r.advance,
            icon: const Icon(Icons.skip_next_rounded),
          ),
          if (wide) ...[
            const SizedBox(width: 24),
            const Icon(Icons.volume_up_outlined, size: 18),
            SizedBox(
              width: 100,
              child: Slider(value: r.volume, max: 100, onChanged: r.setVolume),
            ),
          ],
        ],
      ),
    ),
  );

  Future<void> correct(QueueEntry entry) async {
    final text = TextEditingController();
    final value = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Choose the correct recording'),
        scrollable: true,
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.candidates.isNotEmpty) ...[
                const Text(
                  'Review these Tidal results. Choosing one saves your correction.',
                ),
                const SizedBox(height: 12),
                for (final candidate in entry.candidates)
                  Builder(
                    builder: (context) {
                      final track = Map<String, dynamic>.from(
                        candidate['track'],
                      );
                      final length = Duration(
                        seconds: (track['duration'] as num? ?? 0).round(),
                      );
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(track['title'] ?? 'Unknown recording'),
                        subtitle: Text(
                          [
                            (track['artists'] as List? ?? []).join(', '),
                            '${track['album'] ?? 'Unknown album'} · ${timeLabel(length)}'
                                '${track['explicit'] == true
                                    ? ' · Explicit'
                                    : track['explicit'] == false
                                    ? ' · Not explicit'
                                    : ''}',
                            if (candidate['rejection'] != null)
                              candidate['rejection'].toString(),
                          ].join('\n'),
                        ),
                        trailing: IconButton(
                          tooltip: 'Use this recording',
                          icon: const Icon(Icons.check_circle_outline),
                          onPressed: () => Navigator.pop(c, track['id'] as int),
                        ),
                      );
                    },
                  ),
                const Divider(),
              ],
              TextField(
                controller: text,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Or enter a Tidal track ID',
                  helperText: 'Save this mapping for future occurrences.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final id = int.tryParse(text.text);
              if (id != null && id > 0) Navigator.pop(c, id);
            },
            child: const Text('Save correction'),
          ),
        ],
      ),
    );
    text.dispose();
    if (value != null) {
      try {
        await r.correct(entry, value);
      } catch (e) {
        r.fail(e);
      }
    }
  }

  Future<void> settings() async {
    final address = TextEditingController(text: r.origin),
        access = TextEditingController(text: r.token);
    String? failure;
    bool saving = false;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (c, setDialog) => AlertDialog(
          title: const Text('Connect your server'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: address,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Server address',
                    hintText: 'https://radio.your-tailnet.ts.net',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: access,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Device access token',
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'The token is in data/device-token.txt on your server. Connect this device to Tailscale before using a remote server.',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                if (failure != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      failure!,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => showLicensePage(
                context: dialog,
                applicationName: 'Personal Radio',
                applicationVersion: '0.1.1',
              ),
              child: const Text('Licenses'),
            ),
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setDialog(() {
                        saving = true;
                        failure = null;
                      });
                      try {
                        await r.connect(address.text, access.text);
                        if (dialog.mounted) Navigator.pop(dialog);
                      } catch (e) {
                        if (c.mounted) {
                          setDialog(() {
                            saving = false;
                            failure = e.toString();
                          });
                        }
                      }
                    },
              child: Text(saving ? 'Connecting…' : 'Connect'),
            ),
          ],
        ),
      ),
    );
    address.dispose();
    access.dispose();
  }
}
