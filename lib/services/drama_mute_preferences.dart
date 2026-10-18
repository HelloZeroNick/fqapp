import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// 短剧「开启应用时默认静音」的持久化开关。
///
/// 官方的静音是三层结构（反编译依据见
/// .agents/notes/implemented/feature/2026-09-27-feed-mute-official-logic.md）：
/// 服务端总开关（`video_mute_config_v639.default_mute`，本地缺省 false）、
/// 本设置（官方键 `open_mute_when_cold_start`，MMKV
/// `short_video_mute_global_manager`，**默认 false**＝有声起播）、以及会话态
/// `tm3.b.needMutePlay`（点药丸/按音量键解除后会话内不再静音）。本仓库没有
/// 服务端开关与音量键监听，对齐的是后两层：默认有声，只有用户开了这个设置
/// 才在进入短剧页时静音并给出「取消静音」药丸。
class DramaMutePreferences {
  DramaMutePreferences._();

  static final DramaMutePreferences instance = DramaMutePreferences._();

  static const _key = 'drama_mute_when_cold_start';

  /// Whether the short-drama feed starts muted. Loaded from SharedPreferences
  /// by [load]; before that completes it reads the official default (unmuted).
  final ValueNotifier<bool> muteWhenColdStart = ValueNotifier<bool>(false);

  /// 共享同一次读取的 in-flight Future。
  ///
  /// 之前只有一个 `bool _loaded`，且在 `await` **之前**就置位：短剧页
  /// `initState` 里 `unawaited(load())` 发起读取后，首张卡的
  /// `_applyPlaybackPrefs` 紧接着 `await load()`，第二次调用看到 `_loaded`
  /// 已为 true 就立刻返回，于是 `muteWhenColdStart.value` 还是默认的
  /// false——设置打开了但进短剧不静音。改成缓存 Future 后，并发调用者
  /// 等的是同一份结果，不再各自判断一个还没回填的布尔。
  Future<void>? _loading;

  Future<void> load() {
    final pending = _loading;
    if (pending != null) return pending;
    final request = _read();
    _loading = request;
    return request;
  }

  Future<void> _read() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final stored = sp.getBool(_key);
      muteWhenColdStart.value = stored ?? false;
      // 真机上「开关不记忆」既可能是没写进去，也可能是读回来是别的类型，
      // 两者在这里都能区分开：日志会给出原始值（null 表示键不存在）。
      AppLog.i('drama_mute', 'loaded $_key=$stored');
    } catch (e) {
      AppLog.e('drama_mute', '读取 $_key 失败，按默认有声处理', error: e);
    }
  }

  /// 忘掉已加载状态，让下一次 [load] 重新读 SharedPreferences。
  ///
  /// 只为测试存在：读取结果被缓存，`setMockInitialValues` 换掉的初值
  /// 不会被已加载过的实例重新读取。
  @visibleForTesting
  void resetForTest() {
    _loading = null;
    muteWhenColdStart.value = false;
  }

  Future<void> set(bool value) async {
    muteWhenColdStart.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      final stored = await sp.setBool(_key, value);
      // setBool 返回 false 表示平台拒绝写入，此前被静默吞掉，真机上表现为
      // 「开关拨了、下次进来又变回去」。
      if (stored) {
        AppLog.i('drama_mute', 'saved $_key=$value');
      } else {
        AppLog.e('drama_mute', '写入 $_key=$value 被平台拒绝');
      }
    } catch (e) {
      // The in-session value still applies; only persistence failed.
      AppLog.e('drama_mute', '写入 $_key=$value 失败', error: e);
    }
  }
}
