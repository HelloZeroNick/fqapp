/*
 * fqapp reader device plugin (OpenHarmony).
 *
 * Mirrors android/app/src/main/kotlin/com/fqapp/fqapp/ReaderDevicePlugin.kt
 * on MethodChannel "fqapp/reader". Android owns brightness, immersive window,
 * keep-screen-on and the system status broadcast; this OHOS port only covers
 * the reading-font import/export, which is what the reader appearance sheet
 * drives. Font bytes are copied into the app sandbox (reader-fonts/, content-
 * addressed like Android) on import, and copied back out to a user-picked file
 * on export — the same "touch only the document the user chose" rule the backup
 * plugin follows.
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
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const TAG: string = 'ReaderDevicePlugin';
const CHANNEL_NAME: string = 'fqapp/reader';
const FONT_DIR: string = 'reader-fonts';
const MAX_BYTES: number = 32 * 1024 * 1024;
// Same magic-number gate as Android: TTF/OTF/TTC/TTF(true).
const FONT_SIGNATURES: Array<string> = ['00010000', '4f54544f', '74746366', '74727565'];
const FONT_SUFFIX_CHOICES: Array<string> = [
  '字体文件|.ttf,.otf,.ttc,.TTF,.OTF,.TTC',
];

// The save dialog wants bare suffixes, so it gets its own list.
const FONT_SAVE_SUFFIXES: Array<string> = ['.ttf', '.otf', '.ttc'];

// The picker hands back the imported font to Dart; declaring the shape keeps
// ArkTS from rejecting the object literal.
interface ImportedFont {
  path: string;
  name: string;
}

// One entry of the pruning list; the object literal needs an explicit type too.
interface FontFileStat {
  name: string;
  mtime: number;
}

export default class ReaderDevicePlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;
  private pendingFont: MethodResult | null = null;

  getUniqueClassName(): string {
    return 'ReaderDevicePlugin';
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
    if (call.method !== 'pickFont' && call.method !== 'exportFont') {
      result.notImplemented();
      return;
    }
    if (context == null) {
      result.error('READER_NO_ACTIVITY', '阅读界面尚未就绪', null);
      return;
    }
    if (call.method === 'pickFont') {
      this.handlePickFont(context, result);
    } else {
      this.handleExportFont(call, context, result);
    }
  }

  private handlePickFont(context: common.UIAbilityContext, result: MethodResult): void {
    if (this.pendingFont != null) {
      result.error('FONT_PICKER_BUSY', '请先关闭已打开的字体选择器', null);
      return;
    }
    this.pendingFont = result;
    const selectOptions = new picker.DocumentSelectOptions();
    selectOptions.maxSelectNumber = 1;
    selectOptions.selectMode = picker.DocumentSelectMode.FILE;
    selectOptions.fileSuffixFilters = FONT_SUFFIX_CHOICES;
    const documentPicker = new picker.DocumentViewPicker(context);
    documentPicker.select(selectOptions).then((uris: Array<string>): void => {
      if (uris.length === 0) {
        // User cancelled the picker.
        this.pendingFont = null;
        result.success(null);
        return;
      }
      this.importFont(uris[0], result);
    }).catch((e: ESObject): void => {
      Log.e(TAG, `font picker failed: ${e}`);
      this.pendingFont = null;
      result.error('FONT_PICKER_UNAVAILABLE', '无法打开文件选择器', null);
    });
  }

  private importFont(uri: string, result: MethodResult): void {
    const context = this.context;
    if (context == null) {
      this.pendingFont = null;
      result.error('READER_NO_ACTIVITY', '阅读界面尚未就绪', null);
      return;
    }
    try {
      const stat = fs.statSync(uri);
      if (stat.size < 12 || stat.size > MAX_BYTES) {
        this.pendingFont = null;
        result.error('FONT_IMPORT_FAILED', '请选择小于 32 MB 的字体文件', null);
        return;
      }
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      let total = 0;
      const hash = cryptoFramework.createMd('SHA256');
      let name = this.displayName(uri);
      try {
        const buffer = new ArrayBuffer(16 * 1024);
        while (true) {
          const read = fs.readSync(file.fd, buffer);
          if (read <= 0) break;
          total += read;
          if (total > MAX_BYTES) {
            throw new Error('FONT_TOO_LARGE');
          }
          const chunk: cryptoFramework.DataBlob = { data: new Uint8Array(buffer, 0, read) };
          hash.updateSync(chunk);
        }
      } finally {
        fs.closeSync(file);
      }
      const signature = this.readSignature(uri);
      if (!FONT_SIGNATURES.includes(signature)) {
        this.pendingFont = null;
        result.error('FONT_IMPORT_FAILED', '请选择 TTF、OTF 或 TTC 字体文件', null);
        return;
      }
      const digest: Uint8Array = hash.digestSync().data;
      let hex: string = '';
      for (let i = 0; i < digest.length; i++) {
        hex += (digest[i] & 0xff).toString(16).padStart(2, '0');
      }
      const directory = `${context.filesDir}/${FONT_DIR}`;
      fs.mkdirSync(directory, true);
      const target = `${directory}/${hex}.font`;
      this.copyFile(uri, target);
      // Keep only a few recent fonts; older ones are pruned so the app sandbox
      // does not grow with every import.
      this.pruneFonts(directory, target);
      this.pendingFont = null;
      const imported: ImportedFont = { path: target, name: name };
      result.success(imported);
    } catch (e) {
      Log.e(TAG, `import font failed: ${e}`);
      this.pendingFont = null;
      const message = (e as Error)?.message ?? '字体导入失败';
      result.error('FONT_IMPORT_FAILED', message.includes('FONT_TOO_LARGE') ? '请选择小于 32 MB 的字体文件' : '字体导入失败', null);
    }
  }

  private handleExportFont(call: MethodCall, context: common.UIAbilityContext, result: MethodResult): void {
    const source = call.argument('path') as string | null;
    if (source == null || source.length === 0) {
      result.error('FONT_EXPORT_FAILED', '没有可导出的字体', null);
      return;
    }
    const suggested = call.argument('name') as string | null;
    const fileName = (suggested != null && /^[a-zA-Z0-9_.-]{1,100}\.(ttf|otf|ttc)$/i.test(suggested))
      ? suggested
      : 'fqapp-font.ttf';
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [fileName];
    saveOptions.fileSuffixChoices = FONT_SAVE_SUFFIXES;
    const documentPicker = new picker.DocumentViewPicker(context);
    documentPicker.save(saveOptions).then((uris: Array<string>): void => {
      if (uris.length === 0) {
        result.success(false);
        return;
      }
      this.copyFile(source, uris[0]);
      result.success(true);
    }).catch((e: ESObject): void => {
      Log.e(TAG, `export font failed: ${e}`);
      result.error('FONT_EXPORT_FAILED', '无法导出字体文件', null);
    });
  }

  private copyFile(source: string, destination: string): void {
    const stat = fs.statSync(source);
    const src = fs.openSync(source, fs.OpenMode.READ_ONLY);
    try {
      const dest = fs.openSync(destination, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const buffer = new ArrayBuffer(16 * 1024);
        let remaining = stat.size;
        // Read and write without an explicit position: both APIs continue from
        // the file's own cursor. Passing { offset: 0, length: n } re-reads from
        // the start of the file every iteration, which silently produced a
        // 16 KB font that no engine could parse.
        while (remaining > 0) {
          const read = fs.readSync(src.fd, buffer);
          if (read <= 0) break;
          fs.writeSync(dest.fd, buffer, { length: read });
          remaining -= read;
        }
        fs.fsyncSync(dest.fd);
        const copied = fs.statSync(destination);
        if (copied.size !== stat.size) {
          throw new Error(`FONT_COPY_SHORT: ${copied.size}/${stat.size}`);
        }
      } finally {
        fs.closeSync(dest);
      }
    } finally {
      fs.closeSync(src);
    }
  }

  private readSignature(uri: string): string {
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const header = new ArrayBuffer(4);
        const read = fs.readSync(file.fd, header);
        if (read < 4) return '';
        const bytes = new Uint8Array(header);
        let signature = '';
        for (let i = 0; i < 4; i++) {
          signature += (bytes[i] & 0xff).toString(16).padStart(2, '0');
        }
        return signature;
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      Log.e(TAG, `read signature failed: ${e}`);
      return '';
    }
  }

  private displayName(uri: string): string {
    // The picker hands back a content URI, not a real filename; Android used the
    // DISPLAY_NAME column. Without a query here, fall back to a friendly label.
    return '自定义字体';
  }

  private pruneFonts(directory: string, keep: string): void {
    try {
      const list = fs.listFileSync(directory);
      const fonts: Array<FontFileStat> = list
        .filter((name: string): boolean => name.endsWith('.font') && `${directory}/${name}` !== keep)
        .map((name: string): FontFileStat => {
          const stat = fs.statSync(`${directory}/${name}`);
          const entry: FontFileStat = { name: name, mtime: stat.mtime };
          return entry;
        })
        .sort((a: FontFileStat, b: FontFileStat): number => b.mtime - a.mtime)
        .slice(0, 3);
      for (const old of fonts) {
        try {
          fs.unlinkSync(`${directory}/${old.name}`);
        } catch (e) {
          Log.w(TAG, `prune font failed: ${e}`);
        }
      }
    } catch (e) {
      Log.w(TAG, `list fonts failed: ${e}`);
    }
  }
}
