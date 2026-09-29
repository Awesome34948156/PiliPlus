import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// One host's measurement from a probe round.
class CdnSample {
  const CdnSample({
    required this.host,
    required this.ok,
    this.mbps = 0,
    this.ttfbMs,
  });

  final CDNService host;

  /// Reachable and moved at least one byte. A slow host is still [ok] — it
  /// stays rankable so rotation has somewhere to fall back to once the fast
  /// hosts are exhausted.
  final bool ok;

  /// Measured transfer rate, from first byte to the end of the sample.
  final double mbps;

  /// Time to first byte, only ever used to break an [mbps] tie.
  final int? ttfbMs;
}

/// Adaptive CDN selection: measure every candidate host, rank by throughput,
/// and rotate to the next one when playback stalls.
///
/// Ported from the bili-accelerator userscript's probe/rank/rotate loop. The
/// rewrite *rules* already live in [VideoUtils.getCdnUrl] and are not repeated
/// here — this class only decides which host that function should target.
///
/// The userscript can also measure *live playback* throughput by counting bytes
/// at the XHR layer. That is impossible here: libmpv performs the media fetch in
/// native code, so Dio never sees a media request. Selection is therefore
/// stall-triggered rather than throughput-triggered.
abstract final class CdnAdaptive {
  /// Hosts that are safe to probe and rank.
  ///
  /// The first eight are the userscript's `CANDIDATE_POOL` verbatim. Akamai is
  /// excluded for the reason it gives there: it rejects a upos-signed path with
  /// 403, so it can never win a probe and only wastes a slot.
  ///
  /// [CDNService.hk_bcache] is added on top — Bilibili's own Hong Kong cache,
  /// and the only candidate here that is a different *origin* rather than
  /// another node of Tencent, Alibaba or Huawei. The rest of [CDNService]
  /// (`alib`, `alio1`, `cosb`, `coso1`, `hwb`, `hwo1` and the three `08*`
  /// nodes) is deliberately left out: nine more nodes of those same three
  /// vendors, which would roughly double a round's data for little new signal.
  ///
  /// Both mainland and overseas tiers belong here and the probe decides between
  /// them; the order below only sets the pre-probe preference, and it leads with
  /// overseas because that is what the userscript shipped. Its audience was
  /// overseas viewers; this app's skews mainland. The probe is what settles it
  /// per viewer, so baking either geography in would be the bug, not the fix.
  static const List<CDNService> pool = <CDNService>[
    CDNService.cosov,
    CDNService.aliov,
    CDNService.hwov,
    CDNService.hk_bcache,
    CDNService.ali,
    CDNService.tf_hw,
    CDNService.hw,
    CDNService.cos,
    CDNService.tf_tx,
  ];

  /// How long a ranking stays usable.
  static const Duration ttl = Duration(hours: 6);

  /// Bytes to read per host before cancelling. Reads are bounded rather than
  /// ranged: a Range header is not preflight-safe everywhere.
  static const int probeBytes = 768 * 1024;

  /// A host that cannot deliver [probeBytes] inside this window is aborted
  /// mid-read and scored on whatever it did move.
  static const Duration probeTimeout = Duration(seconds: 4);

  /// Grace period before a buffering event counts as a stall. Keeps a seek or a
  /// tab switch from triggering a rotation.
  static const Duration stallGrace = Duration(milliseconds: 2500);

  /// Re-check interval while a stall persists, because libmpv's buffering
  /// signal fires once per episode rather than repeatedly.
  static const Duration stallRetry = Duration(seconds: 5);

  /// Ranked hosts, best first. Empty until the first probe lands.
  static List<CDNService> ranking = const <CDNService>[];

  /// Last round's measurements in ranked order, for display only.
  static List<CdnSample> lastSamples = const <CdnSample>[];

  /// Epoch milliseconds of the last successful probe.
  static int? rankedAt;

  /// Connection type the ranking was measured on. A ranking learned on WiFi is
  /// not trusted on cellular.
  static bool? rankedOnWifi;

  static int _cursor = 0;

  /// Bumped by [clearOverride]; a probe result landing after a manual host pick
  /// is discarded instead of yanking the user off their choice.
  static int _generation = 0;

