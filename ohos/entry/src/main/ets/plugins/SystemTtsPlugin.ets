/*
 * fqapp system TTS plugin (HarmonyOS / OpenHarmony).
 *
 * Mirrors android/app/src/main/kotlin/com/fqapp/fqapp/SystemTtsPlugin.kt on
 * MethodChannel "fqapp/system_tts" and EventChannel "fqapp/system_tts_events".
 * The Dart half lives in lib/services/system_tts.dart.
 *
 * Android drives the framework android.speech.tts.TextToSpeech; on HarmonyOS
 * we use Core Speech Kit's textToSpeech from @kit.CoreSpeechKit. The contract
 * differences are handled here so the Dart side stays platform-agnostic:
 *
 *  - The platform ships built-in voices, not user-installed engines. The
 *    `engines()` reply maps those voices (keyed by their `person` id) to the
 *    engine entries the settings UI already renders, so the existing picker
 *    becomes a voice/音色 selector.
 *  - There is no per-utterance range callback, so Dart only learns progress at
 *    the end of each piece ("done"). It already copes with engines that lack
 *    range events, so nothing changes on the Dart side.
 *  - `isBackStage: true` is requested at engine creation so listening keeps
 *    playing after the screen turns off / the app moves to the background,
 *    which is the core use case for a 听书 app.
 */

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
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const TAG: string = 'SystemTtsPlugin';
const CHANNEL_NAME: string = 'fqapp/system_tts';
const EVENTS_NAME: string = 'fqapp/system_tts_events';

/** One engine instance is shared; the device allows only 3 per all apps. */
const MAX_TEXT_LENGTH: number = 300;
/** Default Chinese female voice, the one recommended by the platform docs. */
const DEFAULT_PERSON: number = 13;
const DEFAULT_LANGUAGE: string = 'zh-CN';

/**
 * Shapes the Dart side already expects on the 'engines' reply; declaring them
 * keeps ArkTS from falling back to untyped object literals.
 */
interface SystemTtsEngine {
  package: string;
  label: string;
}

interface EnginesReply {
  engines: SystemTtsEngine[];
  defaultEngine: string | null;
}

/** Known voices; 8 is the English (US) female voice, the rest are Chinese. */
const VOICE_LABELS: Record<number, string> = {
  0: '聆小珊 · 女声',
  13: '聆小珊 · 女声',
  21: '凌飞哲 · 男声',
  8: '劳拉 · 英语女声',
};

export default class SystemTtsPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware, StreamHandler {
  private channel: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private context: common.UIAbilityContext | null = null;

  /** The live engine, created lazily and torn down on shutdown(). */
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  /** The requestId currently being spoken, or null when idle/stopped. */
  private activeId: string | null = null;
  /** Bumped on stop/shutdown/initialize to drop stale callbacks. */
  private generation: number = 0;
  /** Speech rate (0.5–2), applied to every utter call. */
  private rate: number = 1;
  /** True once a successful createEngine + setListener has happened. */
  private ready: boolean = false;

