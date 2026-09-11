import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/components/list/multi_select_bottom_bar.dart';

void main() {
  testWidgets('五个多选操作在手机窄屏下等宽显示且不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const labels = ['添加到播放队列', '添加到歌单', '批量匹配', '文件名替换歌名', '添加到收藏'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MultiSelectBottomBar(
            actions: [
              for (final label in labels)
                MultiSelectAction(
                  icon: Icons.music_note,
                  label: label,
                  onTap: _noop,
                ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    for (final label in labels) {
      expect(find.text(label), findsOneWidget);
    }

    final widths = tester
        .widgetList<Expanded>(find.byType(Expanded))
        .map((expanded) => expanded.flex)
        .toList();
    expect(widths, everyElement(1));
  });
}

void _noop() {}
