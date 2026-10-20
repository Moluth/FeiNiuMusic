import 'dart:async';

import 'package:feiniu_music/app/startup/app_startup_bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget readyApp() {
    return const MaterialApp(home: Text('app-ready'));
  }

  testWidgets('初始化完成前先渲染 Flutter 启动页', (tester) async {
    final initialization = Completer<void>();

    await tester.pumpWidget(
      AppStartupBootstrap(
        initialize: (updateStage) {
          updateStage('正在恢复测试数据');
          return initialization.future;
        },
        readyBuilder: (_) => readyApp(),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('app-startup-loading')), findsOneWidget);
    expect(find.text('正在恢复测试数据'), findsOneWidget);
    expect(find.text('app-ready'), findsNothing);

    initialization.complete();
    await tester.pump();

    expect(find.byKey(const ValueKey('app-startup-loading')), findsNothing);
    expect(find.text('app-ready'), findsOneWidget);
  });

  testWidgets('初始化永久挂起时即使诊断回调异常也会放行', (tester) async {
    final initialization = Completer<void>();
    String? timeoutStage;

    await tester.pumpWidget(
      AppStartupBootstrap(
        timeout: const Duration(milliseconds: 100),
        initialize: (updateStage) {
          updateStage('等待原生通道');
          return initialization.future;
        },
        readyBuilder: (_) => readyApp(),
        onTimeout: (stage) {
          timeoutStage = stage;
          throw StateError('diagnostic callback failed');
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(timeoutStage, '等待原生通道');
    expect(find.text('app-ready'), findsOneWidget);
  });

  testWidgets('初始化抛异常时使用默认状态进入应用', (tester) async {
    Object? capturedError;

    await tester.pumpWidget(
      AppStartupBootstrap(
        initialize: (_) async {
          throw StateError('startup failed');
        },
        readyBuilder: (_) => readyApp(),
        onError: (error, stackTrace, stage) => capturedError = error,
      ),
    );
    await tester.pump();

    expect(capturedError, isA<StateError>());
    expect(find.text('app-ready'), findsOneWidget);
  });
}