  static Future<bool>? _inflight;

  /// Set when the user picks a host by hand. Suppresses the automatic pick for
  /// the rest of the session — otherwise [hostToApply] would silently overwrite
  /// their choice every time a video opens, and the override would do nothing.
  /// Stall rotation still applies: that is the point of failover.
  static bool manualOverride = false;

  /// The host [VideoUtils.getCdnUrl] should prefer, or null to fall through to
  /// the user's configured `Pref.defaultCDNService`.
  static CDNService? get best => ranking.isEmpty ? null : ranking.first;

  /// What to apply when a video opens, or null to leave the user's own choice
  /// alone. Read once per video, before any URL is built.
  static CDNService? get hostToApply =>
      (!enabled || manualOverride) ? null : best;

  /// Pool that rotation walks: the measured ranking once there is one.
  static List<CDNService> get effectivePool =>
      ranking.isNotEmpty ? ranking : pool;

  /// Cheap in-memory label for the settings subtitle. Settings search calls this
  /// on every keystroke, so it must never touch IO.
  static String get summary {
    if (ranking.isEmpty) return '未测速';
    return ranking.take(3).map((CDNService e) => e.name).join(' · ');
  }

  static bool get enabled => Pref.autoCdn;

  // ---- pure logic (unit-tested, no IO) ------------------------------------

  /// Whether the adaptive path may touch the player at all right now.
  ///
  /// Written as a plain conjunction so every bail-out is testable without a
  /// player, a route or a clock. The one that is easy to leave out is
  /// [pageActive]: a covered page is not a closed page, so `isClosed` cannot
  /// stand in for it. Tapping a related video pushes a second video page on top
  /// of the first and the first stays alive — same controller, and the same
  /// singleton player underneath. Without this check the covered page watches
  /// the *new* video buffering (`bufferedSeconds` is 0 because that video is
  /// still loading, and `playing` is the new video's state), concludes the
  /// stream is stalling, and re-opens **its own** URL over the video the viewer
  /// is actually watching.
  static bool canAct({
    required bool autoCdn,
    required bool fileSource,
    required bool closed,
    required bool pageActive,
    required bool appVisible,
    required bool rotationInFlight,
    required bool dashSource,
    required bool budgetLeft,
    required int bufferedSeconds,
    required bool playing,
    required bool withinGrace,
  }) =>
      autoCdn &&
      !fileSource &&
      !closed &&
      pageActive &&
      appVisible &&
      !rotationInFlight &&
      dashSource &&
      budgetLeft &&
      bufferedSeconds == 0 &&
      playing &&
      !withinGrace;

  /// Bytes over a duration as megabits per second.
  static double throughputMbps(int bytes, int durationMs) {
    if (bytes <= 0 || durationMs <= 0) {
      return 0;
    }
    return (bytes * 8 / 1e6) / (durationMs / 1000);
  }

  /// Order hosts best-first: reachable ones ahead of failures, then by measured
  /// throughput descending.
  ///
  /// Transfer rate decides when it was measured; [CdnSample.ttfbMs] only breaks
  /// ties. Time to first byte is mostly round-trip latency and swings about
  /// tenfold between back-to-back samples of the same host, so ranking on it let
  /// a mainland mirror that merely answered headers promptly outrank an overseas
  /// one that actually moves several times the bytes.
  static List<CDNService> rankHosts(List<CdnSample> samples) {
    final sorted = List<CdnSample>.of(samples)..sort(_compareSamples);
    return sorted.map((CdnSample s) => s.host).toList(growable: false);
  }

  static int _compareSamples(CdnSample a, CdnSample b) {
    if (a.ok != b.ok) {
      return a.ok ? -1 : 1;
    }
    if (!a.ok) {
      return 0;
    }
    if (a.mbps != b.mbps) {
      return b.mbps.compareTo(a.mbps);
    }
    final int? aLat = a.ttfbMs;
    final int? bLat = b.ttfbMs;
    if (aLat == bLat) {
      return 0;
    }
    // A missing latency sorts last rather than throwing.
    if (aLat == null) return 1;
    if (bLat == null) return -1;
    return aLat.compareTo(bLat);
  }