  getUniqueClassName(): string {
    return 'SystemTtsPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    this.events = new EventChannel(binding.getBinaryMessenger(), EVENTS_NAME);
    this.events.setStreamHandler(this);
    Log.i(TAG, `attached to engine on channel ${CHANNEL_NAME}`);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.internalShutdown();
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
    }
    if (this.events != null) {
      this.events.setStreamHandler(null);
    }
    this.channel = null;
    this.events = null;
    this.sink = null;
    this.context = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context as common.UIAbilityContext;
  }

  onDetachedFromAbility(): void {
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
      case 'engines':
        this.handleEngines(result);
        break;
      case 'initialize':
        this.handleInitialize(call, result);
        break;
      case 'speak':
        this.handleSpeak(call, result);
        break;
      case 'stop':
        this.handleStop(result);
        break;
      case 'shutdown':
        this.handleShutdown(result);
        break;
      case 'settings':
        this.handleSettings(result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  // --- engines ----------------------------------------------------------

  private handleEngines(result: MethodResult): void {
    // List the voices through a short-lived engine so we never pin an instance
    // just for the settings page (the device caps simultaneous engines at 3).
    const query: textToSpeech.VoiceQuery = {
      requestId: util.generateRandomUUID(true),
      online: 1,
    };
    this.createEngine(DEFAULT_PERSON, DEFAULT_LANGUAGE)
      .then((temp: textToSpeech.TextToSpeechEngine): Promise<textToSpeech.VoiceInfo[]> => {
        return temp.listVoices(query);
      })
      .then((voices: textToSpeech.VoiceInfo[]): void => {
        const engines: Array<SystemTtsEngine> = [];
        const seen: Set<string> = new Set<string>();
        for (const voice of voices) {
          const label: string = this.voiceLabel(voice);
          if (seen.has(label)) {
            continue;
          }
          seen.add(label);
          const entry: SystemTtsEngine = { package: String(voice.person), label: label };
          engines.push(entry);
        }
        const defaultEngine: string | null = this.pickDefault(engines);
        Log.i(TAG, `engines: ${engines.length} voices, default=${defaultEngine}`);
        const reply: EnginesReply = { engines: engines, defaultEngine: defaultEngine };
        result.success(reply);
      })
      .catch((err: BusinessError): void => {
        Log.e(TAG, `listVoices failed: ${err?.code ?? ''} ${err?.message ?? err}`);
        // Honest empty result: the settings UI already explains the situation.
        const empty: EnginesReply = { engines: [], defaultEngine: null };
        result.success(empty);
      });
  }

  /**
   * Builds a human label for a voice. Known persons get friendly names; the
   * rest fall back to language + gender. Voices that must be downloaded are
   * marked so the user understands a selection may fail at init time.
   */
  private voiceLabel(voice: textToSpeech.VoiceInfo): string {
    let label: string | undefined = VOICE_LABELS[voice.person];
    if (label == undefined) {
      const gender: string =
        voice.gender === 'Male' ? '男声' : voice.gender === 'Female' ? '女声' : '语音';
      const lang: string = voice.language === 'en-US' ? '英文' : '中文';
      label = `${lang} · ${gender}`;
    }
    if (voice.status === 'GA') {
      label += '（需下载）';
    }
    return label;
  }

  private pickDefault(engines: Array<SystemTtsEngine>): string | null {
    if (engines.length === 0) {
      return null;
    }
    for (const entry of engines) {
      if (entry.package === String(DEFAULT_PERSON)) {
        return entry.package;
      }
    }
    return engines[0].package;
  }

  // --- initialize -------------------------------------------------------

  private handleInitialize(call: MethodCall, result: MethodResult): void {
    const engineArg: string | null = (call.argument('engine') as string | null) ?? null;
    const rateArg: number = (call.argument('rate') as number) ?? 1;
    let person: number = DEFAULT_PERSON;
    let language: string = DEFAULT_LANGUAGE;
    if (engineArg != null && engineArg !== '') {
      const parsed: number = parseInt(engineArg, 10);
      if (!isNaN(parsed)) {
        person = parsed;
        if (parsed === 8) {
          language = 'en-US';
        }
      }
    }
    this.rate = Math.min(2, Math.max(0.5, rateArg));

    // A new selection may need a different voice, so rebuild from scratch.
    this.internalShutdown();
    this.createEngine(person, language)
      .then((engine: textToSpeech.TextToSpeechEngine): void => {
        engine.setListener(this.buildListener());
        this.engine = engine;
        this.ready = true;
        this.activeId = null;
        Log.i(TAG, `initialize ok: person=${person} language=${language}`);
        result.success(MAX_TEXT_LENGTH);
      })
      .catch((err: BusinessError): void => {
        this.engine = null;
        this.ready = false;
        Log.e(TAG, `initialize failed: ${err?.code ?? ''} ${err?.message ?? err}`);
        result.error('init_failed', this.initErrorMessage(err), null);
      });
  }

  private initErrorMessage(err: BusinessError): string {
    const code: number | undefined = err?.code;
    if (code === 1002300003) {
      return '所选音色尚未下载，请先下载该音色，或选择已安装的音色';
    }
    if (code === 1002300002) {
      return '系统不支持该语言，请选择中文或英文音色';
    }
    if (code === 1002300005) {
      return '朗读引擎创建失败，请稍后重试';
    }
    return '朗读引擎启动失败，请检查系统语音设置';
  }

  private createEngine(person: number, language: string): Promise<textToSpeech.TextToSpeechEngine> {
    const extra: Record<string, Object> = {
      // A unique name per instance avoids the multi-instance name-collision
      // trap documented in the Core Speech Kit FAQ.
      'style': 'interaction-broadcast',
      'locate': 'CN',
      'name': `fqapp-tts-${util.generateRandomUUID(true)}`,
      'isBackStage': true,
    };
    const params: textToSpeech.CreateEngineParams = {
      language: language,
      person: person,
      online: 1,
      extraParams: extra,
    };
    return textToSpeech.createEngine(params);
  }

  // --- speak ------------------------------------------------------------

  private handleSpeak(call: MethodCall, result: MethodResult): void {
    const text: string | null = (call.argument('text') as string | null) ?? null;
    const id: string | null = (call.argument('id') as string | null) ?? null;
    if (this.engine == null || !this.ready) {
      result.error('not_ready', '朗读未初始化', null);
      return;
    }
    if (text == null || text.length === 0) {
      result.error('invalid_text', '朗读内容为空', null);
      return;
    }
    if (id == null || id.length === 0) {
      result.error('invalid_id', '朗读任务标识缺失', null);
      return;
    }
    if (text.length > 10000) {
      result.error('too_long', '朗读内容超过 10000 字符上限', null);
      return;
    }

    this.activeId = id;
    const extraParam: Record<string, Object> = {
      'speed': this.rate,
      'volume': 1,
      'pitch': 1,
      'languageContext': 'zh-CN',
      'audioType': 'pcm',
      // playType 1: synthesize and play, no audio stream returned.
      'playType': 1,
      // queueMode 1 (抢占): a new utterance replaces the current one so a
      // late piece never queues up behind a paused/stopped one.
      'queueMode': 1,
    };
    const speakParams: textToSpeech.SpeakParams = {
      requestId: id,
      extraParams: extraParam,
    };
    try {
      this.engine.speak(text, speakParams);
      result.success(null);
    } catch (err) {
      const message: string = err instanceof Error ? err.message : `${err}`;
      Log.e(TAG, `speak failed: ${message}`);
      this.activeId = null;
      result.error('speak_failed', `朗读提交失败：${message}`, null);
    }
  }

  // --- stop / shutdown --------------------------------------------------

  private handleStop(result: MethodResult): void {
    this.generation += 1;
    this.activeId = null;
    if (this.engine != null) {
      try {
        this.engine.stop();
      } catch (err) {
        Log.e(TAG, `stop failed: ${err}`);
      }
    }
    // The engine's onStop callback (if any) arrives with the old id, which no
    // longer matches, so it is ignored. No event is emitted here.
    result.success(null);
  }

  private handleShutdown(result: MethodResult): void {
    this.internalShutdown();
    result.success(null);
  }

  private internalShutdown(): void {
    this.generation += 1;
    this.activeId = null;
    this.ready = false;
    if (this.engine != null) {
      const engine: textToSpeech.TextToSpeechEngine = this.engine;
      this.engine = null;
      try {
        engine.stop();
      } catch (err) {
        Log.e(TAG, `shutdown stop failed: ${err}`);
      }
      try {
        engine.shutdown();
      } catch (err) {
        Log.e(TAG, `shutdown failed: ${err}`);
      }
    }
  }

  // --- settings ---------------------------------------------------------

  private handleSettings(result: MethodResult): void {
    // There is no public deep link to the TTS voice settings. Open the system
    // settings app as a reasonable equivalent (mirrors Android's
    // ACTION_SETTINGS fallback) so the button still does something useful.
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx == null) {
      result.error('no_activity', '无法打开系统设置', null);
      return;
    }
    const want: Want = {
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'com.huawei.hmos.settings.MainAbility',
    };
    try {
      ctx.startAbility(want);
      result.success(null);
    } catch (err) {
      Log.e(TAG, `open settings failed: ${err}`);
      result.error('settings_unavailable', '无法打开系统设置', null);
    }
  }

  // --- listener + events ------------------------------------------------

  private buildListener(): textToSpeech.SpeakListener {
    return {
      onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
        Log.i(TAG, `onStart ${requestId}`);
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        // type 0 = synthesis finished, type 1 = playback finished. Only the
        // latter should advance to the next piece.
        if (response.type !== 1) {
          return;
        }
        if (requestId !== this.activeId) {
          return;
        }
        const id: string = this.activeId;
        this.activeId = null;
        this.emit(id, 'done', 0);
      },
      onStop: (requestId: string, response: textToSpeech.StopResponse): void => {
        // Follows a stop() we triggered; activeId is already cleared, so the
        // matching check below naturally drops it.
        Log.i(TAG, `onStop ${requestId}`);
      },
      onData: (
        requestId: string,
        audio: ArrayBuffer,
        response: textToSpeech.SynthesisResponse,
      ): void => {
        // Not used: playType is 1, so no audio stream is synthesized.
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        if (requestId !== this.activeId) {
          return;
        }
        const id: string = this.activeId;
        this.activeId = null;
        Log.e(TAG, `onError ${requestId} ${errorCode} ${errorMessage}`);
        this.emit(id, 'error', 0);
      },
    };
  }

  private emit(id: string, type: string, start: number): void {
    if (this.sink == null) {
      return;
    }
    this.sink.success({
      type: type,
      id: id,
      start: start,
    });
  }
}
