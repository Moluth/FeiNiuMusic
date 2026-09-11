import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router/app_router.dart';
import '../../../app/services/feiniu/fn_connection_probe_service.dart';
import '../../../app/state/settings_fn_state.dart';
import '../../../app/state/settings_theme_state.dart';
import '../../../app/theme/app_fonts.dart';

class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final Widget? titleWidget;
  final Widget? leading;
  final List<Widget>? actions;
  final bool? centerTitle;
  final bool showBackButton;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double elevation;
  final double? height;
  final PreferredSizeWidget? bottom;
  final bool? isRefreshing;

  /// 隐藏连接失败（wifi_off）入口。用于 FN Connect 设置页自身：
  /// 该页就是修复连接的地方，再显示入口会无限套娃压栈。
  final bool hideConnectionFailedAction;

  const AppTopBar({
    super.key,
    this.title,
    this.titleWidget,
    this.leading,
    this.actions,
    this.centerTitle,
    this.showBackButton = true,
    this.backgroundColor,
    this.foregroundColor,
    this.elevation = 0,
    this.height,
    this.bottom,
    this.isRefreshing,
    this.hideConnectionFailedAction = false,
  });

  @override
  Size get preferredSize => Size.fromHeight(
    (height ??
            (AppThemeSettings.visualStyle.value == AppVisualStyle.miuix
                ? 56
                : 48)) +
        (bottom?.preferredSize.height ?? 0),
  );

  @override
  Widget build(BuildContext context) {
    final miuix = AppThemeSettings.visualStyle.value == AppVisualStyle.miuix;
    final resolvedHeight = height ?? (miuix ? 56 : 48);
    final titleStyle = AppFonts.topBarTitleStyle(Theme.of(context).textTheme)
        .copyWith(
          fontSize: miuix ? 22 : null,
          fontWeight: miuix ? FontWeight.w700 : null,
          letterSpacing: miuix ? -0.2 : null,
        );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    );
    final resolvedActions = <Widget>[...(actions ?? const [])];
    if (isRefreshing == true) {
      resolvedActions.insert(
        0,
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: foregroundColor,
            ),
          ),
        ),
      );
    }
    if (!hideConnectionFailedAction) {
      resolvedActions.add(const _ConnectionFailedAction());
    }
    return AppBar(
      title:
          titleWidget ??
          (title != null ? Text(title!, style: titleStyle) : null),
      leading: leading,
      actions: resolvedActions,
      centerTitle: centerTitle ?? !miuix,
      automaticallyImplyLeading: showBackButton,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      elevation: elevation,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: resolvedHeight,
      bottom: bottom,
      systemOverlayStyle: overlayStyle,
    );
  }
}

/// 连接状态提示（AppBar 标题右侧的 actions 区域）
///
/// 三种状态：
/// - 连接正常（[AppFnConnectionSettings.serverConnected] == true）：不显示；
/// - 正在连接/重连探测中（serverConnected == false 且探测进行中）：显示 WiFi
///   图标按信号格数递进循环（一格 → 两格 → 三格 → 满格，周而复始），
///   点击仍可进连接设置页；
/// - 连接失败（serverConnected == false 且探测结束）：显示红色断开图标，
///   点击跳转连接设置页处理。不占用额外布局空间。
class _ConnectionFailedAction extends StatefulWidget {
  const _ConnectionFailedAction();

  @override
  State<_ConnectionFailedAction> createState() =>
      _ConnectionFailedActionState();
}

class _ConnectionFailedActionState extends State<_ConnectionFailedAction>
    with SingleTickerProviderStateMixin {
  /// 重连中的 WiFi 信号格数递进循环：一格 → 两格 → 三格 → 满格 → 回到一格。
  ///
  /// 在 [initState] 里急切创建（而非 `late final` 懒初始化）：连接正常时
  /// build 直接返回 SizedBox.shrink()，从不触碰该控制器；若用懒初始化，
  /// dispose() 时首次访问会触发 AnimationController(vsync: this) 在已失活的
  /// 元素上查找 TickerMode 祖先 → 「Looking up a deactivated widget's
  /// ancestor」崩溃。initState 里创建保证 vsync 查找安全。
  late final AnimationController _wifiController;

  static const List<IconData> _wifiLevelIcons = [
    Icons.wifi_1_bar_rounded,
    Icons.wifi_2_bar_rounded,
    Icons.wifi_rounded,
  ];

  @override
  void initState() {
    super.initState();
    _wifiController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    AppFnConnectionSettings.serverConnected.addListener(_syncWifiAnimation);
    FnConnectionProbeService.instance.isProbing.addListener(_syncWifiAnimation);
    _syncWifiAnimation();
  }

  void _syncWifiAnimation() {
    final shouldAnimate =
        !AppFnConnectionSettings.serverConnected.value &&
        FnConnectionProbeService.instance.isProbing.value;
    if (shouldAnimate) {
      if (!_wifiController.isAnimating) _wifiController.repeat();
    } else if (_wifiController.isAnimating) {
      _wifiController.stop();
    }
  }

  @override
  void dispose() {
    AppFnConnectionSettings.serverConnected.removeListener(_syncWifiAnimation);
    FnConnectionProbeService.instance.isProbing.removeListener(
      _syncWifiAnimation,
    );
    _wifiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isFnId = (AppFnConnectionSettings.lastFnId ?? '').isNotEmpty;
    return ValueListenableBuilder<bool>(
      valueListenable: AppFnConnectionSettings.serverConnected,
      builder: (context, connected, _) {
        if (connected) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: FnConnectionProbeService.instance.isProbing,
          builder: (context, probing, _) {
            void handleTap() {
              Navigator.pushNamed(
                context,
                isFnId ? AppRoutes.fnConnectSettings : AppRoutes.settings,
              );
            }

            final Widget icon;
            final String tooltip;
            if (probing) {
              // 正在连接/重连探测：WiFi 信号格数递进循环动画
              tooltip = '正在重连中...';
              icon = AnimatedBuilder(
                animation: _wifiController,
                builder: (context, _) {
                  final level = (_wifiController.value * _wifiLevelIcons.length)
                      .floor()
                      .clamp(0, _wifiLevelIcons.length - 1);
                  return Icon(
                    _wifiLevelIcons[level],
                    size: 18,
                    color: colorScheme.primary,
                  );
                },
              );
            } else {
              // 连接失败：红色断开
              tooltip = '服务器连接失败，点击处理';
              icon = Icon(
                Icons.wifi_off_rounded,
                size: 18,
                color: colorScheme.error,
              );
            }
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IconButton(
                tooltip: tooltip,
                onPressed: handleTap,
                icon: icon,
              ),
            );
          },
        );
      },
    );
  }
}
