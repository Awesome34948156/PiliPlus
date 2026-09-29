import 'package:PiliPlus/plugin/pl_player/utils/mpv_net_stats.dart';
import 'package:flutter_test/flutter_test.dart';

/// Only the pure half is exercised here.
///
/// [MpvNetStats.readBytesPerSecond] needs a live mpv handle, which a headless
/// test has no way to obtain — that is exactly why the FFI read and the
/// interpretation of its result are separate functions. Everything below is
/// free of libmpv, so the maths is pinned down without it.
///
/// Importing this library does not load the native side: `_mpv` is a lazy
/// `static final` and nothing here touches it.
void main() {
  group('rawInputRate', () {
    test('reads an integer byte rate', () {
      expect(
        MpvNetStats.rawInputRate({MpvNetStats.rawInputRateKey: 524288}),
        524288,
      );
    });

    test('reads a double byte rate', () {
      expect(
        MpvNetStats.rawInputRate({MpvNetStats.rawInputRateKey: 524288.5}),
        closeTo(524288.5, 0.001),
      );
    });

    test('reads a rate handed back as a string', () {
      expect(
        MpvNetStats.rawInputRate({MpvNetStats.rawInputRateKey: '524288'}),
        524288,
      );
      // Not a number in any sense.
      expect(
        MpvNetStats.rawInputRate({MpvNetStats.rawInputRateKey: 'fast'}),
        isNull,
      );
    });

    test('a missing key is unknown, not zero', () {
      expect(MpvNetStats.rawInputRate(const {}), isNull);
      expect(MpvNetStats.rawInputRate(const {'other': 1}), isNull);
    });

    test('a wrong-typed value is unknown', () {
      expect(
        MpvNetStats.rawInputRate({MpvNetStats.rawInputRateKey: true}),
        isNull,
      );
      expect(
        MpvNetStats.rawInputRate({MpvNetStats.rawInputRateKey: null}),
        isNull,
      );
      expect(
        MpvNetStats.rawInputRate({
          MpvNetStats.rawInputRateKey: <int>[1],
        }),
        isNull,
      );
    });

    test('a negative or non-finite rate is unknown', () {
      expect(
        MpvNetStats.rawInputRate({MpvNetStats.rawInputRateKey: -1}),
        isNull,
      );
      expect(
        MpvNetStats.rawInputRate({MpvNetStats.rawInputRateKey: double.nan}),
        isNull,
      );
      expect(
        MpvNetStats.rawInputRate(
          {MpvNetStats.rawInputRateKey: double.infinity},
        ),
        isNull,
      );
    });

    test('zero is a real reading, not unknown', () {
      // A stalled stream genuinely reads zero; it must not be mistaken for
      // "mpv cannot say", which is what drives the fallback.
      expect(MpvNetStats.rawInputRate({MpvNetStats.rawInputRateKey: 0}), 0);
    });
  });

  group('toMbps', () {
    test('a non-positive or non-finite rate is zero', () {
      expect(MpvNetStats.toMbps(0), 0);
      expect(MpvNetStats.toMbps(-1), 0);
      expect(MpvNetStats.toMbps(double.nan), 0);
      expect(MpvNetStats.toMbps(double.infinity), 0);
    });

    test('125000 bytes per second is one megabit', () {
      expect(MpvNetStats.toMbps(125000), closeTo(1, 0.0001));
    });

    test('768 KiB per second matches the probe suite', () {
      expect(MpvNetStats.toMbps(768 * 1024), closeTo(6.2915, 0.001));
    });
  });

  group('bufferFillRate', () {
    test('a second of buffer gained per second is 1', () {
      expect(MpvNetStats.bufferFillRate(1, 1), closeTo(1, 0.0001));
    });

    test('gaining ground reads above 1, losing it below', () {
      expect(MpvNetStats.bufferFillRate(2, 1), closeTo(2, 0.0001));
      expect(MpvNetStats.bufferFillRate(0.5, 1), closeTo(0.5, 0.0001));
    });

    test('an elapsed of zero or less is zero, not infinity', () {
      expect(MpvNetStats.bufferFillRate(5, 0), 0);
      expect(MpvNetStats.bufferFillRate(5, -1), 0);
      expect(MpvNetStats.bufferFillRate(0, 0), 0);
    });

    test('a buffer that drained reads zero, never negative', () {
      expect(MpvNetStats.bufferFillRate(-3, 1), 0);
    });
  });
}
