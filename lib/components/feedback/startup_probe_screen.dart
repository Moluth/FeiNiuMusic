import 'package:flutter/material.dart';

import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/fn_connection_probe_service.dart';
import '../../app/state/settings_fn_state.dart';

/// 启动探测画面
///
/// APP 启动时优先验证缓存连接，同时展示全屏探测动画。
/// 探测完成后通过 [onProbeComplete] 回调通知父组件，
/// 父组件可以在回调中切换显示主页面。
class StartupProbeScreen extends StatefulWidget {
  /// 探测完成后回调
  final VoidCallback onProbeComplete;

  const StartupProbeScreen({super.key, required this.onProbeComplete});

  @override
  State<StartupProbeScreen> createState() => _StartupProbeScreenState();
}

class _StartupProbeScreenState extends State<StartupProbeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _scanController;
  late final Animation<double> _pulseAnim;

  String _statusText = '正在探测连接...';
  String _detailText = '';
  bool _done = false;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _pulseAnim = Tween<double>(begin: 0.65, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOutSine),
    );

    _startProbe();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scanController.dispose();
    super.dispose();
  }

  Future<void> _startProbe() async {
    final fnId = AppFnConnectionSettings.lastFnId;
    if (fnId == null || fnId.isEmpty) {
      setState(() {
        _done = true;
      });
      return;
    }

    final cache = AppFnConnectionSettings.cachedConnection;

    setState(() {
      _detailText = cache != null ? '优先使用缓存节点' : '正在尝试多种连接方式';
    });

    // 给动画一点时间先渲染
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    try {
      final result = await FnConnectionProbeService.instance.probeSmart(
        cachedUrl: cache?.url,
        cachedIsRelay: cache?.isRelay ?? false,
        fnId: fnId,
      );

      setState(() => _statusText = '连接成功');

      await AppFnConnectionSettings.saveProbeResult(
        fnId: fnId,
        url: result.serverUrl,
        method: result.probeMethod,
        isRelay: result.isRelay,
      );

      // 更新 API 客户端
      final currentBase = FeiNiuApiClient.instance.baseUrl;
      if (currentBase != result.serverUrl) {
        await FeiNiuApiClient.instance.setBaseUrl(result.serverUrl);
      }
      FeiNiuApiClient.instance.setRelayMode(result.isRelay);
    } catch (_) {
      if (!mounted) return;
      setState(() => _detailText = '探测暂不可用，进入主页面后自动重试');
    }

    if (!mounted) return;
    setState(() => _done = true);

    // 短暂停留让用户看到结果
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    widget.onProbeComplete();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: Listenable.merge([_pulseController, _scanController]),
      builder: (context, _) {
        return Scaffold(
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        theme.colorScheme.surface,
                        theme.colorScheme.surfaceContainerHigh,
                      ]
                    : [
                        theme.colorScheme.surface,
                        theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.25,
                        ),
                      ],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Logo
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset(
                        'assets/icon/app_icon.png',
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '欣悦音乐',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 48),

                    // 探测动画
                    SizedBox(
                      width: 80,
                      height: 80,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // 外环脉冲
                          Transform.scale(
                            scale: _pulseAnim.value,
                            child: Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.15,
                                  ),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                          // 第二环
                          Transform.scale(
                            scale: 0.8 + 0.2 * _pulseAnim.value,
                            child: Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.08,
                                  ),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                          // 旋转扫描弧
                          Transform.rotate(
                            angle: _scanController.value * 3.14159 * 2,
                            child: SizedBox(
                              width: 80,
                              height: 80,
                              child: CustomPaint(
                                painter: _StartupArcPainter(
                                  color: theme.colorScheme.primary,
                                  thickness: 2.5,
                                  arcLength: 0.28,
                                ),
                              ),
                            ),
                          ),
                          // 中心旋转
                          SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),

                    // 状态文字
                    Text(
                      _statusText,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _detailText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),

                    if (_done) ...[
                      const SizedBox(height: 40),
                      SizedBox(
                        width: 120,
                        height: 36,
                        child: FilledButton(
                          onPressed: widget.onProbeComplete,
                          child: const Text('继续'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 圆弧画笔——用于启动画面旋转弧线
class _StartupArcPainter extends CustomPainter {
  final Color color;
  final double thickness;
  final double arcLength;

  const _StartupArcPainter({
    required this.color,
    required this.thickness,
    required this.arcLength,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromLTWH(
      thickness / 2,
      thickness / 2,
      size.width - thickness,
      size.height - thickness,
    );
    canvas.drawArc(rect, -3.14159 / 2, arcLength * 3.14159 * 2, false, paint);
  }

  @override
  bool shouldRepaint(covariant _StartupArcPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.thickness != thickness ||
      oldDelegate.arcLength != arcLength;
}