  /// Walk the pool one step and return the next host to try.
  ///
  /// Deliberately a wrapping cursor rather than "the first entry that isn't
  /// current": that version ping-pongs between the top two entries forever —
  /// rank[0] rotates to rank[1], whose own stall rotates straight back to
  /// rank[0] — leaving the rest of the pool unreachable.
  static CDNService? rotate(CDNService? current, {CDNService? stalling}) {
    final list = effectivePool;
    if (list.isEmpty) {
      return null;
    }

    // Nothing is in use yet — no ranking applied, or the user took manual
    // control. There is no host to step away from, so hand back the top of the
    // list; advancing here would skip the best host on the first failover.
    if (current == null) {
      for (var i = 0; i < list.length; i++) {
        final candidate = list[(_cursor + i) % list.length];
        if (candidate != stalling) {
          return candidate;
        }
      }
      return null;
    }

    for (var i = 0; i < list.length; i++) {
      _cursor = (_cursor + 1) % list.length;
      final candidate = list[_cursor];
      if (candidate != current && candidate != stalling) {
        return candidate;
      }
    }
    return null;
  }

  // ---- state changes ------------------------------------------------------

  /// Apply the toggle. Enabling adopts the cached best host immediately and
  /// hands control back from any earlier manual pick; disabling drops back to
  /// the user's configured service.
  static void setEnabled(bool value) {
    if (value) {
      manualOverride = false;
    }
    VideoUtils.adaptiveHost = value ? best : null;
  }

  /// Forget the automatic pick and send rotation back to the top of the
  /// ranking. Called when the user chooses a host by hand, so a probe landing
  /// afterwards cannot override them.
  static void clearOverride() {
    manualOverride = true;
    VideoUtils.adaptiveHost = null;
    _cursor = 0;
    _generation++;
  }

  /// Drop the cached ranking and re-probe on the next opportunity. Also hands
  /// control back to the automatic pick — asking for a fresh ranking is the
  /// user asking the feature to do its job again.
  static void clearRanking() {
    ranking = const <CDNService>[];
    lastSamples = const <CdnSample>[];
    rankedAt = null;
    rankedOnWifi = null;
    _cursor = 0;
    _generation++;
    manualOverride = false;
    VideoUtils.adaptiveHost = null;
    saveCache();
  }

  // ---- cache --------------------------------------------------------------

