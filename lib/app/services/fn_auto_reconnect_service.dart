import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/settings_fn_state.dart';
import 'feiniu/account_store.dart';
import 'feiniu/api_client.dart';
import 'feiniu/auth_service.dart';
import 'feiniu/fn_connection_probe_service.dart';
import 'feiniu/fn_models.dart';

/// 自动重连探测服务（单例）
///
/// 只在「连接不上」时才探测，不维持后台探测：
/// 1. 网络状态变更（WiFi / 移动数据断开后重连、IP 变更）
/// 2. 连续 API 请求失败（连接超时、连接拒绝、网络错误）
/// 3. 连接断开期间的周期重试（服务器持续不可达时每隔一段时间自动再探测，
///    直到恢复）
/// 4. App 从后台回到前台（网络环境可能已变化，做一次性轻量校验，只有
///    当前连接不可达才触发完整重连）
///
/// 触发后执行全链路 FN 探测，成功后更新连接信息并停止重试。
class FnAutoReconnectService with WidgetsBindingObserver {
  FnAutoReconnectService._();

  static final FnAutoReconnectService instance = FnAutoReconnectService._();

  /// 是否已初始化
  bool _initialized = false;

  /// 网络状态流订阅
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// 连续失败计数器
  int _consecutiveFailures = 0;

  /// 连续失败阈值（达到此值触发重连）
  static const int _failureThreshold = 3;

  /// 重连防抖定时器（网络频繁变化时不重复触发）
  Timer? _debounceTimer;

  /// 重连防抖延迟
  static const Duration _debounceDelay = Duration(seconds: 3);

  /// 断开后周期重试定时器（服务器持续不可达时每隔一段时间自动再探测）
  Timer? _retryTimer;

  /// 断开重试间隔
  static const Duration _retryInterval = Duration(seconds: 5);
  static const Duration _maxRetryInterval = Duration(minutes: 1);
  static const Duration _backgroundRetryInterval = Duration(minutes: 1);
  static const Duration _backgroundMaxRetryInterval = Duration(minutes: 5);
  int _retryAttempt = 0;
  bool _appInForeground = true;

  /// 是否有被推迟的重连（触发时探测正好在进行中）。
  ///
  /// 置位后在探测结束（isProbing 变 false）时由监听器补发一次，
  /// 避免「探测进行中 → 重连被跳过」的重连请求被静默吞掉。
  bool _pendingReconnect = false;

  /// 回前台校验是否在途（防止与另一次校验重叠）
  bool _verifyInFlight = false;

  /// 初始化：监听网络变化 + App 生命周期 + 注入 Dio 拦截器
  void init() {
    if (_initialized) return;
    _initialized = true;

    if (kDebugMode) {
      debugPrint('[AutoReconnect] Initializing...');
    }

    // 0. 注册 App 生命周期监听（后台 → 前台时做一次性校验）
    WidgetsBinding.instance.addObserver(this);

    // 1. 监听网络变化
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _onConnectivityChanged,
    );

    // 2. 注入 Dio 拦截器监听 API 失败
    FeiNiuApiClient.instance.addReconnectMonitor(_onApiFailure);

    // 3. 注册 API 成功回调（重置断开状态）
    FeiNiuApiClient.instance.addRecoveryMonitor(_onApiRecovery);

    // 4. 探测结束补发被推迟的重连
    FnConnectionProbeService.instance.isProbing.addListener(
      _onProbeStateChanged,
    );

