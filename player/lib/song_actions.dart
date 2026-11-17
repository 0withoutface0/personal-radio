import 'package:flutter/material.dart';

import 'api.dart';
import 'models.dart';
import 'radio_controller.dart';

/// One set of song options for the overflow button, mouse and touch gestures.
class SongActions extends StatelessWidget {
  final RadioController radio;
  final Song? song;
  final void Function(String kind, String id) onBrowse;
  final Widget Function(Widget menuButton) builder;
  final String buttonTooltip;
  final String? queueOccurrenceId;

  const SongActions({
    super.key,
    required this.radio,
    required this.song,
    required this.onBrowse,
    required this.builder,
    this.buttonTooltip = 'Song actions',
    this.queueOccurrenceId,
  });

  List<PopupMenuEntry<String>> _items() => [
    if (queueOccurrenceId != null)
      PopupMenuItem(
        value: 'remove',
        enabled: !radio.changingQueue,
        child: const Text('Remove from queue'),
      ),
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
    PopupMenuItem(
      value: 'playlist',
      enabled: radio.ready && song!.available,
      child: const Text('Add to playlist'),
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
    if (value == 'remove') {
      await radio.removeOccurrence(queueOccurrenceId!);
    } else if (value == 'playlist') {
      await _addToPlaylist(context, selected);
    } else if (value == 'album') {
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

  Future<void> _addToPlaylist(BuildContext context, Song song) async {
    final api = radio.api;
    if (api == null) return;
    final playlists = api.call(
      '/api/catalog/playlists',
      timeout: const Duration(minutes: 2),
    );
    final target = await showDialog<({String id, String title})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add to playlist'),
        content: SizedBox(
          width: 360,
          height: (MediaQuery.sizeOf(context).height * .45)
              .clamp(100, 320)
              .toDouble(),
          child: FutureBuilder<dynamic>(
            future: playlists,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                final error = snapshot.error;
                return Center(
                  child: Text(
                    error is ApiFailure
                        ? error.message
                        : 'Could not load your playlists. Try again.',
                  ),
                );
              }
              final owned = (snapshot.data['items'] as List)
                  .where((item) => item['owned'] == true)
                  .toList();
              if (owned.isEmpty) {
                return const Center(
                  child: Text('You have no playlists you can add to.'),
                );
              }
              return ListView.builder(
                itemCount: owned.length,
                itemBuilder: (context, index) {
                  final playlist = owned[index];
                  return ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text(playlist['title']),
                    onTap: () => Navigator.pop(context, (
                      id: playlist['id'] as String,
                      title: playlist['title'] as String,
                    )),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (target == null || !context.mounted || api != radio.api) return;
    try {
      await api.call(
        '/api/catalog/playlists/${Uri.encodeComponent(target.id)}/tracks',
        body: {'video_id': song.id},
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved to ${target.title}')));
    } catch (error) {
      if (context.mounted) radio.fail(error);
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
