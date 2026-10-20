import 'dart:io';

import 'package:flutter/services.dart';

class AndroidPlatformService {
  AndroidPlatformService._();

  static final AndroidPlatformService instance = AndroidPlatformService._();

  static const MethodChannel _channel = MethodChannel(
    'com.feiniu.music/downloads',
  );

  int? _sdkInt;

  Future<int> sdkInt() async {
    if (!Platform.isAndroid) return 0;
    final cached = _sdkInt;
    if (cached != null) return cached;
    try {
      final value = await _channel
          .invokeMethod<int>('getAndroidSdkInt')
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);
      _sdkInt = value ?? 0;
    } catch (_) {
      _sdkInt = 0;
    }
    return _sdkInt!;
  }

  Future<bool> supportsNotificationCustomActions() async {
    if (!Platform.isAndroid) return true;
    final sdk = await sdkInt();
    if (sdk == 0) return false;
    // Media-style notification custom actions are supported on old Android
    // versions too. Low-version devices may show fewer actions depending on
    // the system UI/OEM skin, but the feature itself is available.
    return sdk >= 21;
  }
}
