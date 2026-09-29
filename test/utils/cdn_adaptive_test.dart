import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/cdn_adaptive.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Only the pure half is exercised here.
///
/// [CdnAdaptive.probeAll] needs a network and [_maybeProbe] needs a player, so
/// neither is reachable from a headless test. Everything below is deliberately
/// free of Dio, libmpv and BuildContext.
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-cdn-test-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  // Resets the cursor, the ranking, the manual flag and the stored cache.
  setUp(CdnAdaptive.clearRanking);

  group('throughputMbps', () {
    test('a zero or negative input is zero, not infinity', () {
      expect(CdnAdaptive.throughputMbps(0, 1000), 0);
      expect(CdnAdaptive.throughputMbps(1000, 0), 0);
      expect(CdnAdaptive.throughputMbps(0, 0), 0);
      expect(CdnAdaptive.throughputMbps(-1, 1000), 0);
      expect(CdnAdaptive.throughputMbps(1000, -1), 0);
    });

    test('768 KiB in one second is about 6.29 Mbps', () {
      expect(
        CdnAdaptive.throughputMbps(768 * 1024, 1000),
        closeTo(6.2915, 0.001),
      );
    });

    test('halving the duration doubles the rate', () {
      final slow = CdnAdaptive.throughputMbps(500000, 2000);
      final fast = CdnAdaptive.throughputMbps(500000, 1000);
      expect(fast, closeTo(slow * 2, 0.0001));
    });
  });

  group('rankHosts', () {
    test('reachable hosts come first, then by measured speed', () {
      const a = CdnSample(host: CDNService.ali, ok: true, mbps: 10, ttfbMs: 90);
      const b = CdnSample(
        host: CDNService.cos,
        ok: true,
        mbps: 30,
        ttfbMs: 400,
      );
      const c = CdnSample(host: CDNService.hw, ok: true, mbps: 10, ttfbMs: 20);
      const dead = CdnSample(host: CDNService.tf_tx, ok: false);

      expect(CdnAdaptive.rankHosts(<CdnSample>[a, dead, b, c]), <CDNService>[
        CDNService.cos,
        CDNService.hw,
        CDNService.ali,
        CDNService.tf_tx,
      ]);
    });

    test('latency only breaks a throughput tie', () {
      // Same bytes, same window: the only difference is which answered first.
      const quick = CdnSample(
        host: CDNService.ali,
        ok: true,
        mbps: 10,
        ttfbMs: 20,
      );
      const slow = CdnSample(
        host: CDNService.cos,
        ok: true,
        mbps: 10,
        ttfbMs: 200,
      );
      expect(CdnAdaptive.rankHosts(<CdnSample>[slow, quick]), <CDNService>[
        CDNService.ali,
        CDNService.cos,
      ]);
    });

    test('a fast-looking failure still sorts last', () {
      const failed = CdnSample(
        host: CDNService.tf_tx,
        ok: false,
        mbps: 999,
        ttfbMs: 1,
      );
      const ok = CdnSample(
        host: CDNService.ali,
        ok: true,
        mbps: 0.1,
        ttfbMs: 900,
      );
      expect(CdnAdaptive.rankHosts(<CdnSample>[failed, ok]), <CDNService>[
        CDNService.ali,
        CDNService.tf_tx,
      ]);
    });

    test('a missing latency does not throw', () {
      const withLatency = CdnSample(
        host: CDNService.ali,
        ok: true,
        mbps: 5,
        ttfbMs: 50,
      );
      const without = CdnSample(
        host: CDNService.cos,
        ok: true,
        mbps: 5,
        ttfbMs: null,
      );
      expect(
        CdnAdaptive.rankHosts(<CdnSample>[without, withLatency]),
        <CDNService>[CDNService.ali, CDNService.cos],
      );
    });

    test('nothing to rank is empty, not a throw', () {
      expect(CdnAdaptive.rankHosts(<CdnSample>[]), isEmpty);
    });
  });

  group('rotate', () {
    test('walks the whole pool before repeating a host', () {
      final seen = <CDNService>{};
      CDNService? current;
      for (var i = 0; i < CdnAdaptive.pool.length; i++) {
        final next = CdnAdaptive.rotate(current, stalling: current);
        expect(next, isNotNull);
        expect(next, isNot(current));
        seen.add(next!);
        current = next;
      }
      expect(seen, hasLength(CdnAdaptive.pool.length));
    });

    test('never returns the stalled host', () {
      final next = CdnAdaptive.rotate(
        CDNService.cosov,
        stalling: CDNService.cosov,
      );
      expect(next, isNotNull);
      expect(next, isNot(CDNService.cosov));
    });

    test('reaches the third host instead of ping-ponging between two', () {
      // The naive "first entry that is not current" rotates back to the host it
      // just left, so a three-host pool would never try the third.
      CdnAdaptive.ranking = const <CDNService>[
        CDNService.ali,
        CDNService.cos,
        CDNService.hw,
      ];
      var current = CDNService.ali;
      final seen = <CDNService>{current};
      for (var i = 0; i < 2; i++) {
        final next = CdnAdaptive.rotate(current, stalling: current);
        expect(next, isNotNull);
        expect(next, isNot(current));
        seen.add(next!);
        current = next;
      }
      expect(seen, hasLength(3));
    });

    test('a one-host pool has nowhere to go', () {
      CdnAdaptive.ranking = const <CDNService>[CDNService.ali];
      expect(
        CdnAdaptive.rotate(CDNService.ali, stalling: CDNService.ali),
        isNull,
      );
    });

    test('with no host in use it hands back the best one, not the second', () {
      // The state right after a manual pick: the cursor is reset and nothing is
      // applied, so the first failover must not step past the top of the list.
      CdnAdaptive.ranking = const <CDNService>[
        CDNService.cosov,
        CDNService.ali,
        CDNService.hw,
      ];
      CdnAdaptive.clearOverride();
      expect(CdnAdaptive.rotate(null), CDNService.cosov);
    });

    test('never hands back the host already in use', () {
      CdnAdaptive.ranking = const <CDNService>[
        CDNService.cosov,
        CDNService.ali,
        CDNService.hw,
      ];
      // A manual pick of the top-ranked host is the common case — you pick by
      // hand because it measured fastest. Handing it back would re-open the
      // player on a byte-identical URL.
      CdnAdaptive.clearOverride();
      expect(
        CdnAdaptive.rotate(CDNService.cosov, stalling: CDNService.cosov),
        isNot(CDNService.cosov),
      );
    });

    test('excludes the failing host even when nothing is marked in use', () {
      CdnAdaptive.ranking = const <CDNService>[
        CDNService.cosov,
        CDNService.ali,
        CDNService.hw,
      ];
      CdnAdaptive.clearOverride();
      // `stalling` is the only thing that stops the cursor landing on the host
      // that is already failing here.
      expect(
        CdnAdaptive.rotate(null, stalling: CDNService.cosov),
        isNot(CDNService.cosov),
      );
    });
  });

  group('pool', () {
    test('every host is usable and none is a sentinel', () {
      for (final host in CdnAdaptive.pool) {
        expect(host.host, isNotNull, reason: '${host.name} has no host');
        expect(host, isNot(CDNService.baseUrl));
        expect(host, isNot(CDNService.backupUrl));
      }
    });

    test('has no duplicates', () {
      expect(
        CdnAdaptive.pool.toSet(),
        hasLength(CdnAdaptive.pool.length),
      );
    });

    test('akamai is excluded: it rejects a upos-signed path', () {
      expect(CdnAdaptive.pool, isNot(contains(CDNService.akamai)));
    });

    test('includes hk_bcache, the one non-reseller origin', () {
      // Pinned because the pool is otherwise a verbatim copy of the userscript's
      // CANDIDATE_POOL — a tidy-up that restores that copy exactly would silently
      // drop this host without failing anything else.
      expect(CdnAdaptive.pool, contains(CDNService.hk_bcache));
      expect(CDNService.hk_bcache.host, isNotNull);
    });

    test('leaves the redundant same-vendor nodes out', () {
      // Nine more nodes of Tencent, Alibaba and Huawei would roughly double a
      // round's data to re-measure networks the pool already covers.
      const redundant = <CDNService>[
        CDNService.alib,
        CDNService.alio1,
        CDNService.cosb,
        CDNService.coso1,
        CDNService.hwb,
        CDNService.hwo1,
        CDNService.hw_08c,
        CDNService.hw_08h,
        CDNService.hw_08ct,
      ];
      for (final host in redundant) {
        expect(
          CdnAdaptive.pool,
          isNot(contains(host)),
          reason: '${host.name} is a same-vendor node, not a new network',
        );
      }
    });
  });

  group('cache', () {
    test('a ranking survives a save and load round-trip', () {
      CdnAdaptive.ranking = const <CDNService>[
        CDNService.cosov,
        CDNService.ali,
        CDNService.hw,
      ];
      CdnAdaptive.rankedAt = DateTime.now().millisecondsSinceEpoch;
      CdnAdaptive.rankedOnWifi = true;
      CdnAdaptive.saveCache();

      CdnAdaptive.ranking = const <CDNService>[];
      expect(CdnAdaptive.ranking, isEmpty);

      CdnAdaptive.loadCache();
      expect(CdnAdaptive.ranking, <CDNService>[
        CDNService.cosov,
        CDNService.ali,
        CDNService.hw,
      ]);
      expect(CdnAdaptive.rankedOnWifi, isTrue);
    });

    test('unreadable json is ignored rather than thrown', () {
      Pref.cdnRanking = 'not json at all';
      CdnAdaptive.loadCache();
      expect(CdnAdaptive.ranking, isEmpty);
    });

    test('json of the wrong shape is ignored', () {
      Pref.cdnRanking = jsonEncode(<String, Object?>{'at': 'yesterday'});
      CdnAdaptive.loadCache();
      expect(CdnAdaptive.ranking, isEmpty);
    });

    test('an entry older than the ttl is discarded', () {
      Pref.cdnRanking = jsonEncode(<String, Object?>{
        'ranking': <String>['cosov', 'ali'],
        'at':
            DateTime.now().millisecondsSinceEpoch -
            CdnAdaptive.ttl.inMilliseconds -
            1000,
        'wifi': true,
      });
      CdnAdaptive.loadCache();
      expect(CdnAdaptive.ranking, isEmpty);
    });

    test('a host this build does not know keeps the rest usable', () {
      // An upstream rename must not make the whole cached ranking unreadable.
      Pref.cdnRanking = jsonEncode(<String, Object?>{
        'ranking': <String>['cosov', 'aHostFromAFutureVersion', 'ali'],
        'at': DateTime.now().millisecondsSinceEpoch,
        'wifi': true,
      });
      CdnAdaptive.loadCache();
      expect(CdnAdaptive.ranking, <CDNService>[
        CDNService.cosov,
        CDNService.ali,
      ]);
    });

    test('a ranking of only unknown hosts loads as no ranking', () {
      Pref.cdnRanking = jsonEncode(<String, Object?>{
        'ranking': <String>['aHostFromAFutureVersion'],
        'at': DateTime.now().millisecondsSinceEpoch,
      });
      CdnAdaptive.loadCache();
      expect(CdnAdaptive.ranking, isEmpty);
    });

    test('clearing the ranking forgets it on disk too', () {
      CdnAdaptive.ranking = const <CDNService>[CDNService.cosov];
      CdnAdaptive.rankedAt = DateTime.now().millisecondsSinceEpoch;
      CdnAdaptive.saveCache();
      expect(Pref.cdnRanking, isNotNull);

      CdnAdaptive.clearRanking();
      expect(CdnAdaptive.ranking, isEmpty);
      expect(Pref.cdnRanking, isNull);
    });

    test('an empty ranking is not written to disk', () {
      CdnAdaptive.saveCache();
      expect(Pref.cdnRanking, isNull);
    });
  });

  group('hostToApply', () {
    test('is withheld entirely while the feature is off', () async {
      await GStorage.setting.put(SettingBoxKey.autoCdn, false);
      CdnAdaptive.ranking = const <CDNService>[CDNService.cosov];
      expect(CdnAdaptive.hostToApply, isNull);
    });

    test('is the top-ranked host while the feature is on', () async {
      await GStorage.setting.put(SettingBoxKey.autoCdn, true);
      CdnAdaptive.ranking = const <CDNService>[
        CDNService.cosov,
        CDNService.ali,
      ];
      expect(CdnAdaptive.hostToApply, CDNService.cosov);
    });

    test('is withheld after a host is picked by hand', () async {
      await GStorage.setting.put(SettingBoxKey.autoCdn, true);
      CdnAdaptive.ranking = const <CDNService>[
        CDNService.cosov,
        CDNService.ali,
      ];

      CdnAdaptive.clearOverride();
      expect(CdnAdaptive.manualOverride, isTrue);
      expect(CdnAdaptive.hostToApply, isNull);

      // Turning the feature back on hands control to it again.
      CdnAdaptive.setEnabled(true);
      expect(CdnAdaptive.manualOverride, isFalse);
      expect(CdnAdaptive.hostToApply, CDNService.cosov);
    });

    test('is null before anything has been measured', () async {
      await GStorage.setting.put(SettingBoxKey.autoCdn, true);
      expect(CdnAdaptive.ranking, isEmpty);
      expect(CdnAdaptive.hostToApply, isNull);
    });

    test('turning the feature off drops the applied host', () async {
      await GStorage.setting.put(SettingBoxKey.autoCdn, true);
      CdnAdaptive.ranking = const <CDNService>[CDNService.cosov];
      CdnAdaptive.setEnabled(true);
      expect(VideoUtils.adaptiveHost, CDNService.cosov);

      CdnAdaptive.setEnabled(false);
      expect(VideoUtils.adaptiveHost, isNull);
    });
  });

  group('summary', () {
    test('reads the in-memory ranking only, and caps at three', () {
      expect(CdnAdaptive.summary, '未测速');
      CdnAdaptive.ranking = const <CDNService>[
        CDNService.cosov,
        CDNService.ali,
        CDNService.hw,
        CDNService.cos,
      ];
      expect(CdnAdaptive.summary, 'cosov · ali · hw');
    });
  });

  group('effectivePool', () {
    test('falls back to the full pool before anything is measured', () {
      expect(CdnAdaptive.effectivePool, CdnAdaptive.pool);
    });

    test('narrows to the ranking once there is one', () {
      CdnAdaptive.ranking = const <CDNService>[
        CDNService.cosov,
        CDNService.ali,
      ];
      expect(CdnAdaptive.effectivePool, <CDNService>[
        CDNService.cosov,
        CDNService.ali,
      ]);
    });
  });

  group('canAct', () {
    /// Every input in the state where nothing stops the adaptive path.
    bool canAct({
      bool autoCdn = true,
      bool fileSource = false,
      bool closed = false,
      bool pageActive = true,
      bool appVisible = true,
      bool rotationInFlight = false,
      bool dashSource = true,
      bool budgetLeft = true,
      int bufferedSeconds = 0,
      bool playing = true,
      bool withinGrace = false,
    }) => CdnAdaptive.canAct(
      autoCdn: autoCdn,
      fileSource: fileSource,
      closed: closed,
      pageActive: pageActive,
      appVisible: appVisible,
      rotationInFlight: rotationInFlight,
      dashSource: dashSource,
      budgetLeft: budgetLeft,
      bufferedSeconds: bufferedSeconds,
      playing: playing,
      withinGrace: withinGrace,
    );

    test('a fully permissive state acts', () {
      expect(canAct(), isTrue);
    });

    test('a covered page is refused however inviting everything else is', () {
      // The regression. The video underneath is neither closed nor invisible to
      // the app, and the shared player is mid-load for the page on top — so
      // `bufferedSeconds` is 0 and `playing` is true in the new video's name.
      // `pageActive` is the only input that tells the two pages apart.
      expect(canAct(pageActive: false), isFalse);
    });

    test('a covered page is refused in the exact stall shape', () {
      // What the covered page looks like when its timer fires while the page
      // above it is still loading.
      expect(
        canAct(pageActive: false, bufferedSeconds: 0, playing: true),
        isFalse,
      );
      // The identical state one page up is a genuine stall, and still acted on.
      expect(
        canAct(pageActive: true, bufferedSeconds: 0, playing: true),
        isTrue,
      );
    });

    test('each bail-out on its own is enough', () {
      expect(canAct(autoCdn: false), isFalse, reason: 'auto-CDN off');
      expect(canAct(fileSource: true), isFalse, reason: 'file source');
      expect(canAct(closed: true), isFalse, reason: 'controller closed');
      expect(canAct(appVisible: false), isFalse, reason: 'app backgrounded');
      expect(
        canAct(rotationInFlight: true),
        isFalse,
        reason: 'already rotating',
      );
      expect(canAct(dashSource: false), isFalse, reason: 'no dash source');
      expect(canAct(budgetLeft: false), isFalse, reason: 'pool exhausted');
      expect(
        canAct(bufferedSeconds: 1),
        isFalse,
        reason: 'buffer is not empty',
      );
      expect(canAct(playing: false), isFalse, reason: 'not playing');
      expect(canAct(withinGrace: true), isFalse, reason: 'inside reopen grace');
    });
  });
}
