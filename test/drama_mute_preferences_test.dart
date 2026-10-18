import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_mute_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DramaMutePreferences.instance.resetForTest();
  });

  test('defaults to unmuted before anything is stored', () async {
    await DramaMutePreferences.instance.load();
    expect(DramaMutePreferences.instance.muteWhenColdStart.value, isFalse);
  });

  test('persists the setting across a fresh load', () async {
    await DramaMutePreferences.instance.set(true);
    expect(DramaMutePreferences.instance.muteWhenColdStart.value, isTrue);

    DramaMutePreferences.instance.resetForTest();
    await DramaMutePreferences.instance.load();
    expect(DramaMutePreferences.instance.muteWhenColdStart.value, isTrue);
  });

  test('reads back a value written before this process started', () async {
    SharedPreferences.setMockInitialValues({
      'drama_mute_when_cold_start': true,
    });
    await DramaMutePreferences.instance.load();
    expect(DramaMutePreferences.instance.muteWhenColdStart.value, isTrue);
  });

  test('a wrong-typed stored value falls back to unmuted', () async {
    SharedPreferences.setMockInitialValues({
      'drama_mute_when_cold_start': 'yes',
    });
    await DramaMutePreferences.instance.load();
    expect(DramaMutePreferences.instance.muteWhenColdStart.value, isFalse);
  });

  // 竞态回归：短剧页在 initState 里 unawaited(load())，首张卡的
  // _applyPlaybackPrefs 随后又 await load() 再读 value。此前 _loaded 在
  // await 之前就置位，第二次 load() 立即返回、不等待第一次读完，于是读到
  // 尚未回填的默认值 false——真机表现为「设置打开了但进短剧不静音」。
  test('a load started while another is pending still sees the value', () async {
    SharedPreferences.setMockInitialValues({
      'drama_mute_when_cold_start': true,
    });

    // 第一次调用不 await：模拟短剧页 initState 里的 unawaited(load())。
    final first = DramaMutePreferences.instance.load();
    // 第二次调用必须等同一份读取完成，而不是立刻返回。
    await DramaMutePreferences.instance.load();
    await first;

    expect(DramaMutePreferences.instance.muteWhenColdStart.value, isTrue);
  });
}
