/*
 * fqapp native player surface plugin (OpenHarmony).
 *
 * The Dart half of the contract lives in lib/services/native_player.dart and
 * lib/services/ohos_playback.dart: Dart owns decoding (libmpv through the Dart
 * FFI/interop layer) and only asks the platform for a Flutter texture it can
 * render into. This plugin therefore does exactly two things:
 *
 *   1. hand out / size / release Flutter texture surfaces (MethodChannel
 *      "fqapp/native_player"), mirroring media_kit_video's OHOS
 *      VideoOutputManager + VideoOutput pair;
 *   2. toggle the keep-screen-on flag on the ability's main window.
 *   3. hold an AVSession plus an AUDIO_PLAYBACK long-running task while
 *      background listening is active, so HarmonyOS keeps the Dart-owned
 *      libmpv audio alive after the app leaves the foreground and routes the
 *      control-center / headset buttons back to Dart.
 *   4. move the system media volume through an AVVolumePanel node, which is the
 *      only way a third-party app can change the volume on HarmonyOS.
 *
 * It deliberately does not know about media, codecs or CENC: those stay on the
 * Dart side so the Android and OHOS implementations share one player core.
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
  SurfaceTextureEntry,
  TextureRegistry,
} from '@ohos/flutter_ohos';
import window from '@ohos.window';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { AVVolumePanel, audio } from '@kit.AudioKit';
import { BuilderNode, FrameNode, NodeController, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'NativePlayerPlugin';

/** Channel name shared verbatim with NativePlayer._channel on the Dart side. */
const CHANNEL_NAME = 'fqapp/native_player';

/**
 * Reverse channel methods Dart already listens for. NativePlayer._handleMethodCall
 * accepts 'onNotificationAction' (a Map with an 'action' key, or a bare string)
 * and 'onAudioBecomingNoisy'; the action names below are the same ones the
 * Android ListenKeepAliveService sends, so AudioPlaybackController needs no
 * OHOS-specific branch.
 */
const ACTION_CHANNEL = 'onNotificationAction';

/**
 * Only one AVSession may exist per UIAbility, so the session is created lazily
 * on the first startListenForeground and then reused via activate/deactivate.
 */
const SESSION_TAG = 'fqapp_listen';

/** This ability is declared with backgroundModes: ["audioPlayback"]. */
const BACKGROUND_MODE: backgroundTaskManager.BackgroundMode =
  backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK;

/**
 * Reads an integer argument and rejects anything that is not a number.
 *
 * Dart sends these as ints over the standard codec; parsing with parseInt would
 * silently turn a missing or malformed argument into NaN, which then reaches
 * the texture registry as an invalid texture id. Failing loudly here keeps the
 * error on the Dart side of the channel where it can be attributed.
 */
function readInt(value: ESObject): number {
  // 先收窄再校验：Number.isInteger 的形参是 unknown，直接传 ESObject
  // 会被判 arkts-no-any-unknown。
  if (typeof value !== 'number') {
    throw new Error(`expected an integer argument, got ${typeof value}`);
  }
  const numeric: number = value as number;
  if (!Number.isInteger(numeric)) {
    throw new Error(`expected an integer argument, got ${numeric}`);
  }
  return numeric;
}

/** Parameters of the detached volume panel; @Prop on the component side. */
class VolumeParams {
  level: number = 0;
}

@Builder
function volumePanelBuilder(params: VolumeParams) {
  AVVolumePanel({ volumeLevel: params.level });
}

/**
 * Drives the system media volume through AVVolumePanel.
 *
 * HarmonyOS does not let a third-party app write the system volume directly:
 * AudioVolumeManager can only read volumes and listen for changes, and
 * AudioManager.setVolume has been deprecated since API 9. The supported path is
 * the AVVolumePanel ArkUI component, which asks the system to apply a new media
 * volume and shows the system volume bar so the change stays visible.
 *
 * AVVolumePanel is a component rather than a manager object, so it is built into
 * a detached BuilderNode from the main window's UIContext. Every update builds a
 * fresh node instead of mutating the previous params: a BuilderNode renders the
 * parameter object it was built with, so changing `params.level` in place would
 * not reach the component.
 */
class VolumePanelNode extends NodeController {
  private node: BuilderNode<[VolumeParams]> | null = null;
  private context: common.UIAbilityContext | null;
  private initializing: boolean = false;
  private disposed: boolean = false;
  private retryTimer: number | undefined = undefined;
  /** Level requested while the node was still being built, applied on success. */
  private pendingLevel: number = -1;

