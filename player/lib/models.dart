import 'dart:math' as math;

import 'package:uuid/uuid.dart';

const ids = Uuid();

class Song {
  final Map<String, dynamic> source;
  Song(Map<String, dynamic> json) : source = Map.of(json);
  String get id => source['video_id'] as String? ?? '';
  String get title => source['title'] as String? ?? 'Unknown song';
  List<String> get artists => List<String>.from(source['artists'] ?? const []);
  String get artist => artists.join(', ');
  String? get artwork => source['artwork'] as String?;
  String? get albumId => source['album_id'] as String?;
  List<Map<String, dynamic>> get artistRefs =>
      (source['artist_refs'] as List? ?? [])
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
  bool get available => id.isNotEmpty && source['available'] != false;
  Duration get duration => Duration(
    milliseconds: ((source['duration'] as num? ?? 0) * 1000).round(),
  );
}

class QueueEntry {
  final Song song;
  final String occurrenceId;
  String status;
  String? reason;
  Map<String, dynamic>? tidal;
  List<Map<String, dynamic>> candidates;
  final bool addedByUser;
  QueueEntry(
    this.song, {
    String? occurrenceId,
    this.status = 'pending',
    this.reason,
    this.tidal,
    this.candidates = const [],
    this.addedByUser = false,
  }) : occurrenceId = occurrenceId ?? ids.v4();
  factory QueueEntry.fromJson(Map<String, dynamic> json) => QueueEntry(
    Song(Map<String, dynamic>.from(json['song'])),
    occurrenceId: json['id'],
    status: json['status'] ?? 'pending',
    reason: json['reason'],
    tidal: json['tidal'] == null
        ? null
        : Map<String, dynamic>.from(json['tidal']),
    candidates: (json['candidates'] as List? ?? [])
        .map((item) => Map<String, dynamic>.from(item))
        .toList(),
    addedByUser: json['added_by_user'] == true,
  );
  Map<String, dynamic> toJson() => {
    'id': occurrenceId,
    'song': song.source,
    'status': status,
    'reason': reason,
    'tidal': tidal,
    'candidates': candidates,
    'added_by_user': addedByUser,
  };
}

class SongRating {
  final String eventId, value, created;
  String state, detail;
  String? tidalState, tidalValue, tidalDetail;
  int? tidalId;
  SongRating({
    required this.eventId,
    required this.value,
    required this.created,
    required this.state,
    this.detail = '',
    this.tidalState,
    this.tidalValue,
    this.tidalDetail,
    this.tidalId,
  });
  factory SongRating.fromJson(Map<String, dynamic> json) => SongRating(
    eventId: json['event_id'],
    value: json['value'],
    created: json['created'],
    state: json['state'],
    detail: json['detail'] ?? '',
    tidalState: json['tidal_state'],
    tidalValue: json['tidal_value'],
    tidalDetail: json['tidal_detail'],
    tidalId: json['tidal_id'],
  );
  Map<String, dynamic> toJson() => {
    'event_id': eventId,
    'value': value,
    'created': created,
    'state': state,
    'detail': detail,
    'tidal_state': tidalState,
    'tidal_value': tidalValue,
    'tidal_detail': tidalDetail,
    'tidal_id': tidalId,
  };
  String get action => switch (value) {
    'LIKE' => 'Like',
    'DISLIKE' => 'Dislike',
    _ => 'Rating removal',
  };
  bool get needsStatus =>
      state == 'pending' ||
      state == 'sending' ||
      (state == 'submitted' && value == 'LIKE') ||
      ['queued', 'pending', 'sending', 'submitted'].contains(tidalState);
  bool get uncertain => state == 'uncertain' || tidalState == 'uncertain';
  String get details =>
      [detail, if (tidalDetail != null) 'Tidal: $tidalDetail'].join('\n');
  String get label =>
      tidalState == null ? youtubeLabel : '$youtubeLabel\n$tidalLabel';
  String get tidalLabel => switch (tidalState) {
    'queued' => 'Tidal: saved on this device · waiting to send',
    'pending' || 'sending' => 'Tidal: sending favorite change…',
    'visible' =>
      tidalValue == 'LIKE' ? 'Liked on Tidal' : 'Like removed from Tidal',
    'submitted' => 'Tidal: request sent · verification pending',
    'uncertain' => 'Tidal: outcome uncertain · check your favorites',
    'superseded' => 'Tidal: replaced by a newer choice',
    _ => 'Tidal: status unavailable',
  };
  String get youtubeLabel => switch (state) {
    'saving' => 'Saving rating…',
    'queued' => '$action saved on this device · waiting to send',
    'pending' || 'sending' => 'Sending rating to YouTube Music…',
    'visible' =>
      value == 'LIKE'
          ? 'Liked on YouTube Music'
          : value == 'DISLIKE'
          ? 'Disliked on YouTube Music'
          : 'Rating removed',
    'submitted' =>
      value == 'INDIFFERENT'
          ? 'Rating removed · request sent'
          : '$action sent to YouTube Music',
    'uncertain' => 'Rating outcome uncertain · check YouTube Music',
    _ => 'Rating status unavailable',
  };
}

class ListeningClock {
  double? _position;
  Duration? _time;
  double total = 0;
  void reset() {
    _position = null;
    _time = null;
  }

  double sample(double position, Duration monotonic, {required bool audible}) {
    if (!audible) {
      reset();
      return 0;
    }
    double seconds = 0;
    if (_position != null && _time != null) {
      final wall = (monotonic - _time!).inMicroseconds / 1e6;
      final media = position - _position!;
      if (wall > 0 && wall <= 2 && media > 0 && media <= wall + .35) {
        seconds = math.min(wall, media);
      }
    }
    _position = position;
    _time = monotonic;
    total += seconds;
    return seconds;
  }
}

String timeLabel(Duration value) {
  final seconds = value.inSeconds.clamp(0, 10000000);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
