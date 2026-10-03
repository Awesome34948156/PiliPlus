import 'dart:io';

import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Only the pure half is exercised here.
///
/// [VideoUtils.selectVideoRendition] is deliberately free of the player, the
/// network and BuildContext, so the choice the first open makes and the choice
/// every reload makes can be compared head to head.
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-rendition-test-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  const prefer = [VideoDecodeFormatType.AVC, VideoDecodeFormatType.AV1];

  group('selectVideoRendition', () {
    test('takes a rendition the device prefers over the first one listed', () {
      // `support_formats` advertises Dolby Vision, but no returned rendition
      // carries it. The old first-open path fell through to items.first and
      // played HEVC; AVC is further down the list but is the wanted codec.
      final items = [rendition(hevc), rendition(avc)];

      final (item, format) = firstOpen(items, [dvh1], prefer);

      expect(item.codecs, avc);
      expect(format, VideoDecodeFormatType.AVC);
    });

    test('honours the advertised format when it is really present', () {
      final items = [rendition(avc), rendition(av1)];

      final (item, format) = firstOpen(items, [av1], prefer);

      expect(item.codecs, av1);
      expect(format, VideoDecodeFormatType.AV1);
    });

    test('follows preference order, not the order of the rendition list', () {
      // AVC is listed first, but HEVC is the stronger preference and neither
      // is the advertised format, so the preference order has to decide.
      final items = [rendition(avc), rendition(hevc)];

      final (item, format) = firstOpen(items, [dvh1], [
        VideoDecodeFormatType.HEVC,
        VideoDecodeFormatType.AVC,
      ]);

      expect(item.codecs, hevc);
      expect(format, VideoDecodeFormatType.HEVC);
    });

    test('reports the format the rendition really carries when none match', () {
      final items = [rendition(hevc)];

      final (item, format) = firstOpen(items, [dvh1], prefer);

      expect(item.codecs, hevc);
      expect(format, VideoDecodeFormatType.HEVC);
    });

    test('never reports a format that does not match the rendition', () {
      // The invariant the mismatched-seed bug broke: the caller stores the
      // reported format as currentDecodeFormats, so a mismatch there means the
      // next reload aims at a codec that is not on screen.
      const all = [avc, hevc, av1, dvh1];
      for (final a in all) {
        for (final b in all) {
          final items = [rendition(a), rendition(b)];
          for (final seed in VideoDecodeFormatType.values) {
            final (item, format) = VideoUtils.selectVideoRendition(
              items,
              seed,
              prefer,
            );
            expect(
              format.codes.any(item.codecs!.startsWith),
              isTrue,
              reason: 'reported ${format.name} for ${item.codecs}',
            );
          }
        }
      }
    });
  });

  group('the first open and a later reload agree', () {
    test('when the advertised format is absent from the renditions', () {
      // This is the reported bug: the first open picked items.first, so the
      // video stream was dropped and only audio played; changing the audio
      // quality forced a reload, which picked a decodable rendition.
      final items = [rendition(hevc), rendition(avc)];
      final advertised = [dvh1];

      final (opened, openedFormat) = firstOpen(items, advertised, prefer);
      final (reopened, reopenedFormat) = reload(items, openedFormat, prefer);

      expect(reopened.codecs, opened.codecs);
      expect(reopenedFormat, openedFormat);
    });

    test('for every combination of renditions and preferences', () {
      const all = [avc, hevc, av1, dvh1];
      const seeds = [dvh1, hevc, avc, ''];

      for (final a in all) {
        for (final b in all) {
          for (final advertised in seeds) {
            for (final first in VideoDecodeFormatType.values) {
              for (final second in VideoDecodeFormatType.values) {
                final items = [rendition(a), rendition(b)];
                final preferences = [first, second];
                final advertisedList = advertised.isEmpty
                    ? <String>[]
                    : <String>[advertised];

                final (opened, openedFormat) = firstOpen(
                  items,
                  advertisedList,
                  preferences,
                );
                final (reopened, reopenedFormat) = reload(
                  items,
                  openedFormat,
                  preferences,
                );

                final reason =
                    'renditions $a/$b, advertised ${advertisedList.join()}, '
                    'prefer ${first.name}/${second.name}';
                expect(reopened.codecs, opened.codecs, reason: reason);
                expect(reopenedFormat, openedFormat, reason: reason);
              }
            }
          }
        }
      }
    });
  });
}

/// One `dash.video` rendition at a fixed quality (1080P, id 80).
VideoItem rendition(String codecs) =>
    VideoItem.fromJson({'id': 80, 'codecs': codecs});

/// Mirrors the first-open path in `VideoDetailController._queryVideoUrl`: the
/// server's advertised codecs seed the format, then the shared routine picks
/// the rendition and corrects the format to what it really chose.
(VideoItem, VideoDecodeFormatType) firstOpen(
  List<VideoItem> items,
  List<String> advertised,
  List<VideoDecodeFormatType> preferences,
) {
  final seed = advertised.isEmpty
      ? VideoDecodeFormatType.AVC
      : VideoUtils.selectCodec(advertised, preferences);
  return VideoUtils.selectVideoRendition(items, seed, preferences);
}

/// Mirrors every reload path (`updatePlayer` -> `findVideoByQa(setCodecs:
/// true)`, and the CDN rotation), where the format carried in is whatever the
/// previous selection resolved to.
(VideoItem, VideoDecodeFormatType) reload(
  List<VideoItem> items,
  VideoDecodeFormatType current,
  List<VideoDecodeFormatType> preferences,
) => VideoUtils.selectVideoRendition(items, current, preferences);

const avc = 'avc1.640028';
const hevc = 'hev1.1.6.L120.90';
const av1 = 'av01.0.08M.08';
const dvh1 = 'dvh1.05.06';
