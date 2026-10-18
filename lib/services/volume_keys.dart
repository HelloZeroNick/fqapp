import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 音量键转发：把系统音量键变成阅读器的翻页事件。
///
/// 平台差异体现在这一层：
/// - Android / iOS / 桌面：`HardwareKeyboard` 直接能收到 `audioVolumeUp` /
///   `audioVolumeDown`，阅读器自己处理，本类不参与。
/// - HarmonyOS：系统把音量键当作系统功能键消费掉，Flutter 的按键通道拿不到。
///   唯一受支持的途径是 `@ohos.multimodalInput.inputConsumer` 的
///   `on('keyPressed')`——它在应用是前台焦点窗口时拦截系统默认行为（音量键
///   不再调音量）并把按键回调给应用。官方指南见
///   「优先响应系统功能键开发指导」（`keypressed-guidelines`，API 16+）。
///
/// 因为这层拦截会**夺走系统的音量调节**，所以只在阅读器真正需要时才打开：
/// 分页模式 + 用户开了「音量键翻页」+ 页面可见。其余情况一律关闭，让音量键
/// 回到系统默认行为。
///
/// 事件契约（EventChannel `fqapp/volume_keys_events`）：
/// `{'type': 'volumeUp'}` / `{'type': 'volumeDown'}`。
class VolumeKeys {
  VolumeKeys._();

  static const _channel = MethodChannel('fqapp/volume_keys');
  static const _events = EventChannel('fqapp/volume_keys_events');

  /// 只有鸿蒙需要原生转发；其余平台由 [HardwareKeyboard] 自己派发。
  static bool get isSupported => Platform.operatingSystem == 'ohos';

  static Stream<dynamic>? _stream;

  /// 音量键事件流。首次访问时订阅，之后复用同一个广播流。
  static Stream<String> events() {
    final stream = _stream ??= _events.receiveBroadcastStream();
    return stream.where((event) => event is Map && event['type'] is String).map(
      (event) => (event as Map)['type'] as String,
    );
  }

  /// 打开或关闭音量键拦截。
  ///
  /// [enabled] 为 true 时原生订阅 `inputConsumer.on('keyPressed')`，音量键
  /// 不再调系统音量而是回调给阅读器；为 false 时立即取消订阅恢复系统行为。
  /// 非鸿蒙平台直接返回，调用方无需判断平台。
  static Future<void> setEnabled(bool enabled) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // 老版本宿主没有这个 channel：静默降级，音量键维持系统行为。
    } on PlatformException catch (error) {
      // 订阅失败（例如设备不支持）不应影响阅读，只记一条日志。
      debugPrint('volume_keys: setEnabled($enabled) failed: ${error.message}');
    }
  }
}
