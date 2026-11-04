import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'api.dart';
import 'disk.dart';
import 'models.dart';

class RadioController extends ChangeNotifier {
  final RadioDisk disk;
  final FlutterSecureStorage secrets = const FlutterSecureStorage();
  RadioApi? api;
  mk.Player? player;
  AudioSession? _session;
  final Stopwatch _time = Stopwatch()..start();
  ListeningClock _clock = ListeningClock();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _timer;
  Future<void>? _loadingMore;
  Future<void>? _syncing;
  bool _recovering = false;
  bool _draining = false,
      _advancing = false,
      _prefetching = false,
      _seeking = false;
  bool _interruptedPlaying = false, _opening = false, _disposed = false;
  int _generation = 0, _heartbeat = 0, _reconnects = 0;
  String deviceId = ids.v4(), origin = 'http://127.0.0.1:8765', token = '';
  String? nextCursor;
  String? _loadedOccurrence;
  String mode = 'autoplay', queueTitle = 'Your next discovery';
  String? error, connectionMessage;
  bool connected = false,
      retryingMatches = false,
      busy = false,
      playing = false,
      buffering = false,
      hasLease = false;
  double volume = 80;
  Duration position = Duration.zero, duration = Duration.zero;
  List<Song> results = [];
  List<Map<String, dynamic>> catalogResults = [];
  String searchKind = 'songs';
  bool searching = false;
  int _searchRequest = 0;
  List<Map<String, dynamic>> stations = [];
  List<QueueEntry> entries = [];
  List<Map<String, dynamic>> outbox = [];
  Map<String, dynamic>? quality, report;
  final Map<String, SongRating> ratings = {};
  SongRating? get currentRating => ratings[current?.song.id];
  int currentIndex = -1;
  VoidCallback? transportChanged;
  QueueEntry? get current => currentIndex >= 0 && currentIndex < entries.length
      ? entries[currentIndex]
      : null;
  bool get ready => api != null && connected;
  bool get changingQueue => busy || _advancing || _opening;
  RadioController(this.disk);

  Map<String, dynamic> snapshot() => {
    'version': 2,
    'device_id': deviceId,
    'origin': origin,
    'mode': mode,
    'title': queueTitle,
    'cursor': nextCursor,
    'index': currentIndex,
    'position_ms': position.inMilliseconds,
    'entries': entries.map((e) => e.toJson()).toList(),
    'outbox': outbox,
    'ratings': ratings.map((id, value) => MapEntry(id, value.toJson())),
  };
  Future<void> persist() => disk.save(snapshot());
  void update() {
    if (!_disposed) {
      notifyListeners();
      transportChanged?.call();
    }
  }

  void fail(Object failure) {
    error = failure is ApiFailure || failure is FormatException
        ? failure.toString()
        : 'Connection or playback failed. Your queue and listening events are saved.';
    update();
  }

