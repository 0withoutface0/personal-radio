import 'package:flutter/material.dart';

import 'models.dart';
import 'radio_controller.dart';

/// One set of song options for the overflow button, mouse and touch gestures.
class SongActions extends StatelessWidget {
  final RadioController radio;
  final Song? song;
  final void Function(String kind, String id) onBrowse;
  final Widget Function(Widget menuButton) builder;
  final String buttonTooltip;

  const SongActions({
    super.key,
    required this.radio,
    required this.song,
    required this.onBrowse,
    required this.builder,
    this.buttonTooltip = 'Song actions',
  });

  List<PopupMenuEntry<String>> _items() => [
    PopupMenuItem(
      value: 'next',
      enabled: radio.ready && !radio.changingQueue && song!.available,
      child: const Text('Play next'),
    ),
    PopupMenuItem(
      value: 'queue',
      enabled: radio.ready && !radio.changingQueue && song!.available,
      child: const Text('Add to queue'),
    ),
    PopupMenuItem(
      value: 'autoplay',
      enabled: radio.ready && !radio.changingQueue && song!.available,
      child: const Text('Autoplay'),
    ),
    PopupMenuItem(
      value: 'radio',
      enabled: radio.ready && !radio.changingQueue && song!.available,
      child: const Text('Start radio / mix'),
    ),
    if (song!.albumId != null)
      const PopupMenuItem(value: 'album', child: Text('View album')),
    for (final artist in song!.artistRefs)
      if (artist['id'] != null)
        PopupMenuItem(
          value: 'artist:${artist['id']}',
          child: Text('View artist: ${artist['name']}'),
        ),
  ];

  Future<void> _select(BuildContext context, String value) async {
    final selected = song!;
    if (value == 'album') {
      onBrowse('album', selected.albumId!);
    } else if (value.startsWith('artist:')) {
      onBrowse('artist', value.substring(7));
    } else if (value == 'autoplay' || value == 'radio') {
      await radio.start(song: selected, selectedMode: value);
    } else if (value == 'next' || value == 'queue') {
      final next = value == 'next';
      final count = await radio.enqueue([selected], next: next);
      if (!context.mounted || count == 0) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            next ? '1 song will play next' : 'Added 1 song to queue',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _show(BuildContext context, Offset position) async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(point.dx, point.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: _items(),
    );
    if (context.mounted && selection != null) await _select(context, selection);
  }

  @override
  Widget build(BuildContext context) {
    if (song == null) return builder(const SizedBox.shrink());
    final touch =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (event) => _show(context, event.globalPosition),
      onLongPressStart: touch
          ? (event) => _show(context, event.globalPosition)
          : null,
      child: builder(
        PopupMenuButton<String>(
          tooltip: buttonTooltip,
          itemBuilder: (_) => _items(),
          onSelected: (value) => _select(context, value),
        ),
      ),
    );
  }
}
