// ignore_for_file: implementation_imports

import 'dart:ffi';

import 'package:media_kit/ffi/src/allocation.dart';
import 'package:media_kit/ffi/src/utf8.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/player/real.dart';

/// Reads how fast the player is actually pulling bytes off the network.
///
/// The bili-accelerator userscript gets this for free by counting bytes as the
/// browser receives them (`recordTransfer` / `tickSpeed`). Nothing on the Dart
/// side of this app sees a media byte: libmpv performs the fetch in native code,
/// which is why `CdnAdaptive` can only react to a stall rather than to a speed.
/// The number is not actually unavailable though — mpv tracks it, and
/// `NativePlayer.ctx` is a public handle to the live mpv instance, so one
/// property read reaches it.
///
/// mpv exposes `demuxer-cache-state` as a map; `raw-input-rate` in that map is
/// the raw byte rate of the stream being read, before demuxing. That is the
/// closest thing to "current download speed" mpv offers.
///
/// Polling is used rather than `mpv_observe_property`. An observer would have to
/// be registered against media_kit's own observer ids and serviced from its
/// event loop; a 1 Hz `mpv_get_property` needs neither and is called only while
/// something is on screen asking for it.
///
/// **This is a readout. It changes nothing about playback.** Nothing here is
/// wired into host selection, and it must not be: any host change tears the
/// player down, so a number that could trigger one is a number that can cause a
/// reload the user did not ask for.
abstract final class MpvNetStats {
  static final _mpv = NativePlayer.mpv;

  static const _cacheStateProperty = 'demuxer-cache-state';

  /// The key inside `demuxer-cache-state` holding the raw input byte rate.
  static const rawInputRateKey = 'raw-input-rate';

  /// Bytes per second currently being read, or null when mpv cannot say.
  ///
  /// Null is a normal answer, not a failure: the property is absent on a
  /// non-network source, before the demuxer has warmed up, and on any libmpv
  /// that does not carry it. Callers fall back to [bufferFillRate] rather than
  /// showing a zero, which would read as "stalled" when it means "unknown".
  static double? readBytesPerSecond(NativePlayer player) {
    final ctx = player.ctx;
    if (ctx == nullptr) {
      return null;
    }

    final name = _cacheStateProperty.toNativeUtf8();
    final node = calloc<generated.mpv_node>();
    try {
      final rc = _mpv.mpv_get_property(
        ctx,
        name,
        generated.mpv_format.MPV_FORMAT_NODE,
        node.cast<Void>(),
      );
      if (rc < 0) {
        return null;
      }
      try {
        return rawInputRate(_readMap(node));
      } finally {
        // Frees the map, its keys and its values — everything mpv allocated
        // into the node. The node struct itself is ours and is freed below.
        _mpv.mpv_free_node_contents(node);
      }
    } catch (_) {
      // A property read must never take playback down with it.
      return null;
    } finally {
      calloc
        ..free(name)
        ..free(node);
    }
  }

  // ---- pure logic (unit-tested, no IO) ------------------------------------

  /// Pulls [rawInputRateKey] out of an already-flattened cache-state map.
  ///
  /// Accepts a string as well as a number: mpv types this field as an integer,
  /// but a build that hands it back through a node-to-string path would
  /// otherwise read as "unknown".
  static double? rawInputRate(Map<String, Object?> cacheState) {
    final value = cacheState[rawInputRateKey];
    final double? rate = switch (value) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s),
      _ => null,
    };
    if (rate == null || !rate.isFinite || rate < 0) {
      return null;
    }
    return rate;
  }

  /// Bytes per second as megabits per second.
  static double toMbps(double bytesPerSecond) =>
      bytesPerSecond <= 0 || !bytesPerSecond.isFinite
      ? 0
      : bytesPerSecond * 8 / 1e6;

  /// Fallback for when [readBytesPerSecond] returns null: how fast the buffer
  /// is filling, in seconds of buffer gained per second of wall clock.
  ///
  /// This is deliberately **not** a speed and must never be labelled as one.
  /// Above 1 the player is buffering faster than it is playing; at or below 1 it
  /// is losing ground and a stall is coming. That is a health signal, not a
  /// throughput measurement, and the two are not interchangeable.
  static double bufferFillRate(double bufferedSec, double elapsedSec) {
    if (elapsedSec <= 0) {
      return 0;
    }
    final rate = bufferedSec / elapsedSec;
    return rate.isFinite && rate > 0 ? rate : 0;
  }

  // ---- FFI plumbing -------------------------------------------------------

  /// Flattens an `MPV_FORMAT_NODE_MAP` node into a Dart map.
  ///
  /// Values are reduced to scalars; a nested map or array becomes null, which
  /// is all this needs — `raw-input-rate` sits at the top level.
  static Map<String, Object?> _readMap(Pointer<generated.mpv_node> node) {
    final ref = node.ref;
    if (ref.format != generated.mpv_format.MPV_FORMAT_NODE_MAP) {
      return const <String, Object?>{};
    }
    final list = ref.u.list;
    if (list == nullptr) {
      return const <String, Object?>{};
    }
    final count = list.ref.num;
    if (count <= 0) {
      return const <String, Object?>{};
    }

    final keys = list.ref.keys;
    final values = list.ref.values;
    final out = <String, Object?>{};
    for (var i = 0; i < count; i++) {
      final keyPtr = keys[i];
      if (keyPtr == nullptr) {
        continue;
      }
      out[keyPtr.toDartString()] = _readScalar(values[i]);
    }
    return out;
  }

  static Object? _readScalar(generated.mpv_node node) {
    return switch (node.format) {
      generated.mpv_format.MPV_FORMAT_DOUBLE => node.u.double_,
      generated.mpv_format.MPV_FORMAT_INT64 => node.u.int64,
      generated.mpv_format.MPV_FORMAT_FLAG => node.u.flag != 0,
      generated.mpv_format.MPV_FORMAT_STRING => switch (node.u.string) {
        final ptr when ptr != nullptr => ptr.toDartString(),
        _ => null,
      },
      _ => null,
    };
  }
}