  constructor(context: common.UIAbilityContext | null) {
    super();
    this.context = context;
    this.ensureInitialized();
  }

  dispose(): void {
    this.disposed = true;
    if (this.retryTimer !== undefined) {
      clearTimeout(this.retryTimer);
      this.retryTimer = undefined;
    }
    this.node = null;
  }

  /**
   * Builds the detached node. The window stage is not always ready when the
   * plugin attaches (the Flutter view may still be mounting), so a failure
   * retries briefly instead of dropping the panel for the session.
   */
  private ensureInitialized(): void {
    if (this.disposed || this.node !== null || this.initializing) {
      return;
    }
    const stage = this.context?.windowStage;
    if (stage === undefined) {
      this.scheduleRetry();
      return;
    }
    this.initializing = true;
    stage.getMainWindow()
      .then((mainWindow: window.Window) => {
        this.initializing = false;
        if (this.disposed || this.node !== null) {
          return;
        }
        try {
          const params = new VolumeParams();
          params.level = this.pendingLevel >= 0 ? this.pendingLevel : 0;
          const node = new BuilderNode<[VolumeParams]>(mainWindow.getUIContext());
          node.build(wrapBuilder<[VolumeParams]>(volumePanelBuilder), params);
          this.node = node;
        } catch (e) {
          this.node = null;
          Log.w(TAG, `volume panel build failed: ${e}`);
          this.scheduleRetry();
        }
      })
      .catch((e: Error) => {
        this.initializing = false;
        Log.w(TAG, `volume panel window lookup failed: ${e}`);
        this.scheduleRetry();
      });
  }

  private scheduleRetry(): void {
    if (this.disposed || this.node !== null || this.retryTimer !== undefined) {
      return;
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      this.ensureInitialized();
    }, 50);
  }

  makeNode(_: UIContext): FrameNode | null {
    return this.node !== null ? this.node.getFrameNode() : null;
  }

  /** @param level System volume level, in the device's own 0..max scale. */
  changeVolume(level: number): void {
    const applied = Math.round(level);
    this.pendingLevel = applied;
    this.ensureInitialized();
    const node = this.node;
    if (node == null) {
      // The window was not ready yet; the queued level is applied on build.
      return;
    }
    try {
      const params = new VolumeParams();
      params.level = applied;
      node.update(params);
    } catch (e) {
      Log.w(TAG, `volume panel update failed: ${e}`);
    }
  }
}

/**
 * One registered Flutter texture, keyed by the monotonically increasing handle
 * this plugin hands back to Dart.
 *
 * The last requested size is cached so repeated setSurfaceSize calls for the
 * same viewport do not resize the producer buffer on every Flutter build.
 */
class SurfaceEntry {
  readonly handle: number;
  readonly textureId: number;
  readonly surfaceId: number;
  private width: number = 1;
  private height: number = 1;
  private disposed: boolean = false;

  constructor(handle: number, entry: SurfaceTextureEntry) {
    this.handle = handle;
    this.textureId = entry.getTextureId();
    this.surfaceId = entry.getSurfaceId();
  }

  /**
   * Resizes the producer buffer, skipping the native call when the size did not
   * change (same rule as media_kit_video's VideoOutput.setSurfaceSize).
   */
  setSurfaceSize(registry: TextureRegistry, width: number, height: number): void {
    if (this.disposed || (this.width === width && this.height === height)) {
      return;
    }
    this.width = width;
    this.height = height;
    registry.setTextureBufferSize(this.textureId, width, height);
  }

  /**
   * Unregisters the texture. Idempotent: the engine may already have torn the
   * texture down, and unregisterTexture must only run once per surface.
   */
  dispose(registry: TextureRegistry | null): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.width = 1;
    this.height = 1;
    if (registry != null) {
      registry.unregisterTexture(this.textureId);
    }
  }
}

