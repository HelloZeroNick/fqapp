/*
 * fqapp TXT export plugin (OpenHarmony).
 *
 * Mirrors android/app/src/main/kotlin/com/fqapp/fqapp/DownloadsPlugin.kt
 * on MethodChannel "fqapp/downloads": Dart side (lib/services/book_txt_export.dart)
 * calls saveText{fileName, text} expecting {path, public}.
 *
 * Android writes into the shared MediaStore.Downloads collection on API 29+ and
 * falls back to the app's own external directory below that (reporting
 * public: false). HarmonyOS has no equivalent writable "Downloads" collection
 * exposed to apps without extra permission, so the OHOS port uses the system
 * DocumentViewPicker save dialog instead: the user picks the target directory and
 * the file lands wherever the file manager can see it. That is why this port
 * always reports public: true — every saved file is user-visible. Only the
 * document the user chose is written; no broad storage permission is requested.
 */

import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const TAG: string = 'TxtExportPlugin';
const CHANNEL_NAME: string = 'fqapp/downloads';
const TXT_SAVE_SUFFIXES: Array<string> = ['.txt'];
// The book is assembled in memory by the Dart side; guard the write the same way
// the backup plugin guards its payload.
const MAX_BYTES: number = 64 * 1024 * 1024;

// The Dart caller already sanitises the name (see exportFileName), but the
// channel is a public surface, so re-check it here like the backup plugin does.
const SAFE_NAME = /^[a-zA-Z0-9_.\u4e00-\u9fa5 ()-]{1,120}\.txt$/;

// The value handed back to Dart; an explicit interface keeps ArkTS from
// rejecting the object literal.
interface ExportResult {
  path: string;
  public: boolean;
}

export default class TxtExportPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;

  getUniqueClassName(): string {
    return 'TxtExportPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    Log.i(TAG, `attached to engine on channel ${CHANNEL_NAME}`);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.context = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context as common.UIAbilityContext;
  }

  onDetachedFromAbility(): void {
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'saveText') {
      result.notImplemented();
      return;
    }
    const context = this.context;
    if (context == null) {
      result.error('DOWNLOADS_NO_ACTIVITY', '应用窗口不可用', null);
      return;
    }
    this.handleSaveText(call, context, result);
  }

  private handleSaveText(call: MethodCall, context: common.UIAbilityContext, result: MethodResult): void {
    const text = call.argument('text') as string | null;
    if (text == null || text.length === 0) {
      result.error('DOWNLOADS_EMPTY', '导出内容为空', null);
      return;
    }
    const bytes = new util.TextEncoder('utf-8').encodeInto(text);
    if (bytes.length > MAX_BYTES) {
      result.error('DOWNLOADS_TOO_LARGE', '导出内容过大，请重试', null);
      return;
    }
    const requested = call.argument('fileName') as string | null;
    const name = (requested != null && SAFE_NAME.test(requested)) ? requested : 'fqapp-book.txt';

    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [name];
    saveOptions.fileSuffixChoices = TXT_SAVE_SUFFIXES;
    const documentPicker = new picker.DocumentViewPicker(context);
    documentPicker.save(saveOptions).then((uris: Array<string>): void => {
      if (uris.length === 0) {
        // User cancelled: report failure rather than a path nothing was written to.
        result.error('DOWNLOADS_CANCELED', '已取消导出', null);
        return;
      }
      this.writeText(uris[0], bytes, result);
    }).catch((e: ESObject): void => {
      Log.e(TAG, `save picker failed: ${e}`);
      result.error('DOWNLOADS_PICKER_UNAVAILABLE', '无法打开系统文件选择器', null);
    });
  }

  private writeText(uri: string, bytes: Uint8Array, result: MethodResult): void {
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer as ArrayBuffer, { offset: 0, length: bytes.length });
        fs.fsyncSync(file.fd);
      } finally {
        fs.closeSync(file);
      }
      const saved: ExportResult = { path: uri, public: true };
      result.success(saved);
    } catch (e) {
      Log.e(TAG, `write txt failed: ${e}`);
      result.error('DOWNLOADS_IO_FAILED', '导出文件未能完整写入，请重新导出', null);
    }
  }
}