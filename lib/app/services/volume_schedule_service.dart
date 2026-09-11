import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/settings_state.dart';

/// 定时音量调度器：在设定的时间段内把音量强制到段内设定值，
/// 离开时间段后恢复手动音量（`AppPlaybackVolumeSettings.volume` 的当前值）。
///
/// 只通过 `AppPlaybackVolumeSettings.setVolume` 写音量——volume notifier 的
/// 监听（`PlayerService._handleAppVolumeChanged`）会自动把值流到播放器。
class VolumeScheduleService {
  static final VolumeScheduleService instance = VolumeScheduleService._();

  VolumeScheduleService._() {
    AppVolumeScheduleSettings.enabled.addListener(_onSettingsChanged);
    AppVolumeScheduleSettings.periods.addListener(_onSettingsChanged);
  }

  Timer? _ticker;
  VolumeSchedulePeriod? _active;
  bool _started = false;

  bool get isActive => _active != null;

  /// 幂等启动：App 启动时调用一次。加载设置、立即应用一次、调度下个边界。
  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    await AppVolumeScheduleSettings.ensureLoaded();
    await _applySchedule();
    _restartTickerIfNeeded();
  }

  /// 立即重检一次（生命周期 resume、手动音量变化、边界定时器）。
  void checkNow() {
    unawaited(_applySchedule());
  }

  /// 测试专用：同步应用一次调度，可注入时钟 [now]。
  @visibleForTesting
  Future<void> applyScheduleForTest({DateTime? now}) async {
    await _applySchedule(now: now);
  }

  /// 关闭边界定时器并释放监听（仅在测试/热重载时触发）。
  /// 同时重置生效状态，保证单例可被测试复用而不残留上个用例的时段。
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    AppVolumeScheduleSettings.enabled.removeListener(_onSettingsChanged);
    AppVolumeScheduleSettings.periods.removeListener(_onSettingsChanged);
    _active = null;
    AppVolumeScheduleSettings.isActiveNow.value = false;
  }

  /// 测试专用：重新注册设置监听（dispose 会移除它们，供测试复用单例）。
  @visibleForTesting
  void registerListenersForTest() {
    AppVolumeScheduleSettings.enabled.addListener(_onSettingsChanged);
    AppVolumeScheduleSettings.periods.addListener(_onSettingsChanged);
  }

  // ---------- 调度逻辑 ----------

  Future<void> _applySchedule({DateTime? now, bool forceApply = false}) async {
    if (!AppVolumeScheduleSettings.enabled.value) {
      if (_active != null) {
        // 开关被关闭且当前在生效时间段 → 恢复手动音量。
        _active = null;
        AppVolumeScheduleSettings.isActiveNow.value = false;
        await AppPlaybackVolumeSettings.setVolume(
          AppVolumeScheduleSettings.manualVolume.value,
        );
      }
      _restartTickerIfNeeded();
      return;
    }

    final p = AppVolumeScheduleSettings.activePeriodNow(now ?? DateTime.now());
    if (p != null) {
      if (p.id != _active?.id) {
        // 进入新时间段：只取「已持久化的手动音量」用于离开时恢复，
        // 不再现场快照当前音量——否则时段内重启/被杀会把上个时段遗留的
        // 段内强制值当成手动音量，结束时恢复回错误值。
        if (!AppVolumeScheduleSettings.hasPersistedManualVolume) {
          await AppVolumeScheduleSettings.persistManualVolume(
            AppPlaybackVolumeSettings.volume.value,
          );
        }
        _active = p;
        AppVolumeScheduleSettings.isActiveNow.value = true;
        await AppPlaybackVolumeSettings.setVolume(p.volume);
      } else if (forceApply) {
        // 设置变更（编辑时段音量/时间）触发且仍在同一时段 → 重新应用段内音量。
        // forceApply 只来自 _onSettingsChanged，绝不来自心跳 tick，
        // 因此不会在生效时段内反复覆盖用户手动调节的音量。
        await AppPlaybackVolumeSettings.setVolume(p.volume);
      }
      // 仍在同一时间段且非设置变更：不强制写回段内音量。
      // 段内音量只在「进入时段」「设置变更/开关变化」时应用一次，
      // 心跳 tick 不会持续强拉——否则用户在生效时段内手动调节音量
      // 会被 1 秒心跳立即覆盖回定时值。
    } else if (_active != null) {
      // 离开时间段 → 恢复手动音量。
      _active = null;
      AppVolumeScheduleSettings.isActiveNow.value = false;
      await AppPlaybackVolumeSettings.setVolume(
        AppVolumeScheduleSettings.manualVolume.value,
      );
    } else {
      AppVolumeScheduleSettings.isActiveNow.value = false;
      // 不在任何时间段且本会话尚未进入过时段（_active == null）：
      // 若音量仍是某时段遗留的强制值（如 App 在时段内被关、进程被杀后
      // 重新启动/回到前台，persisted 音量仍是段内值），恢复为已记录的手动音量。
      // 仅当已持久化过手动音量才恢复，避免覆盖用户首次使用前的现有音量。
      final current = AppPlaybackVolumeSettings.volume.value;
      final manual = AppVolumeScheduleSettings.manualVolume.value;
      if (AppVolumeScheduleSettings.hasPersistedManualVolume &&
          (current - manual).abs() > 0.001) {
        await AppPlaybackVolumeSettings.setVolume(manual);
      }
    }
    _restartTickerIfNeeded();
  }

  void _onSettingsChanged() {
    // 设置变更（开关/时段增删改）：立即应用一次，包括编辑当前生效时段的音量。
    // 用 forceApply 与心跳 tick（checkNow）区分开，避免心跳强拉覆盖手动音量。
    unawaited(_applySchedule(forceApply: true));
  }

  // ---------- 边界调度 ----------

  /// 只唤醒到下一个开始/结束边界；resume 时 [checkNow] 会立即纠正挂起期间
  /// 跨过的边界，因此无需全天运行固定周期心跳。
  void _restartTickerIfNeeded() {
    _ticker?.cancel();
    _ticker = null;
    final shouldRun =
        AppVolumeScheduleSettings.enabled.value &&
        AppVolumeScheduleSettings.periods.value.isNotEmpty;
    if (!shouldRun) return;

    final now = DateTime.now();
    DateTime? nextBoundary;
    for (final period in AppVolumeScheduleSettings.periods.value) {
      for (final minute in [period.startMin, period.endMin]) {
        var candidate = DateTime(
          now.year,
          now.month,
          now.day,
          minute ~/ 60,
          minute % 60,
        );
        if (!candidate.isAfter(now)) {
          candidate = candidate.add(const Duration(days: 1));
        }
        if (nextBoundary == null || candidate.isBefore(nextBoundary)) {
          nextBoundary = candidate;
        }
      }
    }
    if (nextBoundary == null) return;
    _ticker = Timer(nextBoundary.difference(now), () {
      _ticker = null;
      checkNow();
    });
  }
}
