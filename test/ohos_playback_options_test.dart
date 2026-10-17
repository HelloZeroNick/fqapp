import 'package:fqapp/services/ohos_playback_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isContentKeyHex', () {
    test('accepts a 32 character lowercase hex key', () {
      expect(isContentKeyHex('0123456789abcdef0123456789abcdef'), isTrue);
    });

    test('accepts a 32 character uppercase hex key', () {
      // The regex is the strict lowercase form; callers lower-case before
      // testing, so an upper-case literal is rejected here on purpose.
      expect(isContentKeyHex('0123456789ABCDEF0123456789ABCDEF'), isFalse);
    });

    test('rejects keys with the wrong length', () {
      expect(isContentKeyHex(''), isFalse);
      expect(isContentKeyHex('0123456789abcdef0123456789abcde'), isFalse);
      expect(isContentKeyHex('0123456789abcdef0123456789abcdeff'), isFalse);
    });

    test('rejects non-hex characters', () {
      expect(isContentKeyHex('0123456789abcdef0123456789abcdeg'), isFalse);
      expect(isContentKeyHex(' 123456789abcdef0123456789abcdef'), isFalse);
      expect(isContentKeyHex('0123456789abcdef0123456789abcdef '), isFalse);
    });
  });

  group('ohosDemuxerLavfOptions', () {
    test('appends the whitelist and the decryption key', () {
      final options = ohosDemuxerLavfOptions(
        protocolWhitelist: ohosProtocolWhitelist,
        contentKeyHex: '0123456789abcdef0123456789abcdef',
      );
      expect(options, contains('seg_max_retry=5'));
      expect(options, contains('strict=experimental'));
      expect(options, contains('allowed_extensions=ALL'));
      expect(
        options,
        contains('protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto]'),
      );
      expect(options, contains('decryption_key=0123456789abcdef0123456789abcdef'));
    });

    test('omits decryption_key when the key is missing', () {
      final options = ohosDemuxerLavfOptions(
        protocolWhitelist: ohosProtocolWhitelist,
      );
      expect(options, isNot(contains('decryption_key')));
    });

    test('omits decryption_key when the key is malformed', () {
      // A malformed key must not reach FFmpeg: the option is parsed verbatim
      // and a bad value would silently disable decryption instead of failing.
      final options = ohosDemuxerLavfOptions(
        protocolWhitelist: ohosProtocolWhitelist,
        contentKeyHex: 'not-a-key',
      );
      expect(options, isNot(contains('decryption_key')));
    });

    test('normalises the key to lowercase', () {
      final options = ohosDemuxerLavfOptions(
        protocolWhitelist: ohosProtocolWhitelist,
        contentKeyHex: '0123456789ABCDEF0123456789ABCDEF',
      );
      expect(options, contains('decryption_key=0123456789abcdef0123456789abcdef'));
    });

    test('uses the supplied whitelist', () {
      final options = ohosDemuxerLavfOptions(
        protocolWhitelist: ['file', 'https'],
      );
      expect(options, contains('protocol_whitelist=[file,https]'));
      expect(options, isNot(contains('udp')));
    });

    test('emits one comma separated string', () {
      final options = ohosDemuxerLavfOptions(
        protocolWhitelist: ohosProtocolWhitelist,
        contentKeyHex: '0123456789abcdef0123456789abcdef',
      );
      expect(options.split(',').length, greaterThan(1));
      expect(options, isNot(contains(';')));
    });
  });

  group('ohosDisplaySize', () {
    test('keeps the coded size when the rotation is upright', () {
      for (final rotate in [0, 180]) {
        final size = ohosDisplaySize(
          displayWidth: 1920,
          displayHeight: 1080,
          rotate: rotate,
        );
        expect(size.width, 1920);
        expect(size.height, 1080);
      }
    });

    test('swaps the axes for quarter and three quarter turns', () {
      for (final rotate in [90, 270]) {
        final size = ohosDisplaySize(
          displayWidth: 1920,
          displayHeight: 1080,
          rotate: rotate,
        );
        expect(size.width, 1080);
        expect(size.height, 1920);
      }
    });

    test('treats an unexpected rotation as upright', () {
      final size = ohosDisplaySize(
        displayWidth: 1920,
        displayHeight: 1080,
        rotate: 45,
      );
      expect(size.width, 1920);
      expect(size.height, 1080);
    });
  });

  group('ohosClampSurface', () {
    test('keeps sizes within the limit untouched', () {
      final size = ohosClampSurface(width: 1920, height: 1080);
      expect(size.width, 1920);
      expect(size.height, 1080);
    });

    test('scales the longest edge down to the limit', () {
      final size = ohosClampSurface(width: 7680, height: 4320);
      expect(size.width, 4096);
      expect(size.height, 2304);
    });

    test('scales portrait sources without squashing them', () {
      final size = ohosClampSurface(width: 1080, height: 7680);
      expect(size.width, 576);
      expect(size.height, 4096);
    });

    test('never rounds a dimension down to zero', () {
      final size = ohosClampSurface(width: 4096, height: 1);
      expect(size.height, 1);
    });
  });

  group('ohosVolume', () {
    test('maps 0..1 onto 0..100', () {
      expect(ohosVolume(0), 0);
      expect(ohosVolume(1), 100);
      expect(ohosVolume(0.5), 50);
    });

    test('clamps out of range values', () {
      expect(ohosVolume(-1), 0);
      expect(ohosVolume(2), 100);
    });
  });
}
