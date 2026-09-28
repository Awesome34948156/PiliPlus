import 'package:PiliPlus/utils/cdn_adaptive.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// Show what the last probe measured and which host adaptive selection is using.
///
/// Deliberately not a picker: choosing a host by hand is already covered by
/// `CdnSelectDialog`, both in the settings and in the player's header menu.
/// This dialog exists to answer "what did it decide, and why".
Future<void> showCdnRankDialog(BuildContext context) async {
  final samples = CdnAdaptive.lastSamples;
  final active = VideoUtils.adaptiveHost;
  final rankedAt = CdnAdaptive.rankedAt;

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: const Text('CDN 测速排名'),
      constraints: const BoxConstraints.tightFor(width: 320),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          child: samples.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text('暂无测速结果。开启后将在播放视频时自动测速。'),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(left: 24, bottom: 8),
                      child: Text(
                        '按实测速度排序',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    for (final sample in samples)
                      _RankTile(
                        name: sample.host.name,
                        desc: sample.host.desc,
                        ok: sample.ok,
                        mbps: sample.mbps,
                        isActive: sample.host == active,
                      ),
                    if (rankedAt != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 24,
                          right: 24,
                          top: 8,
                        ),
                        child: Text(
                          '测速于 ${_formatTime(rankedAt)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: samples.isEmpty
              ? null
              : () {
                  CdnAdaptive.clearRanking();
                  Navigator.of(context).pop();
                  SmartDialog.showToast('已清除，将在下次播放时重新测速');
                },
          child: const Text('清除排名'),
        ),
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _RankTile extends StatelessWidget {
  const _RankTile({
    required this.name,
    required this.desc,
    required this.ok,
    required this.mbps,
    required this.isActive,
  });

  final String name;
  final String desc;
  final bool ok;
  final double mbps;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ListTile(
      dense: true,
      leading: Icon(
        isActive ? Icons.play_circle_fill : Icons.cloud_outlined,
        color: isActive ? colorScheme.primary : null,
        size: 20,
      ),
      title: Text(name, style: textTheme.titleSmall),
      subtitle: Text(desc, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        ok ? '${mbps.toStringAsFixed(1)} Mbps' : '失败',
        style: textTheme.bodySmall?.copyWith(
          color: isActive ? colorScheme.primary : null,
        ),
      ),
    );
  }
}

/// Cache timestamps are recent enough that a plain local time is unambiguous.
String _formatTime(int epochMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}
