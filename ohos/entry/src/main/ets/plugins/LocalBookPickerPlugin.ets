/*
 * fqapp local book picker plugin (OpenHarmony).
 *
 * Mirrors android/app/src/main/kotlin/com/fqapp/fqapp/LocalBookPickerPlugin.kt
 * on MethodChannel "fqapp/local_books": Dart side (lib/services/imported_book_store.dart)
 * calls pickBookFile expecting
 *   {name, byteLength, text}  for .txt  (text already decoded)
 *   {name, byteLength, bytes}  for everything else (EPUB and friends)
 * or null when the user cancels.
 *
 * Android opens ACTION_OPEN_DOCUMENT; the HarmonyOS equivalent is the
 * DocumentViewPicker from @kit.CoreFileKit. Only the document the user chose is
 * read — no broad storage permission is requested — and the same 32 MB ceiling
 * as Android applies.
 *
 * TXT decoding mirrors Android's decodeText(): honour the BOM (UTF-8 / UTF-16),
 * otherwise try strict UTF-8 and fall back to GB18030, because Chinese TXT
 * novels are still commonly GBK/GB18030 encoded.
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
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const TAG: string = 'LocalBookPickerPlugin';
const CHANNEL_NAME: string = 'fqapp/local_books';
const MAX_FILE_BYTES: number = 32 * 1024 * 1024;
const BOOK_SUFFIX_CHOICES: Array<string> = [
  '电子书|.txt,.epub,.TXT,.EPUB',
];

// The decoded payload handed back to Dart. ArkTS needs the shape declared before
// an object literal can be built.
interface TextBook {
  name: string;
  byteLength: number;
  text: string;
}

interface RawBook {
  name: string;
  byteLength: number;
  bytes: Uint8Array;
}

export default class LocalBookPickerPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;
  private pending: MethodResult | null = null;

  getUniqueClassName(): string {
    return 'LocalBookPickerPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    Log.i(TAG, `attached to engine on channel ${CHANNEL_NAME}`);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.cancelPending('应用已关闭');
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
    this.cancelPending('应用窗口已关闭');
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'pickBookFile') {
      result.notImplemented();
      return;
    }
    const context = this.context;
    if (context == null) {
      result.error('NO_ACTIVITY', '文件选择器尚未就绪', null);
      return;
    }
    if (this.pending != null) {
      result.error('PICKER_BUSY', '文件选择器正在使用', null);
      return;
    }
    this.pending = result;
    const selectOptions = new picker.DocumentSelectOptions();
    selectOptions.maxSelectNumber = 1;
    selectOptions.selectMode = picker.DocumentSelectMode.FILE;
    selectOptions.fileSuffixFilters = BOOK_SUFFIX_CHOICES;
    const documentPicker = new picker.DocumentViewPicker(context);
    documentPicker.select(selectOptions).then((uris: Array<string>): void => {
      const current = this.pending;
      if (uris.length === 0 || current == null) {
        // User cancelled the picker.
        this.pending = null;
        current?.success(null);
        return;
      }
      this.readDocument(uris[0], current);
    }).catch((e: ESObject): void => {
      Log.e(TAG, `picker failed: ${e}`);
      const current = this.pending;
      this.pending = null;
      current?.error('PICKER_UNAVAILABLE', '无法打开文件选择器', null);
    });
  }

  private readDocument(uri: string, result: MethodResult): void {
    try {
      const stat = fs.statSync(uri);
      if (stat.size <= 0 || stat.size > MAX_FILE_BYTES) {
        this.pending = null;
        result.error('BOOK_IMPORT_READ_FAILED', '请选择小于 32 MB 的 TXT 或 EPUB 文件', null);
        return;
      }
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      let bytes: Uint8Array;
      try {
        // Size is bounded by MAX_FILE_BYTES above, so a single read is safe.
        const buffer = new ArrayBuffer(stat.size);
        const read = fs.readSync(file.fd, buffer);
        bytes = new Uint8Array(buffer, 0, read);
      } finally {
        fs.closeSync(file);
      }
      const name = this.displayName(uri);
      if (name.toLowerCase().endsWith('.txt')) {
        const book: TextBook = {
          name: name,
          byteLength: bytes.length,
          text: this.decodeText(bytes),
        };
        this.pending = null;
        result.success(book);
      } else {
        const book: RawBook = { name: name, byteLength: bytes.length, bytes: bytes };
        this.pending = null;
        result.success(book);
      }
    } catch (e) {
      Log.e(TAG, `read book failed: ${e}`);
      this.pending = null;
      result.error('BOOK_IMPORT_READ_FAILED', '读取书籍文件失败', null);
    }
  }

  /**
   * BOM first (UTF-8 / UTF-16LE / UTF-16BE), then strict UTF-8, then GB18030 —
   * the same order as Android's decodeText().
   */
  private decodeText(bytes: Uint8Array): string {
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      return new util.TextDecoder('utf-8').decodeToString(bytes.subarray(3));
    }
    if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
      return new util.TextDecoder('utf-16le').decodeToString(bytes.subarray(2));
    }
    if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
      return new util.TextDecoder('utf-16be').decodeToString(bytes.subarray(2));
    }
    try {
      // fatal: true is what makes this a strict attempt: malformed sequences
      // throw instead of turning into U+FFFD.
      return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes);
    } catch (e) {
      Log.i(TAG, `not strict utf-8, falling back to gb18030`);
      return new util.TextDecoder('gb18030').decodeToString(bytes);
    }
  }

  /**
   * The picker hands back a document URI rather than a cursor row, so the name
   * comes from the URI's last segment. Android queried DISPLAY_NAME; without
   * that here a name without an extension would be rejected by the Dart parser,
   * so fall back to something parseable.
   */
  private displayName(uri: string): string {
    const withoutQuery = uri.split('?')[0];
    const segments = withoutQuery.split('/');
    const last = segments[segments.length - 1];
    if (last.length === 0) return 'book.txt';
    // A Chinese book title arrives percent-encoded in the document URI; the
    // extension check and the Dart parser both need the raw name.
    let decoded = last;
    try {
      decoded = decodeURIComponent(last);
    } catch (e) {
      Log.w(TAG, `name is not decodable, keeping the raw segment: ${e}`);
    }
    return decoded.length > 240 ? decoded.slice(decoded.length - 240) : decoded;
  }

  private cancelPending(message: string): void {
    const pending = this.pending;
    if (pending == null) return;
    this.pending = null;
    pending.error('PICKER_CANCELED', message, null);
  }
}