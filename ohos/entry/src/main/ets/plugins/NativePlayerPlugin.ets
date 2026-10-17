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
import { common } from '@kit.AbilityKit';

const TAG = 'NativePlayerPlugin';

/** Channel name shared verbatim with NativePlayer._channel on the Dart side. */
const CHANNEL_NAME = 'fqapp/native_player';

/**
 * Reads an integer argument and rejects anything that is not a number.
 *
 * Dart sends these as ints over the standard codec; parsing with parseInt would
 * silently turn a missing or malformed argument into NaN, which then reaches
 * the texture registry as an invalid texture id. Failing loudly here keeps the
 * error on the Dart side of the channel where it can be attributed.
 */
function readInt(value: ESObject): number {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new Error(`expected an integer argument, got ${typeof value}`);
  }
  return value as number;
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
      on = call.argument('on') === true;
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
   * Reported as a plain success so the Dart side can call it unconditionally on
   * every platform. Android uses these to hold a media notification and audio
   * focus; the OHOS foreground-listening session is not implemented yet.
   */
  private handleForegroundListener(call: MethodCall, result: MethodResult): void {
    try {
      Log.i(TAG, `${call.method}: accepted, OHOS foreground-listening session is not implemented yet`);
      result.success(null);
    } catch (e) {
      Log.e(TAG, `${call.method} failed: ${e}`);
      result.error(call.method, `${e}`, null);
    }
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
