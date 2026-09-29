import 'package:PiliPlus/models_new/live/live_room_play_info/url_info.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// Live-stream PCDN host filtering.
///
/// Ported from the bili-accelerator userscript's `isSlowLiveHost` /
/// `filterLiveUrlInfo` (`src/core/rewrite.js`). Live playurl payloads don't
/// carry full media URLs — each codec entry lists candidate hosts in
/// `url_info: [{host, extra}]`, and the first one is what the player uses. On
/// busy rooms that first host is often a residential PCDN node: fine for a
/// viewer near it, stall-prone for anyone else, and impossible to notice from
/// the app because there is nothing to compare against.
///
/// Only the leaf decision is ported. The userscript's `filterLiveUrlInfo`
/// deep-walks an untyped payload — it needs `maxDepth` and a `WeakSet` to avoid
/// looping on a self-referential object. Here `stream[].format[].codec[].urlInfo`
/// is typed, so there is nothing to walk and nothing to guard against: the
/// caller has already arrived at the list.
///
/// This class never mutates a host list. It reports *which index to use*, so the
/// picker keeps showing every host the server offered and a user who knows a
/// PCDN node is fast for them can still choose it by hand.
abstract final class LiveCdnFilter {
  static bool get enabled => Pref.liveFilterPcdn;

  static final _ipRe = RegExp(r'^(?:\d{1,3}\.){3}\d{1,3}$');
  static final _xyMcdnRe = RegExp(
    r'^xy(?:\d+x){3}\d+xy\.mcdn\.bilivideo\.(?:cn|com|net)$',
  );
  static final _mcdnRe = RegExp(r'\.mcdn\.bilivideo\.(?:cn|com|net)$');

  /// Matched against `extra`, which is not lower-cased, hence the flag.
  static final _osMcdnRe = RegExp(
    r'(?:^|[?&])os=mcdn(?:&|$)',
    caseSensitive: false,
  );

  // P2P/PCDN families known from community research (Bilibili-Evolved, MBGTEB):
  // szbdyd is the legacy scheduler, mountaintoys the 2025 rename, nexusedgeio and
  // ahdohpiechei are where the upos-*302* redirect hosts land, and mirror14b is a
  // mirror-named host that actually serves PCDN (its TLS cert is *.bilivideo.cn).
  static const _knownP2pHosts = <String>['upos-sz-mirror14b.bilivideo.com'];
  static const _knownP2pSuffixes = <String>[
    '.szbdyd.com',
    '.mountaintoys.cn',
    '.nexusedgeio.com',
    '.ahdohpiechei.com',
  ];

  // ---- pure logic (unit-tested, no IO) ------------------------------------

  /// Whether one live host looks like a PCDN/P2P node rather than an official
  /// CDN edge.
  ///
  /// [host] may be a bare hostname, a `//host` fragment or a full URL — live
  /// `url_info` entries are not consistent about which. [extra] is the query
  /// fragment that rides along with the host in the same entry.
  static bool isSlowLiveHost(
    String host, {
    String? extra,
    bool portHeuristic = true,
  }) {
    final raw = host.trim();
    if (raw.isEmpty) {
      return false;
    }

    final Uri uri;
    try {
      uri = Uri.parse(
        raw.contains('://')
            ? raw
            // A leading `//` is a scheme-relative URL, not a path.
            : 'https://${raw.startsWith('//') ? raw.substring(2) : raw}',
      );
    } catch (_) {
      return false;
    }

    // `Uri.parse` is lenient where the userscript's `new URL()` throws, so an
    // input that would have raised there arrives here as an empty host. That is
    // the stand-in for the JS catch block.
    final hostname = uri.host.toLowerCase();
    if (hostname.isEmpty) {
      return false;
    }

    if (_ipRe.hasMatch(hostname) ||
        _xyMcdnRe.hasMatch(hostname) ||
        _mcdnRe.hasMatch(hostname) ||
        _isKnownP2pHost(hostname)) {
      return true;
    }

    if (portHeuristic && _hasNonDefaultPort(uri)) {
      return true;
    }

    return extra != null && _osMcdnRe.hasMatch(extra);
  }

  /// Index of the first host in [hosts] that is not a PCDN node, or 0 when
  /// there is nothing better to pick.
  ///
  /// Order is otherwise the server's. Returning 0 rather than "no answer" when
  /// every entry looks slow is deliberate, and mirrors the userscript: it never
  /// removes the last usable host, because a PCDN node that looks slow on paper
  /// may still be the only thing serving this room.
  static int firstFastIndex(
    List<UrlInfo> hosts, {
    bool portHeuristic = true,
  }) {
    // A single-entry list has no alternative, so it is never reindexed.
    if (hosts.length <= 1) {
      return 0;
    }
    for (var i = 0; i < hosts.length; i++) {
      final item = hosts[i];
      if (!isSlowLiveHost(
        item.host,
        extra: item.extra,
        portHeuristic: portHeuristic,
      )) {
        return i;
      }
    }
    return 0;
  }

  /// The index a live stream should start on. 0 (the server's own first choice)
  /// whenever the filter is switched off.
  static int autoIndex(List<UrlInfo> hosts) =>
      enabled ? firstFastIndex(hosts) : 0;

  // ---- internals ----------------------------------------------------------

  static bool _isKnownP2pHost(String hostname) {
    if (_knownP2pHosts.contains(hostname)) {
      return true;
    }
    for (final suffix in _knownP2pSuffixes) {
      // Must end the hostname *and* consume more than the suffix, so
      // `evil.mountaintoys.cn.attacker.com` is not mistaken for a match.
      if (hostname.length > suffix.length && hostname.endsWith(suffix)) {
        return true;
      }
    }
    // upos-sz-302ppio / upos-sz-302kodo style hosts answer with an HTTP 302 to
    // a residential P2P node; the "302" only ever appears in that first label.
    return hostname.startsWith('upos-') &&
        hostname.split('.').first.contains('302');
  }

  static bool _hasNonDefaultPort(Uri uri) {
    // The userscript reads `url.port`, which the URL API leaves empty when the
    // port matches the scheme default. Dart's `hasPort` is not that flag — it
    // tracks whether a port was written at all — so the default ports are
    // excluded explicitly. Both are needed: this stays correct whether or not
    // the parser normalises an explicit `:443` away.
    return uri.hasPort && uri.port != 80 && uri.port != 443;
  }
}
