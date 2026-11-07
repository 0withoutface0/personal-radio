import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dynamic_color/dynamic_color.dart';

import 'appearance.dart';
import 'appearance_dialog.dart';
import 'catalog_view.dart';
import 'desktop_pairing.dart';
import 'listening_view.dart';
import 'models.dart';
import 'player_host.dart';
import 'local_settings.dart';
import 'radio_controller.dart';
import 'song_actions.dart';

class RadioApp extends StatefulWidget {
  final RadioController radio;
  final PlayerHost? host;
  const RadioApp({super.key, required this.radio, this.host});
  @override
  State<RadioApp> createState() => _RadioAppState();
}

class _RadioAppState extends State<RadioApp> with WidgetsBindingObserver {
  final dynamicKey = GlobalKey<DynamicColorBuilderState>();
  late RadioAppearance appearance;
  @override
  void initState() {
    super.initState();
    appearance = widget.radio.appearance;
    widget.radio.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
  }

  void changed() {
    if (widget.radio.appearance != appearance) {
      setState(() => appearance = widget.radio.appearance);
    }
  }

  @override
  void didUpdateWidget(covariant RadioApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.radio != widget.radio) {
      oldWidget.radio.removeListener(changed);
      widget.radio.addListener(changed);
      appearance = widget.radio.appearance;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      dynamicKey.currentState?.initPlatformState();
    }
  }

  @override
  void dispose() {
    widget.radio.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DynamicColorBuilder(
    key: dynamicKey,
    builder: (light, dark) => MaterialApp(
      title: 'Personal Radio',
      debugShowCheckedModeBanner: false,
      themeMode: appearance.mode,
      theme: radioTheme(appearance.palette, Brightness.light, light),
      darkTheme: radioTheme(appearance.palette, Brightness.dark, dark),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value:
            (Theme.of(context).brightness == Brightness.dark
                    ? SystemUiOverlayStyle.light
                    : SystemUiOverlayStyle.dark)
                .copyWith(
                  statusBarColor: Colors.transparent,
                  systemNavigationBarColor: Theme.of(context)
                      .colorScheme
                      .surface,
                ),
        child: child!,
      ),
      home: RadioHome(radio: widget.radio, host: widget.host),
    ),
  );
}

class RadioHome extends StatefulWidget {
  final RadioController radio;
  final PlayerHost? host;
  const RadioHome({super.key, required this.radio, this.host});
  @override
  State<RadioHome> createState() => _RadioHomeState();
}

