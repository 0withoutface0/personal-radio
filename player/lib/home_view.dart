import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'radio_controller.dart';
import 'song_actions.dart';

/// YouTube's shelves retain their order; all plays use the shared radio engine.
class HomeView extends StatelessWidget {
  final RadioController radio;
  final void Function(String kind, String id) onBrowse;
  const HomeView({super.key, required this.radio, required this.onBrowse});

  List<Map<String, dynamic>> _items(String section) =>
      (radio.home?[section]?['items'] as List? ?? [])
          .map((x) => Map<String, dynamic>.from(x))
          .toList();

  Widget _art(String? url) => url == null
      ? const ColoredBox(
          color: Color(0xFF293023),
          child: Center(child: Icon(Icons.music_note, color: Colors.white54)),
        )
      : Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const ColoredBox(
            color: Color(0xFF293023),
            child: Center(child: Icon(Icons.music_note)),
          ),
        );

  void _open(Map<String, dynamic> item) {
    if (item['kind'] == 'artist' || item['kind'] == 'album') {
      onBrowse(item['kind'], item['id']);
    } else if (item['play_id'] != null && !radio.changingQueue) {
      radio.start(homeSelection: item);
    }
  }

  Widget _tile(Map<String, dynamic> item) {
    final song = item['song'] is Map
        ? Song(Map<String, dynamic>.from(item['song']))
        : null;
    return SongActions(
      radio: radio,
      song: song,
      onBrowse: onBrowse,
      builder: (_) => Tooltip(
        message: '${song == null ? 'Open' : 'Play'} ${item['title']}',
        triggerMode: TooltipTriggerMode.manual,
        child: Material(
          color: const Color(0xFF293023),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: radio.changingQueue ? null : () => _open(item),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _art(item['artwork']),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xDD000000)],
                    ),
                  ),
                ),
                Positioned(
                  left: 9,
                  right: 9,
                  bottom: 9,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          item['title'] ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (song == null)
                        const Icon(Icons.chevron_right, size: 16),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pick(Map<String, dynamic> item) {
    final song = Song(Map<String, dynamic>.from(item['song']));
    return SongActions(
      radio: radio,
      song: song,
      onBrowse: onBrowse,
      builder: (menu) => ListTile(
        contentPadding: const EdgeInsets.only(right: 2),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(width: 48, height: 48, child: _art(song.artwork)),
        ),
        title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${song.source['explicit'] == true ? 'E · ' : ''}${song.artist}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: menu,
        onTap: radio.changingQueue || item['play_id'] == null
            ? null
            : () => _open(item),
      ),
    );
  }

  Widget _empty(String section) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      radio.home?[section]?['message'] ??
          'Refresh home to load your YouTube Music recommendations.',
      style: const TextStyle(color: Colors.white54),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final speed = _items('speed_dial');
    final picks = _items('quick_picks')
        .where((item) => item['kind'] == 'song' && item['song'] is Map)
        .toList();
    final all = radio.home?['quick_picks']?['play_all_id'];
    return RefreshIndicator(
      onRefresh: () => radio.loadHome(refresh: true),
      child: ListView(
        key: const PageStorageKey('youtube-home'),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'From your YouTube Music',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: 'Refresh home',
                onPressed: radio.homeLoading
                    ? null
                    : () => radio.loadHome(refresh: true),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (radio.homeLoading) const LinearProgressIndicator(minHeight: 2),
          if (radio.homeError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '${radio.homeError}${radio.home == null ? '' : '\nShowing your previous recommendations.'}',
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          const SizedBox(height: 8),
          const Text(
            'Speed dial',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          if (speed.isEmpty)
            _empty('speed_dial')
          else
            _SpeedDialGrid(
              key: ValueKey(
                speed.map((x) => x['play_id'] ?? x['id']).join('|'),
              ),
              items: speed,
              tile: _tile,
            ),
          const SizedBox(height: 24),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Quick picks',
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
                ),
              ),
              if (all != null)
                OutlinedButton(
                  onPressed: radio.changingQueue
                      ? null
                      : () => radio.start(
                          homeSelection: {
                            'play_id': all,
                            'title': 'Quick picks',
                          },
                        ),
                  child: const Text('Play all'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (picks.isEmpty)
            _empty('quick_picks')
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final width = math.min(380.0, constraints.maxWidth - 16);
                return SizedBox(
                  height: math.min(4, picks.length) * 76.0,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: (picks.length / 4).ceil(),
                    itemBuilder: (_, column) => SizedBox(
                      width: width,
                      child: Column(
                        children: [
                          for (final item in picks.skip(column * 4).take(4))
                            SizedBox(height: 76, child: _pick(item)),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SpeedDialGrid extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final Widget Function(Map<String, dynamic>) tile;
  const _SpeedDialGrid({super.key, required this.items, required this.tile});
  @override
  State<_SpeedDialGrid> createState() => _SpeedDialGridState();
}

class _SpeedDialGridState extends State<_SpeedDialGrid> {
  int page = 0;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final pages = (widget.items.length / 9).ceil();
      final cell = (math.min(constraints.maxWidth, 600.0) - 16) / 3;
      final rows = (math.min(9, widget.items.length) / 3).ceil();
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: math.min(constraints.maxWidth, 600),
          child: Column(
            children: [
              SizedBox(
                height: cell * rows + (rows - 1) * 8,
                child: PageView.builder(
                  itemCount: pages,
                  onPageChanged: (value) => setState(() => page = value),
                  itemBuilder: (_, index) {
                    final items = widget.items.skip(index * 9).take(9).toList();
                    return GridView.builder(
                      padding: EdgeInsets.zero,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      itemCount: items.length,
                      itemBuilder: (_, i) => widget.tile(items[i]),
                    );
                  },
                ),
              ),
              if (pages > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    '${page + 1} / $pages',
                    semanticsLabel: 'Speed dial page ${page + 1} of $pages',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
