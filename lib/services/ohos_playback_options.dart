/// Pure mapping helpers for the OpenHarmony libmpv playback backend.
///
/// The heavy part of that backend (lib/services/ohos_playback.dart) drives an
/// mpv instance and a platform texture, so it cannot run under `flutter test`.
/// Everything that is pure arithmetic or string assembly lives here instead, so
/// the option/geometry mapping -- the part that actually breaks playback when it
/// is wrong -- is covered by ordinary unit tests.
library;

/// Content keys this app's sources carry: a 16-byte AES key written as
/// lowercase hex. Mirrors `_contentKeyPattern` in lib/models/chapter_media.dart,
/// which is what validates the key before it reaches a player.
final _contentKeyPattern = RegExp(r'^[0-9a-f]{32}$');

/// media_kit's own default for `PlayerConfiguration.protocolWhitelist`. Duplicated
/// deliberately: the string assembled below must stay valid even if the package
/// changes its default, and the backend passes this list when it builds the
/// configuration it hands to media_kit.
const List<String> ohosProtocolWhitelist = <String>[
  'udp',
  'rtp',
  'tcp',
  'tls',
  'data',
  'file',
  'http',
  'https',
  'crypto',
];

/// The `demuxer-lavf-o` value media_kit installs for every player, minus the
/// protocol whitelist, which is templated in by [ohosDemuxerLavfOptions].
///
/// These are FFmpeg AVFormatContext options that media_kit relies on for HLS and
/// for the odd extensions this app's CDN serves, so they must survive the
/// decryption key being appended.
const String _baseDemuxerLavfOptions = 'seg_max_retry=5,'
    'strict=experimental,'
    'allowed_extensions=ALL';

/// True when [value] is a usable AES-128 content key in this app's format.
bool isContentKeyHex(String value) => _contentKeyPattern.hasMatch(value);

/// Builds the per-media `demuxer-lavf-o` string.
///
/// `decryption_key` is an FFmpeg mov demuxer option: given a 16-byte AES key it
/// decrypts CENC AES-CTR samples as they are read, using the sample-level
/// senc/saio/saiz offsets in the container. That is the whole reason this app
/// needs no local decryption library on OHOS -- the bundled libmpv already
/// contains the demuxer that implements it.
///
/// The option is appended rather than assigned because `demuxer-lavf-o` is a
/// single comma-separated string: replacing it would silently drop media_kit's
/// other format options.
String ohosDemuxerLavfOptions({
  required List<String> protocolWhitelist,
  String? contentKeyHex,
}) {
  final buffer = StringBuffer(_baseDemuxerLavfOptions)
    ..write(',protocol_whitelist=[')
    ..write(protocolWhitelist.join(','))
    ..write(']');
  final key = contentKeyHex?.trim().toLowerCase();
  if (key != null && isContentKeyHex(key)) {
    buffer.write(',decryption_key=');
    buffer.write(key);
  }
  return buffer.toString();
}

/// Display-oriented pixel size for a decoded frame.
///
/// `dw`/`dh` are mpv's `video-params` display dimensions and `rotate` is the
/// clockwise rotation mpv reports for the file. mpv applies that rotation to its
/// output, so for 90/270 the axes are swapped -- this is exactly what the OHOS
/// video controller in media_kit does, and the surface buffer must be sized to
/// match or the picture is stretched into the wrong box.
({int width, int height}) ohosDisplaySize({
  required int displayWidth,
  required int displayHeight,
  required int rotate,
}) {
  final quarterTurned = rotate == 90 || rotate == 270;
  return quarterTurned
      ? (width: displayHeight, height: displayWidth)
      : (width: displayWidth, height: displayHeight);
}

/// Converts this app's 0..1 volume (callers only ever pass 0 or 1) into mpv's
/// 0..100 scale, clamping so a stray value cannot be rejected by mpv.
double ohosVolume(double volume) {
  if (volume.isNaN) return 0;
  return (volume * 100).clamp(0, 100).toDouble();
}

/// Longest edge mpv will be asked to render. HarmonyOS caps a texture axis, and
/// an over-sized request is dropped rather than clamped, which shows up as a
/// silently black video. Mirrors media_kit's `_maxSurfaceDimension`.
const int ohosMaxSurfaceDimension = 4096;

/// Scales [width]x[height] down so neither axis exceeds
/// [ohosMaxSurfaceDimension], preserving the aspect ratio.
({int width, int height}) ohosClampSurface({
  required int width,
  required int height,
}) {
  final longest = width > height ? width : height;
  if (longest <= ohosMaxSurfaceDimension || longest <= 0) {
    return (width: width, height: height);
  }
  final scale = ohosMaxSurfaceDimension / longest;
  return (
    width: (width * scale).round().clamp(1, ohosMaxSurfaceDimension),
    height: (height * scale).round().clamp(1, ohosMaxSurfaceDimension),
  );
}
