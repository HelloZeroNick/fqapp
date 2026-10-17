/// OpenHarmony playback backend for [NativePlayer].
///
/// This is a `part` of lib/services/native_player.dart, so it can drive the
/// instance's private state (controllers, `_handleEvent`, `_instances`) without
/// widening the class's public surface.
///
/// Android plays media through ExoPlayer in the host app, driven over the
/// `fqapp/native_player` method channel. OHOS has no equivalent native player,
/// so decoding moves to this process: an [mk.NativePlayer] (media_kit +
/// libmpv) is
/// opened against a `Surface` that comes from the ArkTS plugin
/// ohos/entry/src/main/ets/plugins/NativePlayerPlugin.ets, and the same
/// texture is reported back as the player's texture id.
///
/// The plugin deliberately owns only the surface lifecycle. It answers
/// `createSurface` / `setSurfaceSize` / `disposeSurface` / `setKeepScreenOn`
/// and the two foreground-session no-ops, and reports `notImplemented` for
/// everything else -- in particular `create`, `play`, `pause`, `seek`,
/// `setVolume`, `setRate` and `dispose`, which is why [NativePlayer._invoke]
/// must not be reached on this platform.

part of 'native_player.dart';

/// Drives the OHOS backend for one [NativePlayer] instance.
///
/// Everything here is reached only when [Platform.operatingSystem] is
/// `'ohos'`; the Android paths in native_player.dart stay untouched.
class _OhosBackend {
  _OhosBackend(this._owner, this._keyHex);

  final NativePlayer _owner;
  final String _keyHex;

  /// The ArkTS plugin's id for the surface this instance renders into.
  int? _surfaceHandle;

  /// media_kit's native player. Created lazily because libmpv is loaded on
  /// the first `mk.Player()` construction, which is expensive and must happen
  /// on the platform thread only.
  mk.NativePlayer? _player;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<mk.VideoParams>? _videoParamsSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<mk.PlayerLog>? _logSub;

  bool _surfaceSizeSent = false;
  int _sentWidth = 0;
  int _sentHeight = 0;
  bool _released = false;

  /// Set while [create] is in flight so a concurrent [dispose] can tell the
  /// difference between "never started" and "torn down mid-create".
  bool _creating = false;

  bool get isActive => !_released;

