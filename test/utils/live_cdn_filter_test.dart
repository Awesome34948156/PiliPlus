import 'dart:io';

import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/url_info.dart';
import 'package:PiliPlus/utils/live_cdn_filter.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Only the pure half is exercised here.
///
/// [LiveCdnFilter] is deliberately IO-free apart from reading one preference,
/// so everything below runs without a player, a network or a BuildContext.
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-live-cdn-test-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  // The filter is on by default, so every test starts from an unset key.
  setUp(() async {
    await GStorage.setting.delete(SettingBoxKey.liveFilterPcdn);
    VideoUtils.liveCdnUrl = null;
  });

  tearDown(() => VideoUtils.liveCdnUrl = null);

  UrlInfo host(String host, [String extra = '']) =>
      UrlInfo(host: host, extra: extra);

  group('isSlowLiveHost', () {
    test('a bare IP literal is a PCDN node', () {
      expect(LiveCdnFilter.isSlowLiveHost('1.2.3.4'), isTrue);
      expect(LiveCdnFilter.isSlowLiveHost('https://1.2.3.4/x'), isTrue);
      expect(LiveCdnFilter.isSlowLiveHost('1.2.3.4:8080'), isTrue);
    });

    test('the xy...xy mcdn family is slow, with or without a scheme', () {
      const bare = 'xy1x2x3x4xy.mcdn.bilivideo.cn';
      expect(LiveCdnFilter.isSlowLiveHost(bare), isTrue);
      expect(LiveCdnFilter.isSlowLiveHost('$bare:486'), isTrue);
      expect(
        LiveCdnFilter.isSlowLiveHost('https://$bare:486/live-bvc/'),
        isTrue,
      );
      expect(LiveCdnFilter.isSlowLiveHost('//$bare'), isTrue);
    });

    test('a generic mcdn host is slow', () {
      expect(LiveCdnFilter.isSlowLiveHost('a.mcdn.bilivideo.com'), isTrue);
      expect(LiveCdnFilter.isSlowLiveHost('b.mcdn.bilivideo.net'), isTrue);
    });

    test('an ordinary official CDN host is not slow', () {
      expect(
        LiveCdnFilter.isSlowLiveHost('upos-sz-mirrorcos.bilivideo.com'),
        isFalse,
      );
      expect(
        LiveCdnFilter.isSlowLiveHost(
          'https://cn-hbyc-cmcc-live-01.bilivideo.com/live-bvc/x.m3u8',
        ),
        isFalse,
      );
    });

    test('mirror14b serves PCDN, other mirrors of the same shape do not', () {
      expect(
        LiveCdnFilter.isSlowLiveHost('upos-sz-mirror14b.bilivideo.com'),
        isTrue,
      );
      expect(
        LiveCdnFilter.isSlowLiveHost('upos-sz-mirrorcos.bilivideo.com'),
        isFalse,
      );
    });

    test('every known P2P family suffix is caught', () {
      for (final suffix in <String>[
        '.szbdyd.com',
        '.mountaintoys.cn',
        '.nexusedgeio.com',
        '.ahdohpiechei.com',
      ]) {
        expect(
          LiveCdnFilter.isSlowLiveHost('node1x$suffix'),
          isTrue,
          reason: '$suffix should be slow',
        );
      }
    });

    test('a suffix must end the hostname, not merely appear in it', () {
      // Not preceded by a dot, so not the family.
      expect(LiveCdnFilter.isSlowLiveHost('notszbdyd.com'), isFalse);
      // A real host tucked inside an attacker-controlled name.
      expect(
        LiveCdnFilter.isSlowLiveHost('evil.mountaintoys.cn.attacker.com'),
        isFalse,
      );
      // The suffix alone, with no label in front of it.
      expect(LiveCdnFilter.isSlowLiveHost('szbdyd.com'), isFalse);
    });

    test('302 only counts in the first label of a upos- host', () {
      expect(
        LiveCdnFilter.isSlowLiveHost('upos-sz-302ppio.bilivideo.com'),
        isTrue,
      );
      expect(
        LiveCdnFilter.isSlowLiveHost('upos-sz-302kodo.bilivideo.com'),
        isTrue,
      );
      // 302 in the path is a signed segment number, not a redirect host.
      expect(
        LiveCdnFilter.isSlowLiveHost(
          'upos-sz-mirrorcos.bilivideo.com/upgcxcode/302/12.m4s',
        ),
        isFalse,
      );
      // A non-upos host is not judged this way.
      expect(LiveCdnFilter.isSlowLiveHost('cdn302.example.com'), isFalse);
    });

    test('a non-default port is a PCDN tell', () {
      expect(
        LiveCdnFilter.isSlowLiveHost('https://a.bilivideo.com:8080/x'),
        isTrue,
      );
      expect(
        LiveCdnFilter.isSlowLiveHost('https://a.bilivideo.com:486/x'),
        isTrue,
      );
      // Explicit defaults are not a tell.
      expect(
        LiveCdnFilter.isSlowLiveHost('https://a.bilivideo.com:443/x'),
        isFalse,
      );
      expect(
        LiveCdnFilter.isSlowLiveHost('http://a.bilivideo.com:80/x'),
        isFalse,
      );
      // No port at all.
      expect(LiveCdnFilter.isSlowLiveHost('a.bilivideo.com'), isFalse);
    });

    test('portHeuristic: false ignores the port', () {
      expect(
        LiveCdnFilter.isSlowLiveHost(
          'https://a.bilivideo.com:8080/x',
          portHeuristic: false,
        ),
        isFalse,
      );
    });

    test('os=mcdn in extra marks the host, however it is delimited', () {
      const clean = 'upos-sz-mirrorcos.bilivideo.com';
      expect(LiveCdnFilter.isSlowLiveHost(clean, extra: '?os=mcdn'), isTrue);
      expect(
        LiveCdnFilter.isSlowLiveHost(clean, extra: '?os=mcdn&x=1'),
        isTrue,
      );
      expect(LiveCdnFilter.isSlowLiveHost(clean, extra: '&os=mcdn'), isTrue);
      expect(LiveCdnFilter.isSlowLiveHost(clean, extra: 'os=mcdn'), isTrue);
    });

    test('a longer os value is not os=mcdn', () {
      expect(
        LiveCdnFilter.isSlowLiveHost('a.bilivideo.com', extra: '?os=mcdnng'),
        isFalse,
      );
      expect(
        LiveCdnFilter.isSlowLiveHost('a.bilivideo.com', extra: '?xos=mcdn'),
        isFalse,
      );
      expect(
        LiveCdnFilter.isSlowLiveHost('a.bilivideo.com', extra: '?os=other'),
        isFalse,
      );
      expect(LiveCdnFilter.isSlowLiveHost('a.bilivideo.com'), isFalse);
    });

    test('empty and unparseable input is not slow, and never throws', () {
      expect(LiveCdnFilter.isSlowLiveHost(''), isFalse);
      expect(LiveCdnFilter.isSlowLiveHost('   '), isFalse);
      expect(LiveCdnFilter.isSlowLiveHost('http://'), isFalse);
      expect(LiveCdnFilter.isSlowLiveHost(':::'), isFalse);
    });
  });

  group('firstFastIndex', () {
    test('skips a leading PCDN host for the first clean one', () {
      final hosts = <UrlInfo>[
        host('xy1x2x3x4xy.mcdn.bilivideo.cn:486'),
        host('upos-sz-mirrorcos.bilivideo.com'),
      ];
      expect(LiveCdnFilter.firstFastIndex(hosts), 1);
    });

    test('keeps the server order among clean hosts', () {
      final hosts = <UrlInfo>[
        host('a.mcdn.bilivideo.com'),
        host('upos-sz-mirrorcos.bilivideo.com'),
        host('upos-sz-mirrorali.bilivideo.com'),
      ];
      expect(LiveCdnFilter.firstFastIndex(hosts), 1);
      // Swapping the two clean entries moves the answer with them.
      expect(
        LiveCdnFilter.firstFastIndex(<UrlInfo>[hosts[0], hosts[2], hosts[1]]),
        1,
      );
    });

    test('a list where everything looks slow stays on index 0', () {
      final hosts = <UrlInfo>[
        host('1.2.3.4'),
        host('b.mcdn.bilivideo.com'),
      ];
      expect(LiveCdnFilter.firstFastIndex(hosts), 0);
    });

    test('a single host is never reindexed, even if it is slow', () {
      expect(
        LiveCdnFilter.firstFastIndex(<UrlInfo>[host('1.2.3.4')]),
        0,
      );
    });

    test('an empty list returns 0', () {
      expect(LiveCdnFilter.firstFastIndex(<UrlInfo>[]), 0);
    });

    test('a clean host with os=mcdn in extra is skipped too', () {
      final hosts = <UrlInfo>[
        host('upos-sz-mirrorcos.bilivideo.com', '?os=mcdn'),
        host('upos-sz-mirrorali.bilivideo.com'),
      ];
      expect(LiveCdnFilter.firstFastIndex(hosts), 1);
    });
  });

  group('autoIndex', () {
    test('filters by default, without the key ever being written', () {
      expect(LiveCdnFilter.enabled, isTrue);
      final hosts = <UrlInfo>[
        host('xy1x2x3x4xy.mcdn.bilivideo.cn:486'),
        host('upos-sz-mirrorcos.bilivideo.com'),
      ];
      expect(LiveCdnFilter.autoIndex(hosts), 1);
    });

    test('stays on the server order once switched off', () async {
      await GStorage.setting.put(SettingBoxKey.liveFilterPcdn, false);
      expect(LiveCdnFilter.enabled, isFalse);
      final hosts = <UrlInfo>[
        host('xy1x2x3x4xy.mcdn.bilivideo.cn:486'),
        host('upos-sz-mirrorcos.bilivideo.com'),
      ];
      expect(LiveCdnFilter.autoIndex(hosts), 0);
    });
  });

  group('getLiveCdnUrl', () {
    CodecItem codec() => CodecItem(
      codecName: 'avc',
      currentQn: 10000,
      acceptQn: <int>[10000],
      baseUrl: '/live-bvc/1.m3u8',
      urlInfo: <UrlInfo>[
        host('xy1x2x3x4xy.mcdn.bilivideo.cn:486', '?os=mcdn'),
        host('https://upos-sz-mirrorcos.bilivideo.com', '?sign=abc'),
      ],
    );

    test('the served host is used verbatim when no override is set', () {
      expect(
        VideoUtils.getLiveCdnUrl(codec(), index: 1),
        'https://upos-sz-mirrorcos.bilivideo.com/live-bvc/1.m3u8?sign=abc',
      );
    });

    test('the index only chooses which entry rides along', () {
      expect(
        VideoUtils.getLiveCdnUrl(codec(), index: 0),
        'xy1x2x3x4xy.mcdn.bilivideo.cn:486/live-bvc/1.m3u8?os=mcdn',
      );
    });

    test('a user-set host replaces the served one but keeps the entry', () {
      VideoUtils.liveCdnUrl = 'https://my-own.example';
      expect(
        VideoUtils.getLiveCdnUrl(codec(), index: 1),
        'https://my-own.example/live-bvc/1.m3u8?sign=abc',
      );
      // The override does not resurrect the PCDN entry's own host.
      expect(
        VideoUtils.getLiveCdnUrl(codec(), index: 0),
        'https://my-own.example/live-bvc/1.m3u8?os=mcdn',
      );
    });
  });
}
