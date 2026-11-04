import 'package:flutter/material.dart';

import 'models.dart';
import 'radio_controller.dart';

class _BrowsePage {
  final String kind;
  final Map<String, dynamic> data;
  String section = 'songs';
  final Map<String, Map<String, dynamic>> releases = {};
  _BrowsePage(this.kind, this.data);
}

class CatalogView extends StatefulWidget {
  final RadioController radio;
  final TextEditingController search;
  final FocusNode focus;
  const CatalogView({
    super.key,
    required this.radio,
    required this.search,
    required this.focus,
  });
  @override
  State<CatalogView> createState() => CatalogViewState();
}

class CatalogViewState extends State<CatalogView> {
  RadioController get r => widget.radio;
  final List<_BrowsePage> _pages = [];
  String _kind = 'songs';
  bool _loading = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _kind = r.searchKind;
  }

  void _back() => setState(() {
    _request++;
    _loading = false;
    _pages.removeLast();
  });

  Future<void> _open(String kind, String id) async {
    final request = ++_request;
    setState(() => _loading = true);
    try {
      final data = Map<String, dynamic>.from(
        await r.api!.call(
          '/api/catalog/${kind == 'artist' ? 'artists' : 'albums'}/${Uri.encodeComponent(id)}',
        ),
      );
      if (!mounted || request != _request) return;
      setState(() => _pages.add(_BrowsePage(kind, data)));
    } catch (e) {
      if (mounted && request == _request) r.fail(e);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _releases(
    _BrowsePage page,
    String kind, {
    bool more = false,
  }) async {
    if (_loading) return;
    setState(() => page.section = kind);
    if (!more && page.releases.containsKey(kind)) return;
    final limit = more
        ? (page.releases[kind]?['limit'] as int? ?? 0) + 100
        : 100;
    final request = ++_request;
    setState(() => _loading = true);
    try {
      final data = Map<String, dynamic>.from(
        await r.api!.call(
          '/api/catalog/artists/${Uri.encodeComponent(page.data['id'])}/releases?kind=$kind&limit=$limit',
        ),
      );
      if (!mounted || request != _request) return;
      setState(() => page.releases[kind] = data);
    } catch (e) {
      if (mounted && request == _request) r.fail(e);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _search(String query) {
    setState(() {
      _request++;
      _pages.clear();
      _loading = false;
    });
    r.search(query, kind: _kind);
  }

  Future<void> _enqueue(List<Song> songs, {bool next = false}) async {
    final count = await r.enqueue(songs, next: next);
    if (!mounted || count == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          next
              ? '$count ${count == 1 ? 'song' : 'songs'} will play next'
              : 'Added $count ${count == 1 ? 'song' : 'songs'} to queue',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _art(String? url, {double size = 46}) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: SizedBox(
      width: size,
      height: size,
      child: url == null
          ? const ColoredBox(
              color: Color(0xFF293023),
              child: Icon(Icons.music_note),
            )
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Icon(Icons.music_note),
            ),
    ),
  );

  Widget _card(Map<String, dynamic> item, String kind) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 6),
    leading: _art(item['artwork']),
    title: Text(
      item['title'] ?? '',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      [
        for (final artist in item['artists'] as List? ?? [])
          if (artist['name'] != null) artist['name'],
        if (item['year'] != null) item['year'].toString(),
        if (item['explicit'] == true) 'Explicit',
      ].join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: item['id'] == null ? null : () => _open(kind, item['id']),
  );

  Widget _song(
    Song song, {
    List<Song>? album,
    int index = 0,
    String? title,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 4),
    leading: album == null
        ? _art(song.artwork)
        : SizedBox(width: 24, child: Text('${index + 1}')),
    title: Text(song.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      [
        song.artist,
        if (!song.available) 'Unavailable',
        if (song.source['explicit'] == true) 'Explicit',
        if (song.duration > Duration.zero) timeLabel(song.duration),
      ].where((part) => part.isNotEmpty).join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Play song',
          icon: const Icon(Icons.play_arrow_rounded),
          onPressed: r.busy || !song.available
              ? null
              : () => r.playSongs(
                  album ?? [song],
                  startIndex: album == null ? 0 : index,
                  title: title,
                ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Song actions',
          onSelected: (value) {
            if (value == 'autoplay') r.start(song: song);
            if (value == 'radio') r.start(song: song, selectedMode: 'radio');
            if (value == 'next') _enqueue([song], next: true);
            if (value == 'queue') _enqueue([song]);
            if (value == 'album') _open('album', song.albumId!);
            if (value.startsWith('artist:')) {
              _open('artist', value.substring(7));
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'next',
              enabled: !r.changingQueue && song.available,
              child: const Text('Play next'),
            ),
            PopupMenuItem(
              value: 'queue',
              enabled: !r.changingQueue && song.available,
              child: const Text('Add to queue'),
            ),
            PopupMenuItem(
              value: 'autoplay',
              enabled: !r.busy && song.available,
              child: const Text('Autoplay'),
            ),
            PopupMenuItem(
              value: 'radio',
              enabled: !r.busy && song.available,
              child: const Text('Start radio / mix'),
            ),
            if (song.albumId != null)
              const PopupMenuItem(value: 'album', child: Text('View album')),
            for (final artist in song.artistRefs)
              if (artist['id'] != null)
                PopupMenuItem(
                  value: 'artist:${artist['id']}',
                  child: Text('View artist: ${artist['name']}'),
                ),
          ],
        ),
      ],
    ),
  );

  Widget _searchView() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Find your next listen',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 10),
      const Text(
        'Play a song, explore an album, or let your radio take over.',
        style: TextStyle(color: Colors.white54),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: widget.search,
        focusNode: widget.focus,
        textInputAction: TextInputAction.search,
        onSubmitted: _search,
        decoration: InputDecoration(
          hintText: 'Search songs, artists or albums',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(
            tooltip: 'Search',
            onPressed: () => _search(widget.search.text),
            icon: const Icon(Icons.arrow_forward),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        children: [
          for (final kind in ['songs', 'artists', 'albums'])
            ChoiceChip(
              label: Text(kind[0].toUpperCase() + kind.substring(1)),
              selected: _kind == kind,
              onSelected: (_) {
                setState(() => _kind = kind);
                _search(widget.search.text);
              },
            ),
        ],
      ),
      const SizedBox(height: 8),
      if (_loading || r.searching) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: _kind != r.searchKind
            ? const Center(child: Text('Search your music catalog.'))
            : _kind == 'songs'
            ? r.results.isEmpty
                  ? Center(
                      child: Text(
                        r.searching
                            ? 'Searching…'
                            : 'Search for a song to play or start radio.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: r.results.length,
                      itemBuilder: (_, i) => _song(r.results[i]),
                    )
            : r.catalogResults.isEmpty
            ? Center(
                child: Text(
                  r.searching
                      ? 'Searching…'
                      : 'No results. Try another search.',
                ),
              )
            : ListView.builder(
                itemCount: r.catalogResults.length,
                itemBuilder: (_, i) => _card(
                  r.catalogResults[i],
                  _kind == 'artists' ? 'artist' : 'album',
                ),
              ),
      ),
    ],
  );

  Widget _browseView(_BrowsePage page) {
    final data = page.data;
    final songs =
        (data[page.kind == 'album' ? 'tracks' : 'songs'] as List? ?? [])
            .map((item) => Song(Map<String, dynamic>.from(item)))
            .toList();
    final releaseData = page.releases[page.section];
    final releases =
        releaseData?['items'] ?? data['releases']?[page.section] ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Back to browsing',
              onPressed: _back,
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(
              child: Text(
                page.kind == 'artist' ? 'Artist' : 'Album',
                style: const TextStyle(color: Colors.white54),
              ),
            ),
            IconButton(
              tooltip: 'Refresh page',
              onPressed: _loading
                  ? null
                  : () {
                      final id = data['id'];
                      _back();
                      _open(page.kind, id);
                    },
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _art(data['artwork'], size: 72),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data['title'] ?? '',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (data['year'] != null)
                    Text(
                      data['year'].toString(),
                      style: const TextStyle(color: Colors.white54),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (page.kind == 'album')
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.icon(
                onPressed: r.busy || !songs.any((s) => s.available)
                    ? null
                    : () => r.playSongs(songs, title: data['title']),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play album'),
              ),
              OutlinedButton.icon(
                onPressed: r.changingQueue || !songs.any((s) => s.available)
                    ? null
                    : () => _enqueue(songs, next: true),
                icon: const Icon(Icons.playlist_play),
                label: const Text('Play album next'),
              ),
              OutlinedButton.icon(
                onPressed: r.changingQueue || !songs.any((s) => s.available)
                    ? null
                    : () => _enqueue(songs),
                icon: const Icon(Icons.playlist_add),
                label: const Text('Add album to queue'),
              ),
              for (final artist in data['artists'] as List? ?? [])
                if (artist['id'] != null)
                  TextButton(
                    onPressed: () => _open('artist', artist['id']),
                    child: Text(artist['name'] ?? 'Artist'),
                  ),
            ],
          ),
        if (page.kind == 'artist')
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Top songs'),
                selected: page.section == 'songs',
                onSelected: (_) => setState(() => page.section = 'songs'),
              ),
              for (final kind in ['albums', 'singles'])
                ChoiceChip(
                  label: Text(kind == 'albums' ? 'Albums' : 'Singles & EPs'),
                  selected: page.section == kind,
                  onSelected: _loading ? null : (_) => _releases(page, kind),
                ),
            ],
          ),
        const SizedBox(height: 8),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView(
            children: [
              if (page.kind == 'album' || page.section == 'songs') ...[
                if (songs.isEmpty)
                  const ListTile(title: Text('No songs available.')),
                for (var i = 0; i < songs.length; i++)
                  _song(
                    songs[i],
                    album: page.kind == 'album' ? songs : null,
                    index: i,
                    title: page.kind == 'album' ? data['title'] : null,
                  ),
              ] else ...[
                if (releases.isEmpty && !_loading)
                  const ListTile(title: Text('No releases found.')),
                for (final item in releases)
                  _card(Map<String, dynamic>.from(item), 'album'),
                if (releaseData == null || releaseData['has_more'] == true)
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => _releases(
                            page,
                            page.section,
                            more: releaseData != null,
                          ),
                    child: Text(
                      releaseData == null
                          ? 'Load releases'
                          : 'Load more releases',
                    ),
                  ),
                if (releaseData?['limited'] == true)
                  const ListTile(
                    subtitle: Text('Showing the first 1000 releases.'),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _pages.isEmpty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _pages.isNotEmpty) _back();
    },
    child: _pages.isEmpty ? _searchView() : _browseView(_pages.last),
  );
}
