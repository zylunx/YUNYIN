import 'dart:convert';

import 'models.dart';

final _lrcTime = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// 解析 LRC 歌词，可选合并翻译歌词。
///
/// 网易云、本地与 LX 源共用；缺少时间轴时按纯文本返回（[synced] = false）。
Lyrics parseLrc(String lrc, {String translation = ''}) {
  Map<int, String> parse(String text) {
    final out = <int, String>{};
    for (final raw in const LineSplitter().convert(text)) {
      final matches = _lrcTime.allMatches(raw).toList();
      if (matches.isEmpty) continue;
      final content = raw.substring(matches.last.end).trim();
      for (final m in matches) {
        final frac = m.group(3) ?? '0';
        final ms =
            int.parse(m.group(1)!) * 60000 +
            int.parse(m.group(2)!) * 1000 +
            (frac.length == 3
                ? int.parse(frac)
                : frac.length == 2
                ? int.parse(frac) * 10
                : int.parse(frac) * 100);
        out[ms] = content;
      }
    }
    return out;
  }

  final main = parse(lrc);
  if (main.isEmpty) {
    final plain = const LineSplitter().convert(lrc).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return Lyrics([for (final l in plain) LyricLine(Duration.zero, l)], synced: false);
  }
  final tr = parse(translation);
  final keys = main.keys.toList()..sort();
  return Lyrics([
    for (final k in keys)
      if (main[k]!.isNotEmpty) LyricLine(Duration(milliseconds: k), main[k]!, translation: tr[k]),
  ]);
}