  /// Allocates the texture, configures libmpv and opens the media.
  ///
  /// Mirrors [NativePlayer._create] on Android: the caller has already decided
  /// that creation is wanted, and the texture id is the value that completes
  /// `_createdCompleter` so `create()` can return it.
  Future<void> create(String cdnUrl) async {
    if (_released || _owner._disposed) {
      throw StateError('NativePlayer was disposed during creation');
    }
    _creating = true;
    try {
      final surface = await _invokeSurface<Map<Object?, dynamic>>(
        'createSurface',
      );
      final textureId = surface?['textureId'];
      final surfaceId = surface?['surfaceId'];
      final handle = surface?['handle'];
      if (textureId is! int || surfaceId is! int || handle is! int) {
        throw StateError('OHOS surface reply was incomplete');
      }
      _surfaceHandle = handle;
      // `createSurface` allocates a 1x1 buffer. media_kit resizes it as soon
      // as the first `videoParams` arrives; keep this in place until then so
      // the texture is not shown as a full-screen black rectangle.
      _owner._textureId = textureId;

      // The [mk.Player] wrapper is deliberately dropped: its delegates
      // silently no-op when `platform` is null, which would hide a failed
      // platform dispatch, so the backend holds the native player itself.
        final platform = mk.Player(
          configuration: const mk.PlayerConfiguration(
            vo: 'gpu-next',
            protocolWhitelist: ohosProtocolWhitelist,
            // mpv 只把 >= warn 级别的日志转进 error 流；默认 error 太迟，
            // VO 初始化失败这类状态在 info 级别就打出来。
            logLevel: mk.MPVLogLevel.info,
          ),
        ).platform;
      if (platform is! mk.NativePlayer) {
        throw StateError('media_kit did not provide a native player');
      }
      _player = platform;

      // mpv 内部错误（VO/EGL/解码器）不经过 Dart 异常，只能从它的日志通道
      // 看到。log-file 让 libmpv 自己写文件（不依赖 Dart 的日志栈），落到
      // 应用私有 logs/ 目录，与 AppLog 的 app.log 并排，便于真机排障拉取。
      // 失败只损失这份诊断日志，不影响播放，所以静默降级。
      try {
        final support = await getApplicationSupportDirectory();
        await platform.setProperty(
          'log-file',
          '${support.path}/logs/mpv.log',
        );
      } catch (_) {}

      // media_kit's property table installs `ao=opensles` only on Android and
      // leaves the option unset elsewhere. This libmpv was built with every
      // other audio backend disabled (`-Dopensles=disabled -Dalsa=disabled
      // -Dpulse=disabled -Dopenal=disabled`), so the default probing fails and
      // playback is silent. The binary's AO description string is
      // "OHAudio audio output" and it links libohaudio.so, so the driver name
      // is `ohaudio` -- `ohos` was a guess that failed with
      // "Audio output ohos not found!" (mpv.log evidence).
      await platform.setProperty('ao', 'ohaudio');

      // Order is load-bearing. mpv's HarmonyOS video output refuses to
      // initialise without a surface id, so `vo` is dropped first, the surface
      // is attached, and only then is the video output switched back on. This
      // is the same sequence media_kit's own OHOS video controller uses.
      //
      // vo must be gpu-next with gpu-context=ohos. The gpu-context names for
      // this libmpv build are `ohos` (OpenGL via egl-ohos) and `ohosvk`
      // (Vulkan) -- the build feature string `egl-ohos` is NOT a context name.
      // Without opengl-es=yes + egl-output-format=rgba8 the EGL config
      // negotiation picks a pixel format that never matches the texture
      // window's buffer format and eglCreateWindowSurface fails with
      // EGL_BAD_MATCH forever. Same recipe as the official mpv-ohos/mpv-arkts
      // demo (vo=gpu-next, gpu-context=ohos, egl-output-format=rgba8).
      await platform.setProperty('vo', 'null');
      await platform.setProperty('ohos-surface-size', '1x1');
      await platform.setProperty('wid', surfaceId.toString());
      await platform.setProperty('vid', 'auto');
      await platform.setProperty('gpu-context', 'ohos');
      await platform.setProperty('opengl-es', 'yes');
      await platform.setProperty('egl-output-format', 'rgba8');
      await platform.setProperty('force-window', 'yes');
      await platform.setProperty('hwdec', 'ohcodec');
      await platform.setProperty('hwdec-codecs', 'h264,hevc,mpeg2video,mpeg4,h263,vvc');
      await platform.setProperty('hwdec-software-fallback', 'yes');
      await platform.setProperty('vd-lavc-ohos-smart-fluency', 'yes');
      await platform.setProperty('sub-use-margins', 'no');
      await platform.setProperty('sub-scale-with-window', 'no');
      await platform.setProperty('osd-font', 'HarmonyOS Sans SC');
      await platform.setProperty('vo', 'gpu-next');

      _subscribe(platform);

      await platform.open(
        mk.Media(
          cdnUrl,
          // Per-media options, applied from the `on_load` hook. The CENC key
          // is handed to FFmpeg's mov demuxer so it decrypts AES-CTR samples
          // using the container's senc/saio/saiz offsets; there is no local
          // decryption library to keep in step with on this platform.
          extras: {
            'demuxer-lavf-o': ohosDemuxerLavfOptions(
              protocolWhitelist: ohosProtocolWhitelist,
              contentKeyHex: _keyHex,
            ),
          },
        ),
        play: false,
      );

      if (_released || _owner._disposed) {
        await release();
        throw StateError('NativePlayer was disposed during creation');
      }

      // A synthetic `created` event, exactly the shape the Android host sends
      // over the event channel, so the rest of native_player.dart -- and every
      // consumer of `textureIdStream` -- behaves identically on both platforms.
      _owner._handleEvent({
        'type': 'created',
        'playerId': 0,
        'value': textureId,
      });
      _creating = false;
    } catch (error, stackTrace) {
      _creating = false;
      await release();
      _owner._handleChannelError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> play() => _run(() => _player?.play());

  Future<void> pause() => _run(() => _player?.pause());

  Future<void> seek(Duration position) => _run(
    () => _player?.seek(position),
    // media_kit reports position from the mpv property, which is already
    // authoritative once the seek command is acknowledged. Mirror the
    // ExoPlayer-side optimism so the progress bar does not snap back.
    onDone: () async {
      _owner._position = position;
      _owner._completed = false;
      if (!_owner._positionCtrl.isClosed) {
        _owner._positionCtrl.add(position);
      }
    },
  );

  Future<void> setVolume(double volume) => _run(
    () => _player?.setVolume(ohosVolume(volume)),
  );

  Future<void> setRate(double rate) => _run(() => _player?.setRate(rate));

  /// Awaits a media_kit call and folds any failure into the player's error
  /// path, matching how a native channel error surfaces.
  Future<void> _run(
    Future<void>? Function() action, {
    Future<void> Function()? onDone,
  }) async {
    if (_released || _owner._disposed) return;
    try {
      final pending = action();
      if (pending == null) return;
      await pending;
      await onDone?.call();
    } catch (error, stackTrace) {
      _owner._handleChannelError(error, stackTrace);
    }
  }

  void _subscribe(mk.NativePlayer player) {
    _positionSub = player.stream.position.listen((position) {
      if (_released) return;
      _owner._position = position;
      if (!_owner._positionCtrl.isClosed) {
        _owner._positionCtrl.add(position);
      }
    });
    _durationSub = player.stream.duration.listen((duration) {
      if (_released) return;
      // media_kit emits Duration.zero until mpv knows the length. Keep the
      // same "not known yet" semantics the Android host uses.
      if (duration.inMilliseconds <= 0) return;
      _owner._duration = duration;
      if (!_owner._durationCtrl.isClosed) {
        _owner._durationCtrl.add(duration);
      }
    });
    _playingSub = player.stream.playing.listen((playing) {
      if (_released) return;
      _owner._playing = playing;
      if (!_owner._playingCtrl.isClosed) _owner._playingCtrl.add(playing);
    });
    _completedSub = player.stream.completed.listen((completed) {
      if (_released) return;
      _owner._completed = completed;
      if (!_owner._completedCtrl.isClosed) {
        _owner._completedCtrl.add(completed);
      }
    });
    _bufferingSub = player.stream.buffering.listen((buffering) {
      if (_released) return;
      _owner._buffering = buffering;
      if (!_owner._bufferingCtrl.isClosed) {
        _owner._bufferingCtrl.add(buffering);
      }
    });
    _videoParamsSub = player.stream.videoParams.listen((params) {
      if (_released) return;
      final size = ohosDisplaySize(
        displayWidth: params.dw ?? 0,
        displayHeight: params.dh ?? 0,
        rotate: params.rotate ?? 0,
      );
      if (size.width <= 0 || size.height <= 0) return;
      final clamped = ohosClampSurface(
        width: size.width,
        height: size.height,
      );
      _owner._videoWidth = clamped.width;
      _owner._videoHeight = clamped.height;
      // mpv applies the container rotation before presenting, so there is
      // never anything left for the Flutter side to correct -- unlike the
      // Android host, where `textureChanged` has to reset this to 0 because the
      // legacy SurfaceTexture already applied the format rotation.
      _owner._videoRotationCorrection = 0;
      if (!_owner._videoSizeCtrl.isClosed) {
        _owner._videoSizeCtrl.add(
          Size(clamped.width.toDouble(), clamped.height.toDouble()),
        );
      }
      if (!_surfaceSizeSent ||
          _sentWidth != clamped.width ||
          _sentHeight != clamped.height) {
        _surfaceSizeSent = true;
        _sentWidth = clamped.width;
        _sentHeight = clamped.height;
        final handle = _surfaceHandle;
        if (handle != null) {
          // Best effort: the surface must be resized in step with the buffer,
          // and a stale size only costs scaling, not playback.
          _invokeSurface<void>('setSurfaceSize', {
            'handle': handle,
            'width': clamped.width,
            'height': clamped.height,
          }).ignore();
        }
        // Keep mpv's own idea of the surface geometry in sync with the buffer
        // resize, exactly like media_kit's controller does after
        // VideoOutputManager.SetSurfaceSize. Without this the EGL window
        // surface keeps the 1x1 geometry it negotiated at startup.
        _player
            ?.setProperty('ohos-surface-size',
                '${clamped.width}x${clamped.height}')
            .catchError((_) {});
      }
      if (!_owner._firstFrameRendered) {
        _owner._firstFrameRendered = true;
        if (!_owner._firstFrameCtrl.isClosed) {
          _owner._firstFrameCtrl.add(true);
        }
      }
    });
    _errorSub = player.stream.error.listen((error) {
      if (_released) return;
      _owner._handleChannelError(
        NativePlaybackException(error),
        StackTrace.current,
      );
    });
    // mpv 的 VO/解码器初始化状态只出现在 log 流（error 流只收 error 级别）。
    // 转进 AppLog，让真机日志页/落盘文件能看到「mpv 卡在哪一步」。
    _logSub = player.stream.log.listen((log) {
      if (_released) return;
      AppLog.d('mpv', '${log.prefix}: ${log.text}');
    });
  }

  /// Tears down the mpv instance and the platform texture.
  ///
  /// Safe to call more than once, and safe to call while [create] is still in
  /// flight -- in that case the in-flight work is abandoned rather than awaited.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    final player = _player;
    _player = null;
    for (final sub in [
      _positionSub,
      _durationSub,
      _playingSub,
      _completedSub,
      _bufferingSub,
      _videoParamsSub,
      _errorSub,
      _logSub,
    ]) {
      await sub?.cancel();
    }
    _positionSub = null;
    _durationSub = null;
    _playingSub = null;
    _completedSub = null;
    _bufferingSub = null;
    _videoParamsSub = null;
    _errorSub = null;
    _logSub = null;
    final handle = _surfaceHandle;
    _surfaceHandle = null;
    if (handle != null) {
      // The plugin answers unknown handles with success, so this stays correct
      // even if the surface was already disposed.
      await _invokeSurface<void>('disposeSurface', {'handle': handle});
    }
    if (player != null && !_creating) {
      // media_kit defers `mpv_terminate_destroy` by five seconds; that timer
      // would keep the test isolate alive, so it is only awaited when this is a
      // normal shutdown. During a create-time abort the player has not been
      // initialised far enough to need it.
      try {
        await player.dispose();
      } catch (_) {
        // A player that failed to initialise has nothing to tear down.
      }
    }
    _owner._textureId = null;
  }

  /// Invokes a method on the surface channel.
  ///
  /// Unlike [NativePlayer._invoke], this does not send a player id: the ArkTS
  /// plugin keys its surfaces by its own handle. `_channel` and
  /// `_methodTimeout` are private to the library, which is what makes this a
  /// part file rather than a helper of its own.
  Future<T?> _invokeSurface<T>(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) {
    return NativePlayer.channel
        .invokeMethod<T>(method, arguments)
        .timeout(NativePlayer.methodTimeout);
  }
}
