import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart' as dio;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

import '../db/db_constants.dart';
import '../db/db_helper.dart';
import '../stats_service.dart';
import '../feiniu/account_entry.dart';
import '../feiniu/account_store.dart';

/// 备份包含的数据分块。持久化，用户配置一次即可。
///
/// - [accounts]：已保存的飞牛账号（含 token / 密码 / FNID，请妥善保管备份文件）
/// - [stats]：听歌统计（song_stats/listening_days/album_stats/playlist_stats
///   聚合 + report_events 原始事件，备份/还原可完整还原听歌报告）
/// - [settings]：应用偏好（SharedPreferences 通用键）
class BackupSections {
  final bool accounts;
  final bool stats;
  final bool settings;

  const BackupSections({
    this.accounts = true,
    this.stats = true,
    this.settings = true,
  });

  BackupSections copyWith({
    bool? accounts,
    bool? stats,
    bool? settings,
  }) => BackupSections(
    accounts: accounts ?? this.accounts,
    stats: stats ?? this.stats,
    settings: settings ?? this.settings,
  );

  bool get any => accounts || stats || settings;
}

class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const int formatVersion = 1;
  static const String webDavFolder = 'FeiNiuMusicBackup';

  /// 备份目录默认基础路径：用户选择/填写的目录之后会自动拼接 [webDavFolder]。
  static const String defaultBasePath = '/';

  /// 默认保留的备份份数（每设备）。可用 [setKeepCount] 配置。
  static const int defaultKeepCount = 10;
  static const List<int> keepCountOptions = [5, 10, 20, 30];

  static const String _prefsSectionsKey = 'backup_sections_v1';
  static const String _prefsDeviceId = 'backup_device_id';
  static const String _prefsTargetsKey = 'backup_targets_v1';
  static const String _prefsAutoEnabled = 'backup_auto_enabled';
  static const String _prefsAutoKeepCount = 'backup_auto_keep_count';
  static const String _prefsAutoLastMs = 'backup_auto_last_ms';

  // Pref keys that must NOT be exported as generic "app settings".
  static const Set<String> _settingsDenyList = {
    'feiniu_accounts_v1',
    'feiniu_current_account_id',
    // 运行时会话/激活槽位，随账号分块走：导出见 _exportAccounts/
    // _exportCurrentAccountId，还原经 AccountStore.activateForRestore 回填
    'feiniu_music_token',
    'feiniu_server_url',
    'feiniu_relay_mode',
    'feiniu_username',
    'feiniu_password',
    'fn_access_code',
    'fn_last_fnid',
    'debug_log_entries',
    _prefsSectionsKey,
    _prefsDeviceId,
    _prefsTargetsKey,
    _prefsAutoEnabled,
    _prefsAutoKeepCount,
    _prefsAutoLastMs,
  };

  final StatsService _stats = StatsService.instance;

  // ---- section preference ----
  Future<BackupSections> loadSections() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsSectionsKey);
    if (raw == null) return const BackupSections();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return BackupSections(
        accounts: m['accounts'] as bool? ?? true,
        stats: m['stats'] as bool? ?? true,
        settings: m['settings'] as bool? ?? true,
      );
    } catch (_) {
      return const BackupSections();
    }
  }

  Future<void> saveSections(BackupSections s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsSectionsKey,
      jsonEncode({
        'accounts': s.accounts,
        'stats': s.stats,
        'settings': s.settings,
      }),
    );
  }

  // ---- build / parse ----
  Future<String> buildBackupJson(BackupSections sections) async {
    String appVersion = '';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}

    final data = <String, dynamic>{
      'format': formatVersion,
      'app': 'feiniu_music',
      'dbVersion': DbConstants.dbVersion,
      'appVersion': appVersion,
      'exportedAtMs': DateTime.now().millisecondsSinceEpoch,
      'sections': {
        'accounts': sections.accounts,
        'stats': sections.stats,
        'settings': sections.settings,
      },
    };

    if (sections.accounts) {
      data['accounts'] = await _exportAccounts();
      data['currentAccountId'] = await _exportCurrentAccountId();
    }
    if (sections.stats) {
      data['stats'] = await _exportStats();
    }
    if (sections.settings) {
      data['settings'] = await _exportSettings();
    }

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Imports a backup (smart merge). Returns a short human-readable summary.
  /// [restrict] limits which sections are applied even if present in the file.
  Future<String> restoreFromJson(
    String jsonStr, {
    BackupSections? restrict,
  }) async {
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('备份文件格式无效');
    }
    if (data['format'] == null || data['app'] != 'feiniu_music') {
      throw const FormatException('不是有效的欣悦音乐备份文件');
    }

    final applied = <String>[];

    if (data['accounts'] is List && (restrict?.accounts ?? true)) {
      final n = await _importAccounts(
        (data['accounts'] as List),
        data['currentAccountId']?.toString(),
      );
      applied.add('账号 $n 个');
    }
    if (data['stats'] is Map && (restrict?.stats ?? true)) {
      await _importStats((data['stats'] as Map).cast<String, dynamic>());
      applied.add('听歌统计');
    }
    if (data['settings'] is Map && (restrict?.settings ?? true)) {
      await _importSettings((data['settings'] as Map).cast<String, dynamic>());
      applied.add('应用设置');
    }

    return applied.isEmpty ? '没有可导入的数据' : '已导入：${applied.join('、')}';
  }

  // ---- accounts ----
  Future<List<Map<String, dynamic>>> _exportAccounts() async {
    final store = AccountStore.instance;
    if (!store.isInitialized) await store.init();
    return store.accounts.value.map((e) => e.toJson()).toList();
  }

  /// 导出「当前激活账号」id，还原时连同登录态一并恢复。
  Future<String?> _exportCurrentAccountId() async {
    final store = AccountStore.instance;
    if (!store.isInitialized) await store.init();
    return store.currentAccountId.value;
  }

  Future<int> _importAccounts(List raw, String? currentAccountId) async {
    final store = AccountStore.instance;
    if (!store.isInitialized) await store.init();

    var count = 0;
    // 备份内 id → 合并后的条目：同身份账号已存在时 addOrUpdate 会保留本地
    // id，需用备份 id 兜底找回「当时的当前账号」。
    final byBackupId = <String, AccountEntry>{};
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        final entry = AccountEntry.fromJson(item.cast<String, dynamic>());
        if (entry.id.isEmpty) continue;
        final canonical = await store.addOrUpdate(entry);
        byBackupId[entry.id] = canonical;
        count++;
      } catch (_) {}
    }
    // 还原「当前激活账号」：激活会话槽位（token/服务器/中继/安全码/FNID）
    // 并标记为当前，使备份里的登录态还原后保持，无需手动重新点选。
    if (count > 0 && currentAccountId != null && currentAccountId.isNotEmpty) {
      AccountEntry? target = store.byId(currentAccountId);
      target ??= byBackupId[currentAccountId];
      if (target != null) {
        await store.activateForRestore(target);
      }
    }
    return count;
  }

  // ---- stats ----
  Future<Map<String, dynamic>> _exportStats() async {
    final agg = await _stats.exportAll();
    // 原始报告事件：完整导出一份，保证还原后年度报告可重建。
    final db = await DbHelper.instance.database;
    final events = await db.query(DbConstants.tableReportEvents);
    return {
      ...agg,
      'reportEvents': events.map((r) => Map<String, dynamic>.from(r)).toList(),
    };
  }

  Future<void> _importStats(Map<String, dynamic> data) async {
    // 1) 聚合统计：智能合并（累加计数 / 取 max 时间）。
    await _stats.importMerge(data);

    // 2) report_events：按 (songId, sessionStartMs) 去重合并，避免还原后重复。
    final events = (data['reportEvents'] as List?) ?? const [];
    if (events.isEmpty) return;
    final db = await DbHelper.instance.database;
    await db.transaction((txn) async {
      for (final raw in events) {
        if (raw is! Map) continue;
        final row = raw.cast<String, dynamic>();
        final songId = row['songId']?.toString() ?? '';
        final startMs = row['sessionStartMs'];
        if (songId.isEmpty || startMs == null) continue;
        final existing = await txn.query(
          DbConstants.tableReportEvents,
          where: 'songId = ? AND sessionStartMs = ?',
          whereArgs: [songId, startMs],
          limit: 1,
        );
        if (existing.isNotEmpty) continue;
        await txn.insert(DbConstants.tableReportEvents, row);
      }
    });
  }

  // ---- settings (generic prefs) ----
  Future<Map<String, dynamic>> _exportSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (_settingsDenyList.contains(key)) continue;
      final value = prefs.get(key);
      if (value is bool) {
        out[key] = {'t': 'b', 'v': value};
      } else if (value is int) {
        out[key] = {'t': 'i', 'v': value};
      } else if (value is double) {
        out[key] = {'t': 'd', 'v': value};
      } else if (value is String) {
        out[key] = {'t': 's', 'v': value};
      } else if (value is List<String>) {
        out[key] = {'t': 'l', 'v': value};
      }
    }
    return out;
  }

  Future<void> _importSettings(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in data.entries) {
      if (_settingsDenyList.contains(entry.key)) continue;
      final v = entry.value;
      if (v is! Map) continue;
      final type = v['t'];
      final value = v['v'];
      try {
        switch (type) {
          case 'b':
            await prefs.setBool(entry.key, value as bool);
            break;
          case 'i':
            await prefs.setInt(entry.key, (value as num).toInt());
            break;
          case 'd':
            await prefs.setDouble(entry.key, (value as num).toDouble());
            break;
          case 's':
            await prefs.setString(entry.key, value as String);
            break;
          case 'l':
            await prefs.setStringList(
              entry.key,
              (value as List).map((e) => e.toString()).toList(),
            );
            break;
        }
      } catch (_) {}
    }
  }

  // ---- local file ----
  /// 构建备份 JSON 并让用户选择保存位置（系统「另存为」对话框）。
  ///
  /// 返回保存后的文件路径；用户取消时返回 null。
  Future<String?> exportToFile(BackupSections sections) async {
    final jsonStr = await buildBackupJson(sections);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'feiniu-backup-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
    // 让用户选保存位置（Android 走系统「另存为」对话框，写入用户可访问的目录）
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出备份',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: Uint8List.fromList(utf8.encode(jsonStr)),
    );
    if (path == null) return null; // 用户取消
    return path;
  }

  /// Opens a file picker; returns the file contents or null if cancelled.
  Future<String?> pickBackupFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.firstOrNull?.path;
    if (path == null) return null;
    return File(path).readAsString();
  }

  // ---- WebDAV ----
  webdav.Client _client(BackupTarget target) {
    final client = webdav.newClient(
      target.endpoint.trim(),
      user: target.username,
      password: target.password,
      debug: kDebugMode,
    );
    client.setHeaders({
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept': '*/*',
    });
    client.setConnectTimeout(15000);
    client.setSendTimeout(60000);
    client.setReceiveTimeout(60000);
    return client;
  }

  /// 归一化路径：空 → '/'；补前导斜杠；去尾部斜杠。
  String _normalizeDir(String path) {
    var base = path.trim();
    if (base.isEmpty) return '/';
    base = base.replaceAll('\\', '/');
    if (!base.startsWith('/')) base = '/$base';
    if (base.length > 1 && base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base.isEmpty ? '/' : base;
  }

  /// 实际备份目录 = 用户选择/填写的基础目录 + `/FeiNiuMusicBackup`。
  ///
  /// 用户填 `/NAS/music`，备份文件统一落到 `/NAS/music/FeiNiuMusicBackup`，
  /// 不会把备份文件散落在所选目录里。
  String _backupDir(String basePath) {
    final base = _normalizeDir(basePath);
    if (base == '/') return '/$webDavFolder';
    return '$base/$webDavFolder';
  }

  /// Stable per-install id so backups from different devices are distinguishable.
  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_prefsDeviceId);
    if (id == null || id.isEmpty) {
      final rand = Random().nextInt(0x7fffffff).toRadixString(36);
      id = (DateTime.now().microsecondsSinceEpoch.toRadixString(36) + rand)
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (id.length > 8) id = id.substring(id.length - 8);
      await prefs.setString(_prefsDeviceId, id);
    }
    return id;
  }

  String _tsNow() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  DateTime? _parseTs(String ts) {
    if (ts.length != 14) return null;
    try {
      return DateTime(
        int.parse(ts.substring(0, 4)),
        int.parse(ts.substring(4, 6)),
        int.parse(ts.substring(6, 8)),
        int.parse(ts.substring(8, 10)),
        int.parse(ts.substring(10, 12)),
        int.parse(ts.substring(12, 14)),
      );
    } catch (_) {
      return null;
    }
  }

  /// Uploads a timestamped, per-device backup to a single target and prunes old
  /// ones for this device. Returns the remote path written. Throws
  /// [BackupException] with the real HTTP status + path on failure.
  Future<String> uploadToTarget(
    BackupTarget target,
    BackupSections sections,
  ) async {
    final jsonStr = await buildBackupJson(sections);
    final client = _client(target);
    final dir = _backupDir(target.path);
    try {
      await client.mkdirAll(dir);
    } catch (e) {
      if (kDebugMode) debugPrint('BackupService mkdirAll($dir) failed: $e');
    }
    final dev = await deviceId();
    final path = '$dir/feiniu_backup__${dev}__${_tsNow()}.json';
    try {
      await client.write(path, Uint8List.fromList(utf8.encode(jsonStr)));
    } on dio.DioException catch (e) {
      final code = e.response?.statusCode;
      throw BackupException(
        code != null ? '上传失败：HTTP $code $dir' : '上传失败：$dir 不可写或无法连接',
      );
    } catch (e) {
      throw BackupException('上传失败：$e');
    }
    await _pruneWebDav(
      client,
      dir,
      dev,
      keep: await loadKeepCount(),
    );
    return path;
  }

  /// One-click upload to every configured target. Never throws; collects a
  /// per-target success/failure result for the caller to summarize.
  Future<List<BackupUploadResult>> uploadToAllTargets(
    List<BackupTarget> targets,
    BackupSections sections,
  ) async {
    final results = <BackupUploadResult>[];
    for (final t in targets) {
      try {
        await uploadToTarget(t, sections);
        results.add(
          BackupUploadResult(target: t, ok: true),
        );
      } catch (e) {
        final msg = e is BackupException ? e.message : e.toString();
        results.add(
          BackupUploadResult(target: t, ok: false, message: msg),
        );
      }
    }
    return results;
  }

  Future<List<WebDavBackupEntry>> listWebDavBackups(BackupTarget target) async {
    final client = _client(target);
    final dir = _backupDir(target.path);
    List<webdav.File> files;
    try {
      files = await client.readDir(dir);
    } catch (_) {
      return [];
    }
    final me = await deviceId();
    final list = <WebDavBackupEntry>[];
    for (final f in files) {
      if (f.isDir ?? false) continue;
      final name = f.name ?? '';
      if (!name.startsWith('feiniu_backup') || !name.endsWith('.json')) {
        continue;
      }
      String? dev;
      DateTime? ts;
      final core = name.substring(0, name.length - 5);
      final parts = core.split('__');
      if (parts.length >= 3) {
        dev = parts[1];
        ts = _parseTs(parts[2]);
      }
      list.add(
        WebDavBackupEntry(
          name: name,
          path: f.path ?? '$dir/$name',
          sizeBytes: f.size ?? 0,
          modified: f.mTime ?? ts,
          deviceId: dev,
          isCurrentDevice: dev != null && dev == me,
        ),
      );
    }
    list.sort((a, b) {
      final am = a.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bm = b.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bm.compareTo(am);
    });
    return list;
  }

  Future<String> downloadFromWebDavPath(
    BackupTarget target,
    String path,
  ) async {
    final client = _client(target);
    final bytes = await client.read(path);
    return utf8.decode(bytes);
  }

  /// 列出 [path] 下的子文件夹（供文件夹选择器浏览）。失败返回空列表。
  Future<List<WebDavFolder>> listDirectories(
    BackupTarget target,
    String path,
  ) async {
    final client = _client(target);
    final dir = _normalizeDir(path);
    List<webdav.File> files;
    try {
      files = await client.readDir(dir);
    } catch (_) {
      return const [];
    }
    final folders = <WebDavFolder>[];
    for (final f in files) {
      if (!(f.isDir ?? false)) continue;
      final name = f.name ?? '';
      final rawPath = f.path ?? '$dir/$name';
      final normalized = _normalizeDir(rawPath);
      if (normalized.isEmpty) continue;
      folders.add(WebDavFolder(name: name, path: normalized));
    }
    folders.sort((a, b) => a.name.compareTo(b.name));
    return folders;
  }

  Future<void> _pruneWebDav(
    webdav.Client client,
    String dir,
    String deviceId, {
    required int keep,
  }) async {
    try {
      final files = await client.readDir(dir);
      final mine =
          files.where((f) {
            final n = f.name ?? '';
            return !(f.isDir ?? false) &&
                n.startsWith('feiniu_backup__${deviceId}__') &&
                n.endsWith('.json');
          }).toList()..sort((a, b) {
            final am = a.mTime ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bm = b.mTime ?? DateTime.fromMillisecondsSinceEpoch(0);
            return bm.compareTo(am);
          });
      for (var i = keep; i < mine.length; i++) {
        final path = mine[i].path;
        if (path != null) {
          try {
            await client.remove(path);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ---- backup targets ----
  Future<List<BackupTarget>> loadTargets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsTargetsKey);
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map((e) => BackupTarget.fromJson(e.cast<String, dynamic>()))
              .where((t) => t.endpoint.trim().isNotEmpty)
              .toList();
        }
      } catch (_) {}
      return const [];
    }
    return const [];
  }

  Future<void> saveTargets(List<BackupTarget> targets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsTargetsKey,
      jsonEncode(targets.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<BackupTarget>> addTarget(BackupTarget target) async {
    final list = await loadTargets();
    final next = [
      ...list.where(
        (t) => !(t.endpoint.trim() == target.endpoint.trim() &&
            _normalizeDir(t.path) == _normalizeDir(target.path)),
      ),
      target.copyWith(path: _normalizeDir(target.path)),
    ];
    await saveTargets(next);
    return next;
  }

  Future<List<BackupTarget>> updateTargetAt(
    int index,
    BackupTarget target,
  ) async {
    final list = await loadTargets();
    if (index < 0 || index >= list.length) return list;
    final next = [...list];
    next[index] = target.copyWith(path: _normalizeDir(target.path));
    await saveTargets(next);
    return next;
  }

  Future<List<BackupTarget>> removeTargetAt(int index) async {
    final list = await loadTargets();
    if (index < 0 || index >= list.length) return list;
    final next = [...list]..removeAt(index);
    await saveTargets(next);
    return next;
  }

  // ---- auto backup config ----
  Future<bool> loadAutoEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsAutoEnabled) ?? false;
  }

  Future<void> setAutoEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAutoEnabled, v);
  }

  Future<int> loadKeepCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefsAutoKeepCount) ?? defaultKeepCount;
  }

  Future<void> setKeepCount(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsAutoKeepCount, v);
  }

  static bool _hasRunAutoBackupThisSession = false;

  /// 启动时自动备份：每天首次打开 App 时，向所有已配置目标上传一次备份。
  ///
  /// 用「自然日」判断（记录上次备份的日期字符串），保证一天最多一次；
  /// 上传前检查开关与已配置目标；失败静默（不打扰启动），但只有至少一个
  /// 目标成功才推进「上次备份日期」。
  Future<void> maybeAutoBackupOnLaunch() async {
    if (_hasRunAutoBackupThisSession) return;
    _hasRunAutoBackupThisSession = true;

    final enabled = await loadAutoEnabled();
    if (!enabled) return;
    final sections = await loadSections();
    if (!sections.any) return;
    final targets = await loadTargets();
    if (targets.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now();
    final todayKey =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    if (prefs.getString(_prefsAutoLastMs) == todayKey) return;

    final results = await uploadToAllTargets(targets, sections);
    if (results.any((r) => r.ok)) {
      await prefs.setString(_prefsAutoLastMs, todayKey);
    }
  }
}

/// 备份目标：一个 WebDAV 服务器的端点 + 账号 + 服务器上的目录。
class BackupTarget {
  final String id;
  final String name;
  final String endpoint;
  final String username;
  final String password;
  final String path;

  const BackupTarget({
    required this.id,
    this.name = '',
    required this.endpoint,
    this.username = '',
    this.password = '',
    this.path = BackupService.defaultBasePath,
  });

  BackupTarget copyWith({
    String? id,
    String? name,
    String? endpoint,
    String? username,
    String? password,
    String? path,
  }) => BackupTarget(
    id: id ?? this.id,
    name: name ?? this.name,
    endpoint: endpoint ?? this.endpoint,
    username: username ?? this.username,
    password: password ?? this.password,
    path: path ?? this.path,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'endpoint': endpoint,
    'username': username,
    'password': password,
    'path': path,
  };

  factory BackupTarget.fromJson(Map<String, dynamic> json) => BackupTarget(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    endpoint: (json['endpoint'] ?? '').toString(),
    username: (json['username'] ?? '').toString(),
    password: (json['password'] ?? '').toString(),
    path: (json['path'] ?? BackupService.defaultBasePath).toString(),
  );
}

class BackupUploadResult {
  final BackupTarget target;
  final bool ok;
  final String? message;

  const BackupUploadResult({
    required this.target,
    required this.ok,
    this.message,
  });
}

/// Carries a user-facing message (incl. real HTTP status) for backup failures.
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);

  @override
  String toString() => message;
}

class WebDavBackupEntry {
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime? modified;
  final String? deviceId;
  final bool isCurrentDevice;

  const WebDavBackupEntry({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
    required this.deviceId,
    required this.isCurrentDevice,
  });
}

/// WebDAV 服务器上的一个文件夹（供备份目录选择器浏览）。
class WebDavFolder {
  final String name;
  final String path;

  const WebDavFolder({required this.name, required this.path});
}
