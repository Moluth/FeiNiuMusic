import 'dart:async';

import 'package:flutter/material.dart';

typedef AppStartupInitializer =
    Future<void> Function(ValueChanged<String> updateStage);
typedef AppStartupErrorCallback =
    void Function(Object error, StackTrace stackTrace, String stage);

/// Draws a Flutter frame before running startup work that may call plugins.
///
/// Android keeps its native splash visible until Flutter submits the first
/// frame. Running plugin and disk initialization inside this gate prevents a
/// stalled platform call from leaving the native splash on screen forever.
class AppStartupBootstrap extends StatefulWidget {
  const AppStartupBootstrap({
    super.key,
    required this.initialize,
    required this.readyBuilder,
    this.timeout = const Duration(seconds: 10),
    this.initialStage = '正在读取本地设置',
    this.onTimeout,
    this.onError,
  });

  final AppStartupInitializer initialize;
  final WidgetBuilder readyBuilder;
  final Duration timeout;
  final String initialStage;
  final ValueChanged<String>? onTimeout;
  final AppStartupErrorCallback? onError;

  @override
  State<AppStartupBootstrap> createState() => _AppStartupBootstrapState();
}

class _AppStartupBootstrapState extends State<AppStartupBootstrap> {
  Timer? _watchdog;
  late String _stage;
  bool _started = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _stage = widget.initialStage;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  void _start() {
    if (!mounted || _started) return;
    _started = true;
    _watchdog = Timer(widget.timeout, _handleTimeout);

    Future<void> initialization;
    try {
      initialization = widget.initialize(_updateStage);
    } catch (error, stackTrace) {
      _handleError(error, stackTrace);
      return;
    }
    unawaited(
      initialization.then<void>(
        (_) => _showApp(),
        onError: (Object error, StackTrace stackTrace) {
          _handleError(error, stackTrace);
        },
      ),
    );
  }

  void _updateStage(String stage) {
    if (!mounted || _ready || stage == _stage) return;
    setState(() => _stage = stage);
  }

  void _handleTimeout() {
    if (!mounted || _ready) return;
    try {
      widget.onTimeout?.call(_stage);
    } catch (error, stackTrace) {
      debugPrint('[Startup] timeout callback failed: $error\n$stackTrace');
    } finally {
      _showApp();
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    if (!mounted || _ready) return;
    try {
      widget.onError?.call(error, stackTrace, _stage);
    } catch (callbackError, callbackStackTrace) {
      debugPrint(
        '[Startup] error callback failed: $callbackError\n'
        '$callbackStackTrace',
      );
    } finally {
      _showApp();
    }
  }

  void _showApp() {
    if (!mounted || _ready) return;
    _watchdog?.cancel();
    setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.readyBuilder(context);
    return _StartupLoadingScreen(stage: _stage);
  }
}

class _StartupLoadingScreen extends StatelessWidget {
  const _StartupLoadingScreen({required this.stage});

  final String stage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: Scaffold(
        key: const ValueKey('app-startup-loading'),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.asset(
                      'assets/icon/app_icon.png',
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return const SizedBox(
                          width: 72,
                          height: 72,
                          child: Icon(Icons.music_note_rounded, size: 40),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '欣悦音乐',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    stage,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