  /// Restore a ranking saved by a previous session. A corrupt or unreadable
  /// entry is treated as "no ranking", never as an error.
  static void loadCache() {
    final raw = Pref.cdnRanking;
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final at = decoded['at'];
      final names = decoded['ranking'];
      if (at is! int || names is! List) {
        return;
      }
      if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) {
        return;
      }
      final restored = <CDNService>[];
      for (final name in names) {
        // Tolerant lookup: a host renamed by an upstream update must not make
        // the whole cached ranking unusable.
        final found = _serviceByName(name);
        if (found != null && !restored.contains(found)) {
          restored.add(found);
        }
      }
      if (restored.isEmpty) {
        return;
      }
      ranking = restored;
      rankedAt = at;
      rankedOnWifi = decoded['wifi'] is bool ? decoded['wifi'] as bool : null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CdnAdaptive: ignoring unreadable ranking cache: $e');
      }
    }
  }

  /// Persist the ranking. Public and paired with [loadCache] so the round-trip
  /// between them is testable without reaching into privates.
  static void saveCache() {
    Pref.cdnRanking = ranking.isEmpty
        ? null
        : jsonEncode(<String, Object?>{
            'ranking': ranking.map((CDNService e) => e.name).toList(),
            'at': rankedAt,
            'wifi': rankedOnWifi,
          });
  }

  static CDNService? _serviceByName(Object? name) {
    if (name is! String) {
      return null;
    }
    for (final service in CDNService.values) {
      if (service.name == name) {
        return service;
      }
    }
    return null;
  }

  // ---- probing ------------------------------------------------------------

  /// Probe every pool host against [sampleUrls] and adopt the winner.
  ///
  /// Returns true when the applied host changed, so the caller can decide
  /// whether a reload is worth it. Concurrent calls share one round.
  static Future<bool> ensureRanking(List<String> sampleUrls) {
    final existing = _inflight;
    if (existing != null) {
      return existing;
    }
    final round = _runRanking(sampleUrls);
    _inflight = round;
    return round.whenComplete(() => _inflight = null);
  }

  static Future<bool> _runRanking(List<String> sampleUrls) async {
    if (!enabled || sampleUrls.isEmpty) {
      return false;
    }
    if (await _rankingIsFresh()) {
      return false;
    }
    final generation = _generation;

    final samples = await probeAll(sampleUrls);
    final reachable = samples
        .where((CdnSample s) => s.ok)
        .toList(growable: false);
    final ranked = rankHosts(reachable);
    if (ranked.isEmpty) {
      return false;
    }

    // Keep the display order aligned with the ranking, failures last.
    lastSamples = <CdnSample>[
      for (final host in ranked)
        reachable.firstWhere((CdnSample s) => s.host == host),
      ...samples.where((CdnSample s) => !s.ok),
    ];
    ranking = ranked;
    rankedAt = DateTime.now().millisecondsSinceEpoch;
    rankedOnWifi = await ConnectivityUtils.isWiFi;
    saveCache();

    // The user took manual control, or turned the feature off, while this round
    // was in flight. Keep the measurements — they are worth showing — but do
    // not move playback onto them.
    if (generation != _generation || manualOverride || !enabled) {
      return false;
    }

    final next = best;
    if (next == null || next == VideoUtils.adaptiveHost) {
      return false;
    }
    VideoUtils.adaptiveHost = next;
    return true;
  }

  static Future<bool> _rankingIsFresh() async {
    final at = rankedAt;
    if (ranking.isEmpty || at == null) {
      return false;
    }
    if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) {
      return false;
    }
    final wifi = await ConnectivityUtils.isWiFi;
    return rankedOnWifi == null || rankedOnWifi == wifi;
  }

  /// Measure every pool host in parallel.
  static Future<List<CdnSample>> probeAll(List<String> sampleUrls) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: <String, String>{
          'user-agent': BrowserUa.pc,
          'referer': HttpString.baseUrl,
        },
      ),
    );
    return Future.wait(
      pool.map((CDNService host) => _probeOne(dio, host, sampleUrls)),
    );
  }

  static Future<CdnSample> _probeOne(
    Dio dio,
    CDNService host,
    List<String> sampleUrls,
  ) async {
    // Re-request the *same signed* URL on another host. The signature covers
    // the path and the client, not the hostname, so the segment stays valid —
    // that is what makes measuring every host from one URL possible. A host
    // that cannot serve the content answers non-2xx here and is never ranked.
    final url = VideoUtils.getCdnUrl(
      sampleUrls,
      defaultCDNService: host,
    );
    if (url.isEmpty || !url.startsWith('http')) {
      return CdnSample(host: host, ok: false);
    }

    final token = CancelToken();
    final started = _nowMs();
    var firstByteAt = 0;
    var bytes = 0;

    final timer = Timer(probeTimeout, token.cancel);
    try {
      await dio.get<void>(
        url,
        cancelToken: token,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (int count, int total) {
          if (count <= 0) {
            return;
          }
          if (firstByteAt == 0) {
            firstByteAt = _nowMs();
          }
          if (count > bytes) {
            bytes = count;
          }
          if (bytes >= probeBytes) {
            token.cancel();
          }
        },
      );
    } catch (_) {
      // Cancellation at probeBytes, the timeout, and genuine network failures
      // all land here. The measurement below decides which of those happened —
      // an aborted-but-partial transfer is a slow host, not a broken one, and
      // discarding it left rotation with nothing to fall back to.
    } finally {
      timer.cancel();
    }

    if (bytes > 0 && firstByteAt > 0) {
      return CdnSample(
        host: host,
        ok: true,
        mbps: throughputMbps(bytes, _nowMs() - firstByteAt),
        ttfbMs: firstByteAt - started,
      );
    }
    return CdnSample(host: host, ok: false);
  }

  static int _nowMs() => DateTime.now().microsecondsSinceEpoch ~/ 1000;
}
