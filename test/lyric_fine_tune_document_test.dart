import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/lyrics/lyric_fine_tune_document.dart';

void main() {
  group('LyricFineTuneDocument', () {
    test('preserves lyric order and metadata while parsing timestamps', () {
      final document = LyricFineTuneDocument.parse('''
[ti:Example]
[00:10.50]第一行
第二行
[00:30.00]第三行
''');

      expect(document.metadata, ['[ti:Example]']);
      expect(document.lines.map((line) => line.text), ['第一行', '第二行', '第三行']);
      expect(document.lines[0].time, const Duration(milliseconds: 10500));
      expect(document.lines[1].time, isNull);
      expect(document.lines[2].time, const Duration(seconds: 30));
    });

    test('selects first untimed line between surrounding time anchors', () {
      final document = LyricFineTuneDocument.parse('''
[00:10.00]第一行
第二行
第三行
[00:30.00]第四行
''');

      expect(
        document.matchingIndex(
          const Duration(seconds: 20),
          const Duration(minutes: 1),
        ),
        1,
      );

      final updated = document.setLineTime(1, const Duration(seconds: 20));
      expect(
        updated.matchingIndex(
          const Duration(seconds: 20),
          const Duration(minutes: 1),
        ),
        2,
      );
    });

    test('uses zero and song duration as virtual boundary anchors', () {
      final document = LyricFineTuneDocument.parse('''
开场
[00:10.00]中段
结尾
''');

      expect(
        document.matchingIndex(
          const Duration(seconds: 2),
          const Duration(seconds: 40),
        ),
        0,
      );
      expect(
        document.matchingIndex(
          const Duration(seconds: 35),
          const Duration(seconds: 40),
        ),
        2,
      );
      expect(document.previousAnchorFor(0), Duration.zero);
      expect(document.previousAnchorFor(2), const Duration(seconds: 10));
    });

    test('finds the current timed line when no line needs matching', () {
      final document = LyricFineTuneDocument.parse('''
[00:05.00]第一行
[00:12.00]第二行
[00:20.00]第三行
''');

      expect(document.activeTimedIndex(const Duration(seconds: 4)), isNull);
      expect(document.activeTimedIndex(const Duration(seconds: 12)), 1);
      expect(document.activeTimedIndex(const Duration(seconds: 19)), 1);
      expect(document.activeTimedIndex(const Duration(seconds: 25)), 2);
    });

    test('converts normal and enhanced word lyrics to editable lines', () {
      final document = LyricFineTuneDocument.parse('''
[00:25.301]不[00:25.831]做[00:26.116]考[00:26.427]虑[00:31.626]
[00:40.000] <00:40.000>下<00:40.300>一<00:40.600>句<00:41.000>
''');

      expect(document.lines, hasLength(2));
      expect(document.lines[0].time, const Duration(milliseconds: 25301));
      expect(document.lines[0].text, '不做考虑');
      expect(document.lines[1].time, const Duration(seconds: 40));
      expect(document.lines[1].text, '下一句');
      expect(document.toLrc(), '[00:25.30]不做考虑\n[00:40.00]下一句');
    });

    test('clears and serializes line timestamps as standard LRC', () {
      final document = LyricFineTuneDocument.parse('''
[ar:歌手]
[00:01.23]第一行
[00:04.56]第二行
''');

      final cleared = document.clearTimes();
      expect(cleared.lines.every((line) => line.time == null), isTrue);

      final updated = cleared
          .setLineTime(0, const Duration(milliseconds: 2345))
          .setLineTime(1, const Duration(minutes: 1, milliseconds: 70));
      expect(updated.toLrc(), '[ar:歌手]\n[00:02.34]第一行\n[01:00.07]第二行');
    });
  });
}
