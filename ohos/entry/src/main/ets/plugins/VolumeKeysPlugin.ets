import {
  AbilityAware,
  AbilityPluginBinding,
  EventChannel,
  EventSink,
  FlutterPlugin,
  FlutterPluginBinding,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StreamHandler,
} from '@ohos/flutter_ohos';
import { inputConsumer, KeyCode, KeyEvent } from '@kit.InputKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'VolumeKeysPlugin';
/** Channel names shared verbatim with VolumeKeys on the Dart side. */
const CHANNEL_NAME = 'fqapp/volume_keys';
const EVENTS_NAME = 'fqapp/volume_keys_events';

/** Payload of the volume-key event; mirrors what VolumeKeys decodes in Dart. */
interface VolumeKeyEvent {
  type: string;
}

/**
 * Forwards the volume keys into Dart so the reader can turn pages with them.
 *
 * Why the native side is needed: HarmonyOS treats the volume keys as system
 * function keys and consumes them before the Flutter key channel sees them. The
 * only supported way to intercept them from an app is
 * `inputConsumer.on('keyPressed', ...)` -- see the official
 * "优先响应系统功能键开发指导" guide (`keypressed-guidelines`). It is available for
 * KEYCODE_VOLUME_UP / KEYCODE_VOLUME_DOWN from API 16, which the project's
 * `compatibleSdkVersion` 5.0.5(17) satisfies.
 *
 * Why it is opt-in: subscribing *steals* the system volume function while the
 * app is the focused window. The reader therefore asks for the claim only while
 * a press would really turn a page (paged mode, the preference on, controls
 * hidden, page active) and releases it on every other state, so this plugin
 * must never subscribe at startup.
 *
 * Key events are delivered to Dart as `{'type': 'volumeUp' | 'volumeDown'}`.
 * The interception happens natively, so the platform volume bar will not show
 * while the reader holds the claim -- that is the intended trade-off the reader
 * opts into by enabling the preference.
 */
export default class VolumeKeysPlugin
  implements FlutterPlugin, MethodCallHandler, AbilityAware, StreamHandler
{
  private channel: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private context: common.UIAbilityContext | null = null;
  private claimed: boolean = false;

  getUniqueClassName(): string {
    return 'VolumeKeysPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    this.events = new EventChannel(binding.getBinaryMessenger(), EVENTS_NAME);
    this.events.setStreamHandler(this);
    Log.i(TAG, `attached to engine on channel ${CHANNEL_NAME}`);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.release();
    this.events?.setStreamHandler(null);
    this.channel?.setMethodCallHandler(null);
    this.events = null;
    this.channel = null;
    this.sink = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context as common.UIAbilityContext;
  }

  onDetachedFromAbility(): void {
    // Losing the ability means the window is gone; the subscription would be
    // useless and would keep intercepting the system volume.
    this.release();
    this.context = null;
  }

  onListen(_args: ESObject, events: EventSink): void {
    this.sink = events;
  }

  onCancel(_args: ESObject): void {
    this.sink = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'setEnabled':
        this.handleSetEnabled(call, result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private handleSetEnabled(call: MethodCall, result: MethodResult): void {
    const wanted: ESObject = call.argument('enabled');
    if (typeof wanted !== 'boolean') {
      result.error('setEnabled', `expected a boolean, got ${typeof wanted}`, null);
      return;
    }
    try {
      if (wanted as boolean) {
        this.claim();
      } else {
        this.release();
      }
      result.success(null);
    } catch (error) {
      // A failed claim must not break reading: report it, leave the keys with
      // the system, and clear the flag so the next sync retries cleanly.
      this.claimed = false;
      const err = error as BusinessError;
      Log.e(TAG, `setEnabled failed: ${err.code} ${err.message}`);
      result.error('setEnabled', `${err.message}`, null);
    }
  }

  private claim(): void {
    if (this.claimed) return;
    inputConsumer.on('keyPressed', this.config(KeyCode.KEYCODE_VOLUME_UP), this.onVolumeUp);
    inputConsumer.on('keyPressed', this.config(KeyCode.KEYCODE_VOLUME_DOWN), this.onVolumeDown);
    this.claimed = true;
    Log.i(TAG, 'volume keys claimed');
  }

  private release(): void {
    if (!this.claimed) return;
    try {
      inputConsumer.off('keyPressed', this.onVolumeUp);
      inputConsumer.off('keyPressed', this.onVolumeDown);
    } catch (error) {
      const err = error as BusinessError;
      Log.w(TAG, `release failed: ${err.code} ${err.message}`);
    }
    this.claimed = false;
    Log.i(TAG, 'volume keys released');
  }

  /**
   * `action: 1` is a press; `isRepeat: false` keeps a held key from paging
   * several times, which matches how the reader treats repeats elsewhere.
   */
  private config(key: number): inputConsumer.KeyPressedConfig {
    const options: inputConsumer.KeyPressedConfig = {
      key: key,
      action: 1,
      isRepeat: false,
    };
    return options;
  }

  private onVolumeUp: (event: KeyEvent) => void = (_event: KeyEvent): void => {
    this.send('volumeUp');
  };

  private onVolumeDown: (event: KeyEvent) => void = (_event: KeyEvent): void => {
    this.send('volumeDown');
  };

  private send(type: string): void {
    const sink = this.sink;
    if (sink == null) return;
    const payload: VolumeKeyEvent = { type: type };
    sink.success(payload);
  }
}