  Future<void> initialize() async {
    final saved = await disk.load();
    deviceId = saved['device_id'] ?? deviceId;
    origin = saved['origin'] ?? origin;
    mode = saved['mode'] ?? mode;
    queueTitle = saved['title'] ?? queueTitle;
    nextCursor = saved['cursor'];
    currentIndex = saved['index'] ?? -1;
    position = Duration(milliseconds: saved['position_ms'] ?? 0);
    entries = (saved['entries'] as List? ?? [])
        .map((j) => QueueEntry.fromJson(Map<String, dynamic>.from(j)))
        .toList();
    outbox = (saved['outbox'] as List? ?? [])
        .map((j) => Map<String, dynamic>.from(j))
        .toList();
    restoreRatings(saved['ratings']);
    token = await secrets.read(key: 'device_token') ?? '';
    final pairingFile = Platform.environment['RADIO_PAIRING_FILE'];
    if (pairingFile != null && token.isEmpty) {
      // The development launcher can prefill a device token; it is never compiled into a binary.
      final pairing = await RadioDisk(File(pairingFile)).load();
      origin = pairing['origin'] ?? origin;
      token = pairing['token'] ?? '';
      if (token.isNotEmpty) {
        await secrets.write(key: 'device_token', value: token);
      }
    }
    player = mk.Player(
      configuration: const mk.PlayerConfiguration(title: 'Personal Radio'),
    );
    await player!.setVolume(volume);
    _subscriptions.add(
      player!.stream.playing.listen((value) {
        playing = value;
        if (!value) _clock.reset();
        update();
      }),
    );
    _subscriptions.add(
      player!.stream.buffering.listen((value) {
        buffering = value;
        if (value) _clock.reset();
        update();
      }),
    );
    _subscriptions.add(player!.stream.position.listen(_positionChanged));
    _subscriptions.add(
      player!.stream.duration.listen((value) {
        duration = value;
        update();
      }),
    );
    _subscriptions.add(
      player!.stream.completed.listen((value) {
        if (value && !_opening && !_advancing) {
          if (duration > Duration.zero &&
              position >= duration - const Duration(seconds: 2)) {
            unawaited(advance(natural: true));
          } else {
            unawaited(_recoverStream());
          }
        }
      }),
    );
    _subscriptions.add(
      player!.stream.error.listen((message) {
        final occurrence = current?.occurrenceId;
        Future<void>.delayed(const Duration(seconds: 1), () {
          if (!_disposed && current?.occurrenceId == occurrence) {
            unawaited(_recoverStream());
          }
        });
      }),
    );
    if (Platform.isAndroid) {
      _session = await AudioSession.instance;
      await _session!.configure(const AudioSessionConfiguration.music());
      _subscriptions.add(
        _session!.becomingNoisyEventStream.listen((_) => unawaited(pause())),
      );
      _subscriptions.add(
        _session!.interruptionEventStream.listen((event) {
          if (event.begin) {
            if (event.type == AudioInterruptionType.duck) {
              unawaited(player!.setVolume(volume * .2));
            } else {
              _interruptedPlaying = playing;
              unawaited(pause());
            }
          } else if (event.type == AudioInterruptionType.duck) {
            unawaited(player!.setVolume(volume));
          } else if (event.type == AudioInterruptionType.pause &&
              _interruptedPlaying) {
            _interruptedPlaying = false;
            unawaited(play());
          }
        }),
      );
    }
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_background()),
    );
    if (token.isNotEmpty) {
      try {
        await connect(origin, token);
      } catch (e) {
        fail(e);
      }
    }
    await persist();
    update();
  }

  Future<void> connect(String address, String accessToken) async {
    final validated = validateServer(address);
    if (accessToken.trim().isEmpty) {
      throw const FormatException(
        'Enter the device access token from your server.',
      );
    }
    if (api != null &&
        (origin != validated || token != accessToken.trim()) &&
        outbox.isNotEmpty) {
      throw const FormatException(
        'Sync pending listening events before changing servers.',
      );
    }
    final candidate = RadioApi(validated, accessToken.trim(), deviceId);
    try {
      await candidate.call('/api/accounts');
    } catch (_) {
      candidate.close();
      rethrow;
    }
    await pause();
    api?.close();
    api = candidate;
    origin = validated;
    token = accessToken.trim();
    await secrets.write(key: 'device_token', value: token);
    connected = true;
    error = null;
    connectionMessage = 'Connected';
    await persist();
    update();
    unawaited(loadStations());
    unawaited(refreshReport());
  }

  Future<void> search(String query, {String kind = 'songs'}) async {
    if (!ready || query.trim().isEmpty) return;
    final request = ++_searchRequest;
    searchKind = kind;
    searching = true;
    results = [];
    catalogResults = [];
    error = null;
    update();
    try {
      final data = await api!.call(
        '/api/catalog/search?q=${Uri.encodeQueryComponent(query.trim())}&kind=$kind',
      );
      if (request != _searchRequest) return;
      catalogResults = (data['items'] as List)
          .map((j) => Map<String, dynamic>.from(j))
          .toList();
      if (kind == 'songs') results = catalogResults.map(Song.new).toList();
    } catch (e) {
      if (request == _searchRequest) fail(e);
    } finally {
      if (request == _searchRequest) {
        searching = false;
        update();
      }
    }
  }

  Future<void> loadStations() async {
    if (!ready) return;
    try {
      stations = (await api!.call('/api/stations') as List)
          .map((j) => Map<String, dynamic>.from(j))
          .toList();
      update();
    } catch (e) {
      fail(e);
    }
  }

  Future<void> refreshReport() async {
    if (!ready) return;
    try {
      report = Map<String, dynamic>.from(await api!.call('/api/report'));
      mergeRatings(report!['submissions'] as List? ?? []);
      await persist();
      update();
    } catch (e) {
      fail(e);
    }
  }

  void restoreRatings(dynamic saved) {
    ratings.clear();
    if (saved is Map) {
      for (final row in saved.entries) {
        ratings[row.key as String] = SongRating.fromJson(
          Map<String, dynamic>.from(row.value),
        );
      }
    }
  }

  void mergeRatings(List<dynamic> submissions) {
    for (final row in submissions) {
      final kind = row['kind'] as String;
      if (kind != 'rating' && !kind.startsWith('rating:')) continue;
      final video = row['video_id'] as String?;
      if (video == null || video.isEmpty) continue;
      final local = ratings[video];
      if (local != null &&
          outbox.any(
            (event) =>
                event['path'] == '/api/ratings' &&
                event['body']['id'] == local.eventId,
          )) {
        continue;
      }
      final eventId = kind.startsWith('rating:')
          ? kind.substring(7)
          : row['id'] as String;
      final created = row['created'] as String;
      if (local != null &&
          local.eventId != eventId &&
          !DateTime.parse(created).isAfter(DateTime.parse(local.created))) {
        continue;
      }
      ratings[video] = SongRating(
        eventId: eventId,
        value: row['value'],
        created: created,
        state: row['state'],
        detail: row['detail'] ?? '',
        tidalState: local?.eventId == eventId ? local?.tidalState : null,
        tidalValue: local?.eventId == eventId ? local?.tidalValue : null,
        tidalDetail: local?.eventId == eventId ? local?.tidalDetail : null,
        tidalId: local?.eventId == eventId ? local?.tidalId : null,
      );
    }
    for (final row in submissions) {
      final kind = row['kind'] as String;
      if (kind != 'tidal_favorite' && !kind.startsWith('tidal_favorite:')) {
        continue;
      }
      final local = ratings[row['video_id']];
      if (local == null ||
          outbox.any((event) => event['body']['id'] == local.eventId)) {
        continue;
      }
      String? eventId;
      if (kind.startsWith('tidal_favorite:')) {
        eventId = kind.substring('tidal_favorite:'.length);
      } else {
        for (final youtube in submissions) {
          if (youtube['kind'] == 'rating' &&
              youtube['occurrence_id'] == row['occurrence_id']) {
            eventId = youtube['id'];
            break;
          }
        }
      }
      if (local.eventId != eventId) continue;
      local.tidalState = row['state'];
      local.tidalValue = row['value'];
      local.tidalDetail = row['detail'] ?? '';
      local.tidalId = row['tidal_id'];
    }
  }

  Future<void> acquire({bool force = false}) async {
    await api!.call(
      '/api/device/lease',
      body: {'device_id': deviceId, 'force': force},
    );
    hasLease = true;
  }

  Future<void> start({
    Song? song,
    String selectedMode = 'autoplay',
    Map<String, dynamic>? station,
  }) async {
    if (!ready || busy || _advancing || _opening) return;
    busy = true;
    error = null;
    update();
    try {
      await acquire();
      await pause();
      _loadedOccurrence = null;
      final body = station != null
          ? {'mode': 'station', 'playlist_id': station['id']}
          : {'mode': selectedMode, 'video_id': song!.id};
      final data = Map<String, dynamic>.from(
        await api!.call('/api/queues', body: body),
      );
      _generation++;
      mode = data['mode'];
      nextCursor = data['next_cursor'];
      queueTitle =
          station?['title'] ??
          '${song!.title} · ${mode == 'autoplay' ? 'Autoplay' : 'Radio'}';
      entries = (data['tracks'] as List)
          .map((j) => QueueEntry(Song(Map<String, dynamic>.from(j))))
          .toList();
      currentIndex = -1;
      position = Duration.zero;
      quality = null;
      await persist();
      await advance();
    } catch (e) {
      fail(e);
    } finally {
      busy = false;
      update();
    }
  }

  Future<void> _more() async {
    if (_loadingMore != null) return _loadingMore;
    final loading = _fetchMore();
    _loadingMore = loading;
    try {
      await loading;
    } finally {
      _loadingMore = null;
    }
  }

  /// A finite catalog queue has no recommendation cursor. Each deliberate play
  /// creates fresh occurrences; reconnecting the same occurrence keeps its ID.
  Future<void> playSongs(
    List<Song> songs, {
    int startIndex = 0,
    String? title,
  }) async {
    if (!ready ||
        busy ||
        _advancing ||
        _opening ||
        songs.isEmpty ||
        startIndex < 0 ||
        startIndex >= songs.length) {
      return;
    }
    busy = true;
    error = null;
    update();
    try {
      await acquire();
      await pause();
      _generation++;
      _loadedOccurrence = null;
      mode = 'queue';
      nextCursor = null;
      queueTitle = title ?? songs[startIndex].title;
      entries = songs
          .map((song) => QueueEntry(song, addedByUser: true))
          .toList();
      currentIndex = startIndex - 1;
      position = duration = Duration.zero;
      quality = null;
      await persist();
      await advance();
    } catch (e) {
      fail(e);
    } finally {
      busy = false;
      update();
    }
  }

  /// Insert without changing the radio generation/cursor or interrupting audio.
  /// Next goes immediately after the current occurrence; append goes after all
  /// currently queued tracks and before recommendation pages fetched later.
  Future<int> enqueue(List<Song> songs, {bool next = false}) async {
    if (!ready || changingQueue || songs.isEmpty) return 0;
    if (entries.isEmpty && nextCursor == null) {
      mode = 'queue';
      queueTitle = 'Your queue';
      currentIndex = -1;
    }
    final additions = songs
        .map((song) => QueueEntry(song, addedByUser: true))
        .toList();
    entries.insertAll(
      next ? (currentIndex + 1).clamp(0, entries.length) : entries.length,
      additions,
    );
    try {
      await persist();
      update();
      return additions.length;
    } catch (e) {
      fail(e);
      return 0;
    }
  }

  Future<void> _fetchMore() async {
    if (nextCursor == null) return;
    final generation = _generation;
    final data = Map<String, dynamic>.from(
      await api!.call('/api/queues', body: {'cursor': nextCursor}),
    );
    if (generation != _generation) return;
    entries.addAll(
      (data['tracks'] as List).map(
        (j) => QueueEntry(Song(Map<String, dynamic>.from(j))),
      ),
    );
    nextCursor = data['next_cursor'];
    await persist();
    update();
  }

  /// Remove one occurrence, even when the same song appears more than once.
  /// The outbox and recommendation cursor belong to the session, not the row.
  Future<bool> removeOccurrence(String occurrenceId) async {
    if (changingQueue || _recovering) return false;
    final index = entries.indexWhere((e) => e.occurrenceId == occurrenceId);
    if (index < 0) return false;
    final active = index == currentIndex;
    busy = true;
    try {
      if (active) {
        // Native stop can emit a completion callback. Keep the same transition
        // guard as a manual skip so it cannot complete/advance the old row.
        _advancing = true;
        try {
          await pause();
          await player?.stop();
        } finally {
          _advancing = false;
        }
        _loadedOccurrence = null;
        position = duration = Duration.zero;
        quality = null;
      }
      entries.removeAt(index);
      if (index <= currentIndex) currentIndex--;
      if (active) {
        // Removal is an explicit skip, never a completion or a rating.
        if (!ready) {
          // Offline queue edits stay paused; reconnecting opens the next row.
          currentIndex = entries.isEmpty ? -1 : index;
        } else if (currentIndex + 1 < entries.length || nextCursor != null) {
          await advance();
        } else {
          // Keep the playback boundary beyond retained history. -1 means an
          // unstarted queue and would replay those old occurrence IDs on Play.
          currentIndex = entries.isEmpty ? -1 : entries.length;
        }
      }
      await persist();
      return true;
    } catch (e) {
      fail(e);
      return false;
    } finally {
      busy = false;
      update();
    }
  }

  Future<bool> prepare(QueueEntry entry, {bool retry = false}) async {
    if (!entry.song.available) {
      entry.status = 'skipped';
      entry.reason = 'Unavailable on YouTube Music';
      await persist();
      update();
      return false;
    }
    if (entry.tidal != null) return true;
    if (entry.status == 'skipped' && !retry) return false;
    final data = Map<String, dynamic>.from(
      await api!.call('/api/match', body: entry.song.source),
    );
    entry.candidates = (data['candidates'] as List? ?? [])
        .take(8)
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (data['status'] != 'matched') {
      entry.status = 'skipped';
      entry.reason = data['reason'] ?? 'No confident recording match';
      await persist();
      update();
      return false;
    }
    entry.tidal = Map<String, dynamic>.from(data['track']);
    entry.status = 'matched';
    entry.reason = null;
    await persist();
    update();
    return true;
  }

  Future<void> retrySkippedMatches() async {
    if (!ready || retryingMatches) return;
    retryingMatches = true;
    error = null;
    update();
    final generation = _generation;
    final skipped = entries
        .where((entry) => entry.status == 'skipped')
        .toList();
    try {
      for (final entry in skipped) {
        if (generation != _generation) break;
        await prepare(entry, retry: true);
      }
    } catch (e) {
      fail(e);
    } finally {
      retryingMatches = false;
      update();
    }
  }

  Future<void> prefetch() async {
    if (_prefetching || !ready || current == null) return;
    _prefetching = true;
    final generation = _generation;
    try {
      if (entries.length - currentIndex < 8) await _more();
      final upcoming = entries.skip(currentIndex + 1).take(5).toList();
      for (final entry in upcoming) {
        if (generation != _generation) break;
        await prepare(entry);
      }
    } catch (e) {
      fail(e);
    } finally {
      _prefetching = false;
    }
  }

  Future<void> advance({bool natural = false}) async {
    if (_advancing || _opening || !ready) return;
    if (natural && current?.status == 'completed') return;
    _advancing = true;
    try {
      if (natural && current != null) {
        current!.status = 'completed';
        await _event(0, completed: true);
      }
      await player!.pause();
      _clock.reset();
      for (int attempted = 0; attempted < 150; attempted++) {
        if (currentIndex + 1 >= entries.length && nextCursor != null) {
          await _more();
        }
        if (currentIndex + 1 >= entries.length) {
          error = mode == 'queue'
              ? null
              : 'End of recommendations. Choose another song or station.';
          break;
        }
        currentIndex++;
        position = Duration.zero;
        _reconnects = 0;
        if (!await prepare(current!)) continue;
        await _openCurrent();
        return;
      }
      await persist();
      update();
    } catch (e) {
      fail(e);
    } finally {
      _advancing = false;
    }
  }

  Future<void> selectEntry(int index) async {
    if (index < 0 || index >= entries.length || changingQueue) return;
    if (index == currentIndex && entries[index].status != 'completed') {
      await play();
      return;
    }
    busy = true;
    try {
      await pause();
      if (index < currentIndex || entries[index].status == 'completed') {
        _replayOccurrence(index);
      }
      currentIndex = index - 1;
      await advance();
    } finally {
      busy = false;
      update();
    }
  }

  void _replayOccurrence(int index) {
    final old = entries[index];
    entries[index] = QueueEntry(
      old.song,
      tidal: old.tidal,
      candidates: old.candidates,
      addedByUser: old.addedByUser,
    );
    position = Duration.zero;
  }

  Future<void> correct(QueueEntry entry, int tidalId) async {
    final result = await api!.call(
      '/api/corrections',
      body: {'video_id': entry.song.id, 'tidal_id': tidalId},
      method: 'PUT',
    );
    entry.tidal = Map<String, dynamic>.from(result['track']);
    entry.status = 'matched';
    entry.reason = null;
    await persist();
    update();
  }

  Future<void> _openCurrent({Duration? resume}) async {
    final entry = current!;
    final desired = resume ?? Duration.zero;
    _opening = true;
    quality = null;
    _clock = ListeningClock();
    duration = Duration(
      milliseconds:
          ((entry.tidal?['duration'] as num? ??
                      entry.song.duration.inMilliseconds / 1000) *
                  1000)
              .round(),
    );
    try {
      await acquire();
      await api!.call(
        '/api/occurrences',
        body: {
          'id': entry.occurrenceId,
          'tidal_id': entry.tidal!['id'],
          'video_id': entry.song.id,
        },
      );
      final stream = Map<String, dynamic>.from(
        await api!.call('/api/streams', body: {'tidal_id': entry.tidal!['id']}),
      );
      quality = {'verified': false, ...stream};
      _clock.reset();
      position = desired;
      if (_session != null && !await _session!.setActive(true)) {
        throw ApiFailure(409, 'Audio is temporarily in use by another app.');
      }
      await persist();
      _loadedOccurrence = entry.occurrenceId;
      await player!.open(
        mk.Media('$origin${stream['url']}', httpHeaders: api!.headers),
        play: false,
      );
      if (desired > Duration.zero) await player!.seek(desired);
      position = desired;
      entry.status = 'playing';
      await player!.play();
      final occurrence = entry.occurrenceId;
      unawaited(() async {
        try {
          final measured = Map<String, dynamic>.from(
            await api!.call('/api/streams/${stream['id']}/quality'),
          );
          if (current?.occurrenceId == occurrence) {
            quality = measured;
            update();
          }
        } catch (_) {
          /* Source manifest still enforces FLAC; resolution remains unverified. */
        }
      }());
      unawaited(prefetch());
    } finally {
      _opening = false;
      update();
    }
  }

  Future<void> _recoverStream() async {
    if (_recovering || _disposed) return;
    if (_opening || _advancing || current == null || _reconnects >= 3) {
      error = 'Playback interrupted. Press play to reconnect at the saved position.';
      update();
      return;
    }
    _reconnects++;
    _recovering = true;
    final saved = position;
    try {
      await player!.pause();
      await _openCurrent(resume: saved);
    } catch (e) {
      fail(e);
    } finally {
      _recovering = false;
    }
  }

  void _positionChanged(Duration value) {
    if (_loadedOccurrence == null) return;
    position = value;
    final seconds = _clock.sample(
      value.inMicroseconds / 1e6,
      _time.elapsed,
      audible: playing && !buffering && !_seeking && !_opening && volume > 0,
    );
    if (seconds > 0 && current != null) {
      unawaited(
        _event(seconds).catchError((Object e) {
          unawaited(pause());
          fail(e);
        }),
      );
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _event(double seconds, {bool completed = false}) async {
    final entry = current;
    if (entry == null || entry.tidal == null) return;
    outbox.add({
      'id': ids.v4(),
      'path': '/api/events',
      'body': {
        'id': ids.v4(),
        'occurrence_id': entry.occurrenceId,
        'seconds': seconds,
        'completed': completed,
      },
    });
    await persist();
  }

  Future<void> rate(String value) async {
    final entry = current;
    if (!ready ||
        entry == null ||
        entry.tidal == null ||
        entry.song.id.isEmpty) {
      return;
    }
    if (!['LIKE', 'DISLIKE'].contains(value)) return;
    final previous = ratings[entry.song.id];
    final selected = previous?.value == value ? 'INDIFFERENT' : value;
    final bool? tidalFavorite = selected == 'LIKE'
        ? true
        : previous?.value == 'LIKE'
        ? false
        : null;
    final eventId = ids.v4();
    final rating = SongRating(
      eventId: eventId,
      value: selected,
      created: DateTime.now().toUtc().toIso8601String(),
      state: 'queued',
      tidalState: tidalFavorite == null ? null : 'queued',
      tidalValue: tidalFavorite == null
          ? null
          : tidalFavorite
          ? 'LIKE'
          : 'INDIFFERENT',
      tidalId: tidalFavorite == null ? null : entry.tidal!['id'] as int,
    );
    ratings[entry.song.id] = rating;
    final event = <String, dynamic>{
      'id': eventId,
      'path': '/api/ratings',
      'body': {
        'id': eventId,
        'occurrence_id': entry.occurrenceId,
        'value': selected,
        'tidal_favorite': ?tidalFavorite,
      },
    };
    outbox.add(event);
    update();
    try {
      await persist();
    } catch (_) {
      outbox.removeWhere((row) => row['id'] == eventId);
      if (ratings[entry.song.id]?.eventId == eventId) {
        if (previous == null) {
          ratings.remove(entry.song.id);
        } else {
          ratings[entry.song.id] = previous;
        }
      }
      error = 'Could not save your rating on this device. Please try again.';
      update();
      return;
    }
    await sync();
  }

  Future<void> sync() async {
    while (_syncing != null) {
      await _syncing;
    }
    if (!ready) return;
    final operation = _syncOnce();
    _syncing = operation;
    try {
      await operation;
    } finally {
      _syncing = null;
    }
  }

  Future<void> _syncOnce() async {
    if (_draining || !ready) return;
    _draining = true;
    bool sentRating = false;
    try {
      await disk.settled;
      for (final event in List<Map<String, dynamic>>.from(outbox)) {
        await api!.call(
          event['path'],
          body: Map<String, dynamic>.from(event['body']),
        );
        if (event['path'] == '/api/ratings') {
          sentRating = true;
          for (final rating in ratings.values) {
            if (rating.eventId == event['body']['id']) {
              rating.state = 'pending';
              if (rating.tidalState == 'queued') rating.tidalState = 'pending';
            }
          }
        }
        outbox.removeWhere((row) => row['id'] == event['id']);
        await persist();
      }
      await api!.call('/api/reporting/dispatch', body: {});
      if (sentRating || currentRating?.needsStatus == true) {
        await refreshReport();
      }
      connectionMessage = 'Connected';
    } catch (e) {
      connectionMessage = 'Offline · listening events saved';
    } finally {
      _draining = false;
      update();
    }
  }

  Future<void> _background() async {
    if (!ready) return;
    if (!_draining) unawaited(sync());
    if (++_heartbeat % 3 == 0 && hasLease && (playing || buffering)) {
      try {
        await acquire();
      } catch (e) {
        await pause();
        hasLease = false;
        fail(e);
      }
    }
  }

  Future<void> play() async {
    if (!ready || changingQueue) return;
    try {
      if (current == null) {
        if (entries.isNotEmpty) await advance();
        return;
      }
      if (current!.status == 'completed' || player!.state.completed) {
        if (currentIndex + 1 < entries.length || nextCursor != null) {
          await advance();
          return;
        }
        _replayOccurrence(currentIndex);
        await persist();
      }
      if (!await prepare(current!)) return;
      await acquire();
      _reconnects = 0;
      if (_loadedOccurrence != current!.occurrenceId ||
          player!.state.playlist.medias.isEmpty ||
          player!.state.completed) {
        await _openCurrent(resume: position);
      } else {
        if (_session != null) await _session!.setActive(true);
        await player!.play();
      }
    } catch (e) {
      fail(e);
    }
  }

  Future<void> pause() async {
    playing = false;
    _clock.reset();
    if (player != null) await player!.pause();
    await persist();
  }

  Future<void> seek(Duration target) async {
    _seeking = true;
    _clock.reset();
    try {
      await player!.seek(target);
      position = target;
      await persist();
    } finally {
      _clock.reset();
      _seeking = false;
      update();
    }
  }

  Future<void> setVolume(double value) async {
    volume = value;
    if (value == 0) _clock.reset();
    await player?.setVolume(value);
    update();
  }

  Future<void> takeover() async {
    try {
      await acquire(force: true);
      error = null;
      await play();
      update();
    } catch (e) {
      fail(e);
    }
  }

  Future<void> shutdown() async {
    _timer?.cancel();
    await pause();
    try {
      await sync().timeout(const Duration(seconds: 3));
      await api?.call(
        '/api/device/lease',
        body: {'device_id': deviceId, 'release': true},
      );
    } catch (_) {}
    _disposed = true;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await player?.dispose();
    api?.close();
  }
}

class RadioAudioHandler extends BaseAudioHandler with SeekHandler {
  final RadioController radio;
  bool _stopped = true;
  RadioAudioHandler(this.radio) {
    radio.transportChanged = publish;
    publish();
  }
  void publish() {
    if (radio.playing) _stopped = false;
    final current = radio.current;
    if (current != null &&
        (mediaItem.value?.id != current.occurrenceId ||
            mediaItem.value?.duration != radio.duration)) {
      mediaItem.add(
        MediaItem(
          id: current.occurrenceId,
          title: current.song.title,
          artist: current.song.artist,
          album: current.song.source['album'],
          duration: radio.duration > Duration.zero
              ? radio.duration
              : current.song.duration,
          artUri: current.song.artwork == null
              ? null
              : Uri.tryParse(current.song.artwork!),
        ),
      );
    }
    playbackState.add(
      PlaybackState(
        controls: [
          radio.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1],
        playing: radio.playing,
        processingState: _stopped || current == null
            ? AudioProcessingState.idle
            : radio.buffering
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        updatePosition: radio.position,
        bufferedPosition: radio.player?.state.buffer ?? Duration.zero,
      ),
    );
  }

  @override
  Future<void> play() => radio.play();
  @override
  Future<void> pause() => radio.pause();
  @override
  Future<void> seek(Duration position) => radio.seek(position);
  @override
  Future<void> skipToNext() => radio.advance();
  @override
  Future<void> stop() async {
    _stopped = true;
    await radio.pause();
    await radio.player?.stop();
    if (radio.api != null) {
      await radio.api!.call(
        '/api/device/lease',
        body: {'device_id': radio.deviceId, 'release': true},
      );
    }
    radio.hasLease = false;
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
    await super.stop();
  }
}
