import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

abstract final class VideoUtils {
  static CDNService cdnService = Pref.defaultCDNService;
  static String? liveCdnUrl = Pref.liveCdnUrl;
  static bool disableAudioCDN = Pref.disableAudioCDN;

  /// Host chosen by adaptive selection, or null to use [cdnService].
  ///
  /// Session-scoped on purpose: the automatic pick must never be written back
  /// over the user's saved `Pref.defaultCDNService`. Owned by
  /// `utils/cdn_adaptive.dart`.
  static CDNService? adaptiveHost;

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';

  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );

  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
    bool adaptive = true,
  }) {
    // An explicit host always wins: the settings speed test measures each
    // candidate by passing one in per row, and would otherwise measure the
    // adaptive host over and over.
    defaultCDNService ??= (adaptive ? adaptiveHost : null) ?? cdnService;

    if (defaultCDNService == CDNService.baseUrl) {
      return urls.first;
    }

    String? mcdnTf;
    String? mcdnUpgcxcode;

    String last = '';
    for (final url in urls) {
      last = url;
      if (_mirrorRegex.hasMatch(url)) {
        final uri = Uri.parse(url);
        if (uri.queryParameters['os'] == 'mcdn') {
          // upos-sz-mirrorcoso1.bilivideo.com os=mcdn
          mcdnUpgcxcode = url;
        } else {
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return uri.replace(host: defaultCDNService.host).toString();
        }
      }

      if (_mCdnTfRegex.hasMatch(url)) {
        mcdnTf = url;
        continue;
      }

      // upos-\w*-302.* & bcache & mcdn host but upgcxcode path
      if (url.contains('/upgcxcode/')) {
        mcdnUpgcxcode = url;
        continue;
      }

      // may be deprecated
      if (url.contains('szbdyd.com')) {
        final uri = Uri.parse(url);
        final hostname =
            uri.queryParameters['xy_usource'] ?? defaultCDNService.host;
        return uri
            .replace(scheme: 'https', host: hostname, port: 443)
            .toString();
      }

      if (kDebugMode) {
        debugPrint('unknown cdn type: $url');
      }
    }

    return mcdnUpgcxcode == null
        ? mcdnTf == null
              ? last
              : Uri(
                  scheme: 'https',
                  host: _proxyTf,
                  queryParameters: {'url': mcdnTf},
                ).toString()
        : Uri.parse(mcdnUpgcxcode)
              .replace(host: defaultCDNService.host ?? CDNService.ali.host)
              .toString();
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    final urlInfo = e.urlInfo.getOrFirst(index);
    return (liveCdnUrl ?? urlInfo.host) + e.baseUrl + urlInfo.extra;
  }

  static VideoDecodeFormatType selectCodec(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    if (preferCodecs.isNotEmpty) {
      int bestIndex = preferCodecs.length;
      for (final e in codecs) {
        for (int i = 0; i < bestIndex; i++) {
          if (preferCodecs[i].codes.any(e.startsWith)) {
            bestIndex = i;
            if (bestIndex == 0) {
              return preferCodecs[0];
            }
            break;
          }
        }
      }
      if (bestIndex < preferCodecs.length) {
        return preferCodecs[bestIndex];
      }
    }
    return VideoDecodeFormatType.fromString(codecs.first);
  }

  /// Picks the video rendition to play for one quality, and reports the decode
  /// format that actually belongs to it.
  ///
  /// [items] must already be filtered to the target quality. [seed] is the
  /// format advertised for that quality by `support_formats`; it is a hint
  /// only, and is frequently absent from [items] — the advertised list and the
  /// returned `dash.video` renditions come from different places, the list is
  /// silently substituted with the top quality's when the target quality is
  /// not in it, and `_supplementVideoQualities` merges in a second response.
  ///
  /// This is the single source of truth for rendition selection: the first
  /// open and every reload (quality change, CDN rotation) must agree. When
  /// they diverge, the first open can land on a rendition the device cannot
  /// decode — audio plays while the video stream is dropped, until some later
  /// reload happens to pick a good one. Falling back to `items.first` is the
  /// bug this exists to prevent.
  static (VideoItem, VideoDecodeFormatType) selectVideoRendition(
    List<VideoItem> items,
    VideoDecodeFormatType seed,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    assert(items.isNotEmpty, 'target quality has no renditions');

    // The advertised format wins when it is really there.
    for (final item in items) {
      if (seed.codes.any(item.codecs!.startsWith)) {
        return (item, seed);
      }
    }

    // Otherwise take the best format the user prefers that actually exists.
    int bestIndex = preferCodecs.length;
    VideoItem? best;
    for (final item in items) {
      final c = item.codecs!;
      for (int i = 0; i < bestIndex; i++) {
        if (preferCodecs[i].codes.any(c.startsWith)) {
          bestIndex = i;
          best = item;
          break;
        }
      }
      if (bestIndex == 0) break;
    }
    if (best != null) {
      return (best, preferCodecs[bestIndex]);
    }

    // Nothing matched a preference: keep the rendition, but at least report
    // the format it really carries rather than a mismatched seed.
    return (items.first, VideoDecodeFormatType.fromString(items.first.codecs!));
  }
}