class _RadioHomeState extends State<RadioHome> {
  RadioController get r => widget.radio;
  ColorScheme get colors => Theme.of(context).colorScheme;
  Color get lime => colors.primary;
  Color get ink => colors.onPrimary;
  Color get panel => colors.surfaceContainer;
  Color get muted => colors.onSurfaceVariant;
  Color get soft => colors.onSurfaceVariant;
  Color get outline => colors.outlineVariant;
  int tab = 0;
  final catalogKey = GlobalKey<CatalogViewState>();
  double? draggingPosition;
  final search = TextEditingController(), focus = FocusNode();
  final labels = ['Discover', 'Stations', 'Queue', 'Listening'];
  final icons = [
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
                            child: Icon(Icons.graphic_eq, color: ink),
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
                              style: TextStyle(fontSize: 12, color: muted),
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
                        color: colors.errorContainer,
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
  Widget? get setupFromWindows {
    final host = widget.host;
    if (!Platform.isAndroid || host == null) return null;
    return FilledButton.icon(
      onPressed: () => showDeviceSetup(context, host),
      icon: const Icon(Icons.qr_code_scanner),
      label: const Text('Set up from Windows'),
    );
  }

  Widget connectScreen() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 530),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.radio_rounded, size: 66, color: lime),
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
            Text(
              'Your YouTube Music recommendations, played from Tidal in lossless quality.',
              style: TextStyle(color: muted, fontSize: 16, height: 1.6),
            ),
            const SizedBox(height: 28),
            if (setupFromWindows case final setup?) ...[
              setup,
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: settings,
              icon: const Icon(Icons.link),
              label: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Connect your server'),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Use your private server address and device access token. Provider accounts stay on the server.',
              style: TextStyle(color: soft, height: 1.5),
            ),
          ],
        ),
      ),
    ),
  );
  Widget sidebar() => Container(
    width: 190,
    padding: const EdgeInsets.fromLTRB(16, 22, 12, 20),
    decoration: BoxDecoration(
      border: Border(right: BorderSide(color: outline)),
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
        Text(
          'YOUTUBE MUSIC\n× TIDAL',
          style: TextStyle(
            fontSize: 12,
            color: soft,
            letterSpacing: 2,
            height: 1.8,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          r.outbox.isEmpty
              ? 'Listening events synced'
              : '${r.outbox.length} events saved locally',
          style: TextStyle(color: soft, fontSize: 11),
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
          style: TextStyle(
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
            child: Text(subtitle, style: TextStyle(color: muted, height: 1.5)),
          ),
      ],
    ),
  );
  Widget content() => switch (tab) {
    0 => discover(),
    1 => stationList(),
    2 => queueList(),
    _ => ListeningView(radio: r),
  };
  Widget discover() {
    if (r.localMode &&
        (!r.accountLinked('youtube') || !r.accountLinked('tidal'))) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            ?setupFromWindows,
            FilledButton.icon(
              onPressed: settings,
              icon: const Icon(Icons.account_circle_outlined),
              label: const Text('Set up your music accounts'),
            ),
          ],
        ),
      );
    }
    return CatalogView(key: catalogKey, radio: r, search: search, focus: focus);
  }

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
            ? Center(
                child: Text(
                  'No stations found yet. Refresh to check your account.',
                  style: TextStyle(color: muted),
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
                      leading: Icon(Icons.radio, color: lime),
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
      if (r.entries.isNotEmpty && r.currentIndex < 0)
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
            ? Center(
                child: Text(
                  'Start with a song or station.',
                  style: TextStyle(color: soft),
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
                              ? Icon(Icons.graphic_eq, color: lime)
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
                            style: TextStyle(color: muted, fontSize: 12),
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
  Widget artwork(Song? song, double size) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .16),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colors.primaryContainer, colors.surfaceContainerHigh],
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
            style: TextStyle(
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
          style: TextStyle(color: soft, fontSize: 10),
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
                Expanded(
                  child: Text(
                    'NOW PLAYING',
                    style: TextStyle(
                      color: soft,
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
              style: TextStyle(color: muted, height: 1.5),
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
                        : colors.onSurface,
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
                        : colors.onSurface,
                    onPressed: r.ready && r.current!.tidal != null
                        ? () => r.rate('DISLIKE')
                        : null,
                    icon: const Icon(Icons.thumb_down_outlined),
                    selectedIcon: const Icon(Icons.thumb_down),
                  ),
                  const Spacer(),
                  Text(timeLabel(r.duration), style: TextStyle(color: soft)),
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
                            : muted,
                      ),
                    ),
                  ),
                ),
              seekBar(),
            ],
            const SizedBox(height: 14),
            Divider(color: outline),
            const SizedBox(height: 14),
            Text(
              r.queueTitle,
              style: TextStyle(color: soft, fontSize: 12, height: 1.6),
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
            style: TextStyle(fontSize: 11, color: muted),
          ),
          Text(
            timeLabel(r.duration),
            style: TextStyle(fontSize: 11, color: muted),
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
      decoration: BoxDecoration(
        color: panel,
        border: Border(top: BorderSide(color: outline)),
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
                    style: TextStyle(color: muted, fontSize: 11),
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
                ? SizedBox(
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
    final host = widget.host;
    if (host != null && r.localMode) {
      await showLocalSettings(context, host);
      return;
    }
    final address = TextEditingController(text: r.origin),
        access = TextEditingController(text: r.token);
    String? failure;
    bool saving = false;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (c, setDialog) => AlertDialog(
          title: const Text('Settings'),
          scrollable: true,
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (host != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.qr_code_2),
                    title: Text(
                      Platform.isWindows
                          ? 'Set up Android'
                          : 'Set up from Windows',
                    ),
                    onTap: saving ? null : () => showDeviceSetup(c, host),
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Appearance'),
                  subtitle: Text(r.appearance.palette.label),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await showAppearanceDialog(dialog, r);
                    if (c.mounted) setDialog(() {});
                  },
                ),
                if (host?.supportsLocal == true)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.devices_outlined),
                    title: const Text('Use this device'),
                    subtitle: const Text('Keep the server profile for later'),
                    onTap: host!.changing
                        ? null
                        : () {
                            Navigator.pop(dialog);
                            unawaited(host.switchMode(true));
                          },
                  ),
                const SizedBox(height: 12),
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
                Text(
                  'The token is in data/device-token.txt on your server. Connect this device to Tailscale before using a remote server.',
                  style: TextStyle(color: muted, fontSize: 12, height: 1.6),
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
                applicationVersion: '0.5.0',
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