export default class NativePlayerPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private textureRegistry: TextureRegistry | null = null;
  private context: common.UIAbilityContext | null = null;
  private surfaces: Map<number, SurfaceEntry> = new Map();
  private nextHandle: number = 1;
  private keepScreenOn: boolean = false;
  /** Non-null once created; kept for the whole foreground-listening lifetime. */
  private session: avSession.AVSession | null = null;
  private listening: boolean = false;
  private backgroundRunning: boolean = false;
  /** Lazily created AVVolumePanel host; absent until the first volume call. */
  private volumePanel: VolumePanelNode | null = null;
  /** Media-stream level captured before a mute, restored when it is lifted. */
  private unmuteLevel: number = 0;
  private volumeManager: audio.AudioVolumeManager | null = null;

  getUniqueClassName(): string {
    return 'NativePlayerPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.textureRegistry = binding.getTextureRegistry();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    Log.i(TAG, `attached to engine on channel ${CHANNEL_NAME}`);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
    }
    // Dropping the surfaces here keeps a hot-restart from leaking textures; the
    // Dart side re-creates them from scratch on the next createSurface call.
    this.disposeAllSurfaces();
    this.releaseBackgroundSession();
    this.volumePanel?.dispose();
    this.volumePanel = null;
    this.volumeManager = null;
    this.channel = null;
    this.textureRegistry = null;
    this.context = null;
    this.keepScreenOn = false;
    Log.i(TAG, 'detached from engine');
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    if (this.keepScreenOn) {
      // Best effort: the ability's window may already be gone at this point, so
      // a failure here is logged rather than propagated.
      this.setWindowKeepScreenOn(false).catch((e: Error) => {
        Log.w(TAG, `clearing keep-screen-on on ability detach failed: ${e}`);
      });
    }
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'createSurface': {
        this.handleCreateSurface(result);
        break;
      }
      case 'setSurfaceSize': {
        this.handleSetSurfaceSize(call, result);
        break;
      }
      case 'disposeSurface': {
        this.handleDisposeSurface(call, result);
        break;
      }
      case 'setKeepScreenOn': {
        this.handleSetKeepScreenOn(call, result);
        break;
      }
      case 'startListenForeground':
      case 'stopListenForeground': {
        this.handleForegroundListener(call, result);
        break;
      }
      case 'setSystemVolume': {
        this.handleSetSystemVolume(call, result);
        break;
      }
      default: {
        result.notImplemented();
        break;
      }
    }
  }

  /**
   * Replies {"handle": int, "textureId": int, "surfaceId": int}. The handle is
   * this plugin's own id for the surface; textureId/surfaceId are the engine's.
   */
  private handleCreateSurface(result: MethodResult): void {
    try {
      const registry = this.textureRegistry;
      if (registry == null) {
        result.error('unavailable', 'NativePlayerPlugin is not attached to an engine.', null);
        return;
      }

      const handle = this.nextHandle;
      this.nextHandle += 1;

      const textureId = registry.getTextureId();
      const entry = registry.registerTexture(textureId);
      const surface = new SurfaceEntry(handle, entry);
      // The producer starts at 1x1 and is opaque black until mpv renders its
      // first frame, so a video never flashes the Flutter background.
      registry.setTextureBackGroundColor(surface.textureId, 0xFF000000);
      registry.setTextureBufferSize(surface.textureId, 1, 1);
      this.surfaces.set(handle, surface);

      const reply: Map<string, number> = new Map();
      reply.set('handle', surface.handle);
      reply.set('textureId', surface.textureId);
      reply.set('surfaceId', surface.surfaceId);
      Log.i(TAG, `createSurface: handle=${surface.handle} textureId=${surface.textureId} `
        + `surfaceId=${surface.surfaceId}`);
      result.success(reply);
    } catch (e) {
      Log.e(TAG, `createSurface failed: ${e}`);
      result.error('createSurface', `${e}`, null);
    }
  }

  private handleSetSurfaceSize(call: MethodCall, result: MethodResult): void {
    try {
      const handle = readInt(call.argument('handle'));
      const width = readInt(call.argument('width'));
      const height = readInt(call.argument('height'));
      const registry = this.textureRegistry;
      const surface = this.surfaces.get(handle);
      if (registry == null || surface == undefined) {
        result.error('unavailable', `No surface registered for handle ${handle}.`, null);
        return;
      }
      surface.setSurfaceSize(registry, width, height);
      result.success(null);
    } catch (e) {
      Log.e(TAG, `setSurfaceSize failed: ${e}`);
      result.error('setSurfaceSize', `${e}`, null);
    }
  }

  private handleDisposeSurface(call: MethodCall, result: MethodResult): void {
    try {
      const handle = readInt(call.argument('handle'));
      const surface = this.surfaces.get(handle);
      if (surface == undefined) {
        // Idempotent by contract: disposing an unknown handle is a no-op, not an
        // error, because Dart cannot tell teardown from a double dispose.
        Log.i(TAG, `disposeSurface: handle ${handle} is already gone`);
        result.success(null);
        return;
      }
      this.surfaces.delete(handle);
      surface.dispose(this.textureRegistry);
      Log.i(TAG, `disposeSurface: handle=${handle} textureId=${surface.textureId}`);
      result.success(null);
    } catch (e) {
      Log.e(TAG, `disposeSurface failed: ${e}`);
      result.error('disposeSurface', `${e}`, null);
    }
  }

  private handleSetKeepScreenOn(call: MethodCall, result: MethodResult): void {
    let on = false;
    try {
      // 用中间变量显式标注，避免 `const x = call.argument(...)` 推导出 Any。
      const flag: ESObject = call.argument('on');
      on = flag === true;
    } catch (e) {
      Log.e(TAG, `setKeepScreenOn failed to read its argument: ${e}`);
      result.error('setKeepScreenOn', `${e}`, null);
      return;
    }
    // Deferred reply: the flag lives on the ability window, which is resolved
    // asynchronously. Both branches reply exactly once.
    this.setWindowKeepScreenOn(on)
      .then(() => {
        Log.i(TAG, `setKeepScreenOn: ${on}`);
        result.success(null);
      })
      .catch((e: Error) => {
        Log.e(TAG, `setKeepScreenOn failed: ${e}`);
        result.error('setKeepScreenOn', `${e}`, null);
      });
  }

  /**
   * HarmonyOS has no foreground-service equivalent that keeps audio running on
   * its own: playback survives leaving the foreground only while an
   * AUDIO_PLAYBACK long-running task is held AND an AVSession is activated
   * (otherwise the system suspends the task and mutes the output, see the
   * audio FAQ "state=4 without an AVSession"). So the OHOS counterpart of the
   * Android ListenKeepAliveService is the pair created here.
   *
   * Dart owns the actual player: the session only publishes metadata/state to
   * the control center and forwards button presses back over the same channel.
   */
  private handleForegroundListener(call: MethodCall, result: MethodResult): void {
    if (call.method === 'startListenForeground') {
      this.startListenForeground(call, result);
    } else {
      this.stopListenForeground(result);
    }
  }

  private startListenForeground(call: MethodCall, result: MethodResult): void {
    const context = this.context;
    if (context == null) {
      result.error('startListenForeground',
        'NativePlayerPlugin is not attached to an ability.', null);
      return;
    }
    const metadata: avSession.AVMetadata = {
      assetId: this.readString(call, 'episode', 'fqapp-listen'),
      title: this.readString(call, 'title', ''),
    };
    const playing: boolean = call.argument('playing') === true;
    const positionMs: number = this.readNumber(call, 'positionMs', 0);
    const durationMs: number = this.readNumber(call, 'durationMs', 0);
    const speed: number = this.readNumber(call, 'speed', 1);

    this.ensureSession(context)
      .then(() => {
        const session = this.session;
        if (session == null) {
          throw new Error('AVSession was not created.');
        }
        session.setAVMetadata(metadata);
        // PlaybackPosition.elapsedTime is where playback has reached, and
        // updateTime is the wall clock when that was measured, so the control
        // centre extrapolates from here. A zero total means "unknown duration".
        session.setAVPlaybackState({
          state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY :
            avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
          position: {
            updateTime: Date.now() - positionMs,
            elapsedTime: positionMs,
          },
          speed: speed,
          duration: durationMs,
        });
        return this.startBackgroundTask(context);
      })
      .then(() => {
        this.listening = true;
        Log.i(TAG, `startListenForeground: ${metadata.title}`);
        result.success(null);
      })
      .catch((e: Error) => {
        Log.e(TAG, `startListenForeground failed: ${e}`);
        result.error('startListenForeground', `${e}`, null);
      });
  }

  private stopListenForeground(result: MethodResult): void {
    const context = this.context;
    // Stopping the long-running task without also stopping the audio invites a
    // system kill, so tear both down together and let Dart own the pause.
    const teardown = context == null || !this.backgroundRunning ?
      Promise.resolve() :
      backgroundTaskManager.stopBackgroundRunning(context);
    this.backgroundRunning = false;
    this.listening = false;
    const session = this.session;
    this.session = null;
    teardown
      .then(() => {
        session?.setAVPlaybackState({
          state: avSession.PlaybackState.PLAYBACK_STATE_STOP,
          position: { updateTime: Date.now(), elapsedTime: 0 },
        });
        session?.deactivate();
        session?.destroy();
        Log.i(TAG, 'stopListenForeground');
        result.success(null);
      })
      .catch((e: Error) => {
        Log.e(TAG, `stopListenForeground failed: ${e}`);
        result.error('stopListenForeground', `${e}`, null);
      });
  }

  /**
   * Routes a 0..1 player volume to the system media volume.
   *
   * Dart's setVolume(0) is the short-drama "start muted" default and
   * setVolume(1) is full volume, so the flag maps onto the media stream rather
   * than onto libmpv: the user asked for the system volume to move, and libmpv
   * writing its own `volume`/`mute` properties left the system slider untouched.
   *
   * AVVolumePanel is the only supported writer, so the level is applied by
   * pushing it into the detached panel node. The muted case records the current
   * level first and restores it when sound comes back, matching what a media
   * app is expected to do -- dropping to 0 and back to full would otherwise
   * discard the user's own volume choice.
   *
   * The conversion mirrors ohosSystemVolume() in lib/services/
   * ohos_playback_options.dart, which is covered by unit tests; keep the two
   * in step.
   */
  private handleSetSystemVolume(call: MethodCall, result: MethodResult): void {
    try {
      // 显式标注类型：MethodCall.argument 返回 embedding 的 Any，
      // 直接 const 推导会触发 arkts-no-any-unknown。
      const requested: ESObject = call.argument('volume');
      // typeof 先把 ESObject 收窄成 number，再交给 Number.isFinite —— 它的形参
      // 是 unknown，直接传 ESObject 同样会被判 arkts-no-any-unknown。
      if (typeof requested !== 'number') {
        result.error('setSystemVolume', `expected a number volume, got ${typeof requested}`, null);
        return;
      }
      const volume: number = requested as number;
      if (!Number.isFinite(volume)) {
        result.error('setSystemVolume', `expected a finite volume, got ${volume}`, null);
        return;
      }
      const manager = this.volumeManagerFor();
      // STREAM_USAGE_MOVIE is the media stream the short dramas play on; the
      // audiobook/voice-assistant streams are separate sliders on this device.
      const stream = audio.StreamUsage.STREAM_USAGE_MOVIE;
      const max = manager.getMaxVolumeByStream(stream);
      const min = manager.getMinVolumeByStream(stream);
      const panel = this.ensureVolumePanel();
      if (volume <= 0) {
        // Remember where the user was before this mute so unmuting restores it.
        if (this.unmuteLevel <= min) {
          this.unmuteLevel = manager.getVolumeByStream(stream);
        }
        panel.changeVolume(min);
        Log.i(TAG, `setSystemVolume: muted (restore level ${this.unmuteLevel})`);
        result.success(null);
        return;
      }
      let target: number;
      if (this.unmuteLevel > min) {
        target = this.unmuteLevel;
        this.unmuteLevel = 0;
      } else {
        target = min >= max ? max : Math.round(min + (max - min) * Math.min(1, volume));
        if (volume < 1 && target <= min) {
          // A non-zero request must never round down to silence.
          target = Math.min(max, min + 1);
        }
      }
      panel.changeVolume(target);
      Log.i(TAG, `setSystemVolume: ${target}/${max}`);
      result.success(null);
    } catch (e) {
      Log.e(TAG, `setSystemVolume failed: ${e}`);
      result.error('setSystemVolume', `${e}`, null);
    }
  }

  private volumeManagerFor(): audio.AudioVolumeManager {
    let manager = this.volumeManager;
    if (manager == null) {
      manager = audio.getAudioManager().getVolumeManager();
      this.volumeManager = manager;
    }
    return manager;
  }

  private ensureVolumePanel(): VolumePanelNode {
    let panel = this.volumePanel;
    if (panel == null) {
      panel = new VolumePanelNode(this.context);
      this.volumePanel = panel;
    }
    return panel;
  }

  /**
   * Creates the single allowed session, activates it and wires the control
   * callbacks. Reuses the existing session when one is already active so that
   * track changes do not recreate the control-center entry.
   */
  private async ensureSession(context: common.UIAbilityContext): Promise<void> {
    if (this.session != null) {
      this.session.activate();
      return;
    }
    const session = await avSession.createAVSession(context, SESSION_TAG, 'audio');
    session.activate();
    // Both keys are mandatory in AVMetadata; an empty assetId is rejected
    // with 6001014, so fall back to the tag when Dart has no episode id.
    session.on('play', () => {
      this.sendAction('playPause');
    });
    session.on('pause', () => {
      this.sendAction('playPause');
    });
    session.on('stop', () => {
      this.sendAction('stop');
    });
    session.on('playPrevious', () => {
      this.sendAction('prev');
    });
    session.on('playNext', () => {
      this.sendAction('next');
    });
    this.session = session;
  }

  /**
   * The API 9 (compatibleSdkVersion 5.0.5) long-running task path. The newer
   * ContinuousTaskRequest with submodes is API 21+ and therefore unavailable
   * here; this variant keeps the process alive without an AVSession submode.
   */
  private async startBackgroundTask(context: common.UIAbilityContext): Promise<void> {
    if (this.backgroundRunning) {
      return;
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: 'com.fqapp.fqapp',
        abilityName: 'EntryAbility',
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    // getWantAgent is promise-based (API 9+). Awaiting it matters: handing the
    // pending promise itself to startBackgroundRunning fails with 1600004
    // ("parameter error"), which is why the long-running task used to be
    // rejected silently and background listening looked like it did nothing.
    const agent: WantAgent = await wantAgent.getWantAgent(info);
    await new Promise<void>((resolve: (v: void) => void,
                              reject: (e: Error) => void) => {
      backgroundTaskManager.startBackgroundRunning(
        context,
        BACKGROUND_MODE,
        agent,
        // AsyncCallback<void> 的 err 形参是 BusinessError；用具体类型而不是
        // ESObject，err.code / err.message 才是可静态检查的字段。
        (err: BusinessError) => {
          if (err != undefined && err.code != 0) {
            reject(new Error(`startBackgroundRunning failed: ${err.code} ${err.message}`));
            return;
          }
          this.backgroundRunning = true;
          resolve();
        });
    });
    Log.i(TAG, 'startBackgroundRunning: AUDIO_PLAYBACK granted');
  }

  /** Sends one notification action back to Dart on the shared channel. */
  private sendAction(action: string): void {
    if (!this.listening) {
      return;
    }
    const args: Map<string, string> = new Map();
    args.set('action', action);
    this.channel?.invokeMethod(ACTION_CHANNEL, args);
  }

  private readString(call: MethodCall, key: string, fallback: string): string {
    const value: ESObject = call.argument(key);
    return typeof value === 'string' && value.length > 0 ? value as string : fallback;
  }

  private readNumber(call: MethodCall, key: string, fallback: number): number {
    const value: ESObject = call.argument(key);
    if (typeof value !== 'number') {
      return fallback;
    }
    // Number.isFinite 的形参是 unknown：先 as number 收窄再传入，
    // 否则这里也会被判 arkts-no-any-unknown。
    const numeric: number = value as number;
    return Number.isFinite(numeric) ? numeric : fallback;
  }

  private async setWindowKeepScreenOn(on: boolean): Promise<void> {
    const context = this.context;
    if (context == null) {
      throw new Error('NativePlayerPlugin is not attached to an ability.');
    }
    const mainWindow: window.Window = await window.getLastWindow(context);
    await mainWindow.setWindowKeepScreenOn(on);
    this.keepScreenOn = on;
  }

  /**
   * Best-effort teardown used when the engine goes away. Must stay silent and
   * synchronous-looking: the ability context may already be null there, in
   * which case only the in-memory session state can be dropped.
   */
  private releaseBackgroundSession(): void {
    this.listening = false;
    this.backgroundRunning = false;
    const session = this.session;
    this.session = null;
    if (session != null) {
      try {
        session.deactivate();
        session.destroy();
      } catch (e) {
        Log.w(TAG, `releasing the AVSession failed: ${e}`);
      }
    }
  }

  private disposeAllSurfaces(): void {
    this.surfaces.forEach((surface: SurfaceEntry) => {
      try {
        surface.dispose(this.textureRegistry);
      } catch (e) {
        Log.e(TAG, `disposeAllSurfaces: ${e}`);
      }
    });
    this.surfaces.clear();
    this.nextHandle = 1;
  }
}
