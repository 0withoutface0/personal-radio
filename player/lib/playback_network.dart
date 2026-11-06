import 'package:media_kit/media_kit.dart' as mk;

const networkPlayerConfiguration = mk.PlayerConfiguration(
  title: 'Personal Radio',
  bufferSize: 96 * 1024 * 1024,
);

/// Temporary memory buffering, never an offline download. The time target is
/// also bounded by the byte limit, so high-resolution tracks may buffer less.
Future<void> configureNetworkPlayback(mk.Player player) async {
  final native = player.platform;
  if (native is! mk.NativePlayer) return;
  for (final option in {
    'cache-on-disk': 'no',
    'demuxer-max-back-bytes': '${8 * 1024 * 1024}',
    'cache-secs': '90',
    'demuxer-readahead-secs': '90',
    'cache-pause-wait': '3',
    'network-timeout': '10',
  }.entries) {
    await native.setProperty(option.key, option.value);
  }
}
