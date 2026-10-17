/*
 * fqapp library backup plugin (OpenHarmony).
 *
 * Mirrors android/app/src/main/kotlin/com/fqapp/fqapp/LibraryBackupPlugin.kt
 * on MethodChannel "fqapp/library_backup": Dart side
 * (lib/services/library_backup_service.dart) calls saveBackup{name, bytes}
 * expecting bool and openBackup expecting Uint8List? / null-on-cancel.
 *
 * Android uses the system SAF picker; on OHOS the equivalent is the
 * DocumentViewPicker from @kit.CoreFileKit. The plugin touches only the
 * document the user picked — no broad storage permission is requested — and
 * keeps the same limits as Android: 16 MB ceiling and a strict backup
 * filename whitelist on save.
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

const TAG: string = 'LibraryBackupPlugin';
const CHANNEL_NAME: string = 'fqapp/library_backup';
const MAX_BYTES: number = 16 * 1024 * 1024;

export default class LibraryBackupPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;

  getUniqueClassName(): string {
    return 'LibraryBackupPlugin';
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
    const context = this.context;
    if (call.method !== 'openBackup' && call.method !== 'saveBackup') {
      result.notImplemented();
      return;
    }
    if (context == null) {
      result.error('BACKUP_NO_ACTIVITY', '应用窗口不可用', null);
      return;
    }
    if (call.method === 'saveBackup') {
      this.handleSave(call, context, result);
    } else {
      this.handleOpen(context, result);
    }
  }

  private handleSave(call: MethodCall, context: common.UIAbilityContext, result: MethodResult): void {
    const bytes = call.argument('bytes') as Uint8Array | null;
    if (bytes == null || bytes.length === 0 || bytes.length > MAX_BYTES) {
      result.error('BACKUP_SIZE', '备份为空或超过 16 MB', null);
      return;
    }
    const requested = call.argument('name') as string | null;
    // Same whitelist as Android: a component may only pass a plain backup name.
    const name = (requested != null && /^[a-zA-Z0-9_.-]{1,100}\.json$/.test(requested))
      ? requested
      : 'fqapp-backup.json';

    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [name];
    const documentPicker = new picker.DocumentViewPicker(context);
    documentPicker.save(saveOptions).then((uris: Array<string>): void => {
      if (uris.length === 0) {
        // User cancelled the picker.
        result.success(false);
        return;
      }
      this.writeBackup(uris[0], bytes, result);
    }).catch((e: ESObject): void => {
      Log.e(TAG, `save picker failed: ${e}`);
      result.error('BACKUP_PICKER_UNAVAILABLE', '无法打开系统文件选择器', null);
    });
  }

  private writeBackup(uri: string, bytes: Uint8Array, result: MethodResult): void {
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer as ArrayBuffer, { offset: 0, length: bytes.length });
        fs.fsyncSync(file.fd);
      } finally {
        fs.closeSync(file);
      }
      result.success(true);
    } catch (e) {
      Log.e(TAG, `write backup failed: ${e}`);
      result.error('BACKUP_IO_FAILED', '备份未能完整写入，请重新导出并使用新文件', null);
    }
  }

  private handleOpen(context: common.UIAbilityContext, result: MethodResult): void {
    const selectOptions = new picker.DocumentSelectOptions();
    selectOptions.maxSelectNumber = 1;
    selectOptions.selectMode = picker.DocumentSelectMode.FILE;
    const documentPicker = new picker.DocumentViewPicker(context);
    documentPicker.select(selectOptions).then((uris: Array<string>): void => {
      if (uris.length === 0) {
        // User cancelled the picker.
        result.success(null);
        return;
      }
      this.readBackup(uris[0], result);
    }).catch((e: ESObject): void => {
      Log.e(TAG, `open picker failed: ${e}`);
      result.error('BACKUP_PICKER_UNAVAILABLE', '无法打开系统文件选择器', null);
    });
  }

  private readBackup(uri: string, result: MethodResult): void {
    try {
      const stat = fs.statSync(uri);
      if (stat.size > MAX_BYTES) {
        result.error('BACKUP_IO_FAILED', '备份文件超过 16 MB', null);
        return;
      }
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        // Size is bounded by MAX_BYTES above, so a single read is safe.
        const buffer = new ArrayBuffer(stat.size);
        const read = fs.readSync(file.fd, buffer);
        if (read !== stat.size) {
          result.error('BACKUP_IO_FAILED', '读取失败，请重新选择备份文件', null);
          return;
        }
        result.success(new Uint8Array(buffer));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      Log.e(TAG, `read backup failed: ${e}`);
      result.error('BACKUP_IO_FAILED', '读取失败，请选择不超过 16 MB 的备份文件', null);
    }
  }
}