    if (kDebugMode) {
      debugPrint('[AutoReconnect] Initialized');
    }
  }

  /// 探测结束（isProbing 变 false）且存在被推迟的重连时补发一次。
  void _onProbeStateChanged() {
    if (FnConnectionProbeService.instance.isProbing.value) return;
    if (!_pendingReconnect) return;
    _pendingReconnect = false;
    _triggerReconnect(reason: '补发：上次重连被探测进行中推迟');
  }

  /// App 生命周期回调：从后台回到前台时做一次性轻量校验。
  ///
  /// 后台期间 Dart isolate 被挂起，网络变化事件可能丢失（如内网 → 公网
  /// 切换恰好发生在后台），恢复时用快探（[kFnCachedProbeConnectTimeout]，
  /// 直连 3s / 中继 10s）验证当前连接；只有不可达才触发完整重连，可达时
  /// 不打扰用户。不做周期探测。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    if (!_appInForeground) {
      if (_retryTimer?.isActive ?? false) {
        _retryTimer?.cancel();
        _retryTimer = null;
        _scheduleRetryIfDisconnected();
      }
      return;
    }
    if (!AppFnConnectionSettings.serverConnected.value) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _scheduleRetryIfDisconnected();
    }
    if (_verifyInFlight) return;
    if (FnConnectionProbeService.instance.isProbing.value) return;
    final fnId = AppFnConnectionSettings.lastFnId;
    if (fnId == null || fnId.isEmpty) return;
    final current = FeiNiuApiClient.instance.baseUrl;
    if (current.isEmpty) return;

    _verifyInFlight = true;
    unawaited(() async {
      try {
        final reachable = await FnConnectionProbeService.instance
            .isAddressReachable(
              current,
              isRelay: FeiNiuApiClient.instance.relayMode,
            );
        // 被并发占用（null）或可达 → 连接正常，不打扰用户
        if (reachable != false) return;

        if (kDebugMode) {
          debugPrint(
            '[AutoReconnect] Resume verify failed: $current, reconnecting...',
          );
        }
        AppFnConnectionSettings.serverConnected.value = false;
        _triggerReconnect(reason: '回到前台，连接不可达，重新连接');
      } finally {
        _verifyInFlight = false;
      }
    }());
  }

  /// 网络状态变化回调
  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasConnection = results.any((r) => r != ConnectivityResult.none);

    if (kDebugMode) {
      debugPrint(
        '[AutoReconnect] Connectivity changed: $results → ${hasConnection ? "connected" : "disconnected"}',
      );
    }

    if (hasConnection) {
      // 网络恢复后再等一会，让网络稳定下来
      _retryTimer?.cancel();
      _retryTimer = null;
      _retryAttempt = 0;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounceDelay, () {
        _triggerReconnect(reason: '网络已恢复');
      });
    } else {
      // 网络断开，重置连续失败计数器
      _consecutiveFailures = 0;
    }
  }

  /// 连接被标记为断开时调用（如启动预热失败），立即触发一次重连，
  /// 失败后保持周期重试直到恢复。
  void onConnectionLost({String reason = '服务器连接失败'}) {
    AppFnConnectionSettings.serverConnected.value = false;
    _triggerReconnect(reason: reason);
  }

  /// 断开期间退避重试：上一轮失败后再安排下一轮，避免慢探测与周期 tick 重叠。
  void _scheduleRetryIfDisconnected() {
    if (AppFnConnectionSettings.serverConnected.value) return;
    if (_retryTimer?.isActive ?? false) return;
    final baseInterval = _appInForeground
        ? _retryInterval
        : _backgroundRetryInterval;
    final maxInterval = _appInForeground
        ? _maxRetryInterval
        : _backgroundMaxRetryInterval;
    final exponent = _retryAttempt > 4 ? 4 : _retryAttempt;
    final candidateDelayMs = baseInterval.inMilliseconds * (1 << exponent);
    final delayMs = candidateDelayMs > maxInterval.inMilliseconds
        ? maxInterval.inMilliseconds
        : candidateDelayMs;
    _retryAttempt++;
    _retryTimer = Timer(Duration(milliseconds: delayMs), _onRetryTick);
  }

  void _onRetryTick() {
    _retryTimer = null;
    if (AppFnConnectionSettings.serverConnected.value) return;
    _triggerReconnect(reason: '连接断开自动重试');
  }

  /// API 请求成功回调：恢复连接状态
  void _onApiRecovery() {
    if (!AppFnConnectionSettings.serverConnected.value) {
      AppFnConnectionSettings.serverConnected.value = true;
      if (kDebugMode) {
        debugPrint('[AutoReconnect] API recovered, connection restored');
      }
    }
    _retryAttempt = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// API 请求失败回调
  void _onApiFailure(DioException error) {
    // 只关注网络层面的错误（超时、连接拒绝、DNS 等）
    final isNetworkError = switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      _ => false,
    };

    if (!isNetworkError) return;

    _consecutiveFailures++;

    if (kDebugMode) {
      debugPrint(
        '[AutoReconnect] API failure #$_consecutiveFailures: ${error.type}',
      );
    }

    if (_consecutiveFailures >= _failureThreshold) {
      _consecutiveFailures = 0;
      AppFnConnectionSettings.serverConnected.value = false;
      _triggerReconnect(reason: '连接连续失败 $_failureThreshold 次');
    }
  }

  /// 触发重连
  void _triggerReconnect({required String reason}) {
    // 只有已登录且有上次 FNID 时才自动重连
    if (!AuthService.instance.isLoggedIn.value) return;
    final fnId = AppFnConnectionSettings.lastFnId;
    if (fnId == null || fnId.isEmpty) return;

    // 探测进行中（如启动预热 / 用户手动全量探测 / 另一次重连）时先不打扰，
    // 置位待发标记，探测结束后由监听器补发，避免本次重连请求被静默吞掉。
    if (FnConnectionProbeService.instance.isProbing.value) {
      _pendingReconnect = true;
      if (kDebugMode) {
        debugPrint('[AutoReconnect] Probe in progress, deferring reconnect');
      }
      return;
    }

    if (kDebugMode) {
      debugPrint('[AutoReconnect] Triggering reconnect, reason: $reason');
    }

    // 异步执行，不阻塞
    _doReconnect(fnId);
  }

  Future<void> _doReconnect(String fnId) async {
    try {
      // 缓存优先：先快探上次成功连接（probeSmart 内部为
      // kFnCachedProbeConnectTimeout，直连 3s / 中继 10s），可达直接复用，
      // 避免每次断连都全量重探所有候选（尤其最慢的中继）。缓存失效自动
      // 回退完整探测。
      final cache = AppFnConnectionSettings.cachedConnection;
      final result = await FnConnectionProbeService.instance.probeSmart(
        fnId: fnId,
        cachedUrl: cache?.url,
        cachedIsRelay: cache?.isRelay ?? false,
      );

      if (kDebugMode) {
        debugPrint(
          '[AutoReconnect] Reconnect succeeded: ${result.serverUrl} (${result.probeMethod})',
        );
      }

      await _applyProbeResult(fnId, result);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AutoReconnect] Reconnect failed: $e');
      }
      _scheduleRetryIfDisconnected();
    }
  }

  /// 应用探测结果：更新连接信息、API 客户端 baseUrl / relay 模式，并恢复连接状态。
  Future<void> _applyProbeResult(
    String fnId,
    ConnectionProbeResult result,
  ) async {
    // 更新连接信息
    await AppFnConnectionSettings.saveProbeResult(
      fnId: fnId,
      url: result.serverUrl,
      method: result.probeMethod,
      isRelay: result.isRelay,
    );

    // 如果 baseUrl 变了，更新 API 客户端的 baseUrl
    final currentBase = FeiNiuApiClient.instance.baseUrl;
    if (currentBase != result.serverUrl) {
      await FeiNiuApiClient.instance.setBaseUrl(result.serverUrl);
    }

    // 如果是中继模式，确保 relayMode 开启
    if (result.isRelay) {
      FeiNiuApiClient.instance.setRelayMode(true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('feiniu_relay_mode', true);
    } else {
      FeiNiuApiClient.instance.setRelayMode(false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('feiniu_relay_mode', false);
    }

    AppFnConnectionSettings.serverConnected.value = true;
    _consecutiveFailures = 0;
    _pendingReconnect = false;
    _retryAttempt = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    // 把探测得到的连接信息回写当前账号，保持账号列表与连接一致
    await AccountStore.instance.syncActiveAccountConnection();
  }

  /// 释放资源
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FnConnectionProbeService.instance.isProbing.removeListener(
      _onProbeStateChanged,
    );
    _connectivitySub?.cancel();
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _initialized = false;
  }
}
