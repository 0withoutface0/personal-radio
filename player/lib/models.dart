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
  QueueEntry(
    this.song, {
    String? occurrenceId,
    this.status = 'pending',
    this.reason,
    this.tidal,
  }) : occurrenceId = occurrenceId ?? ids.v4();
  factory QueueEntry.fromJson(Map<String, dynamic> json) => QueueEntry(
    Song(Map<String, dynamic>.from(json['song'])),
    occurrenceId: json['id'],
    status: json['status'] ?? 'pending',
    reason: json['reason'],
    tidal: json['tidal'] == null
        ? null
        : Map<String, dynamic>.from(json['tidal']),
  );
  Map<String, dynamic> toJson() => {
    'id': occurrenceId,
    'song': song.source,
    'status': status,
    'reason': reason,
    'tidal': tidal,
  };
}

class SongRating {
  final String eventId, value, created;
  String state, detail;
  SongRating({
    required this.eventId,
    required this.value,
    required this.created,
    required this.state,
    this.detail = '',
  });
  factory SongRating.fromJson(Map<String, dynamic> json) => SongRating(
    eventId: json['event_id'],
    value: json['value'],
    created: json['created'],
    state: json['state'],
    detail: json['detail'] ?? '',
  );
  Map<String, dynamic> toJson() => {
    'event_id': eventId,
    'value': value,
    'created': created,
    'state': state,
    'detail': detail,
  };
  String get action => switch (value) {
    'LIKE' => 'Like',
    'DISLIKE' => 'Dislike',
    _ => 'Rating removal',
  };
  bool get needsStatus =>
      state == 'pending' ||
      state == 'sending' ||
      (state == 'submitted' && value == 'LIKE');
  String get label => switch (state) {
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
