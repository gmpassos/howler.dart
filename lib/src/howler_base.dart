/*!
 *  howler.dart (howlerjs.com v2.2.0)
 *
 *  (c) 2013-2020, Graciliano M. Passos, James Simpson of GoldFire Studios
 *  https://github.com/gmpassos/howler.dart
 *
 *  MIT License
 */

import 'dart:async';
import 'dart:convert' show base64;
import 'dart:html';
import 'dart:typed_data';
import 'dart:web_audio';

import 'package:swiss_knife/swiss_knife.dart';

typedef _SimpleCall = void Function();

void _doCall(_SimpleCall call) {
  if (call != null) {
    try {
      call();
    } catch (e, s) {
      print(e);
      print(s);
    }
  }
}

/// Detects initial user interaction and flushes calls waiting this state.
/// By: Graciliano M. Passos - Jul/2020
class _DetectUserInteraction {
  static bool _interactionDetected = false;

  static bool get interactionDetected => _interactionDetected;

  static void callAfterDetection(_SimpleCall call) {
    if (interactionDetected) {
      try {
        call();
      } catch (e, s) {
        print(e);
        print(s);
      }
    } else {
      detect();
      _toCallOnDetection.add(call);
    }
  }

  static final List<_SimpleCall> _toCallOnDetection = [];

  static List<StreamSubscription> _listeners;

  static void detect() {
    if (_listeners != null || _interactionDetected) return;

    var listeners = <StreamSubscription>[];

    // Need to track window focus:
    // if user changes window/tab (loses focus), any interaction should
    // be ignored until regain focus.
    listeners.add(window.onFocus.listen(_onFocus));
    listeners.add(window.onBlur.listen(_onBlur));

    // Interaction is defined only on Up/End events.
    // Events like KeyDown or MouseDown won't set "user interacted"
    // status in the browser.
    listeners.add(window.onMouseUp.listen(_onInteraction));
    listeners.add(window.onTouchEnd.listen(_onInteraction));
    listeners.add(window.onKeyUp.listen(_onInteraction));

    _listeners = listeners;
  }

  static void cancelDetection() {
    var listeners = _listeners;
    _listeners = null;

    if (listeners != null) {
      listeners.forEach((s) => s.cancel());
    }
  }

  static bool _focus = true;

  static void _onFocus(dynamic event) {
    _focus = true;
  }

  static void _onBlur(dynamic event) {
    _focus = false;
  }

  static void _onInteraction(dynamic event) {
    if (_interactionDetected) {
      return;
    }

    Future.delayed(Duration(milliseconds: 100), _setInteractionDetectedImpl);
  }

  static void setInteractionDetected() => _setInteractionDetectedImpl(true);

  static void _setInteractionDetectedImpl([bool force = false]) {
    if (!_focus && !force) {
      return;
    }

    _interactionDetected = true;
    cancelDetection();

    Future.delayed(Duration(milliseconds: 10), _flushCalls);
  }

  static void _flushCalls() {
    for (var call in _toCallOnDetection) {
      _doCall(call);
    }

    _toCallOnDetection.clear();
  }
}

class _HowlerGlobal {
  // Create a global ID counter.
  int _counter = 1000;

  // Pool of unlocked HTML5 Audio objects.
  final List _html5AudioPool = [];
  int html5PoolSize = 10;

  // Internal properties.
  Map<String, bool> _codecs = {};
  final List<Howl> _howls = [];
  bool _muted = false;
  double _volume = 1;
  final String _canPlayEvent = 'canplaythrough';

  GainNode masterGain;
  bool noAudio = false;
  bool usingWebAudio = true;
  bool autoSuspend = true;
  AudioContext ctx;
  String state;

  // Set to false to disable the auto audio unlocker.
  bool autoUnlock = true;

  Navigator _navigator;

  String get userAgent => _navigator != null ? _navigator.userAgent : '';

  bool _ios;

  bool get isIOS => _ios;

  _HowlerGlobal() {
    _navigator = window.navigator;

    _ios = _calcIsIOS();

    // Setup the various state values for global tracking.
    _setup();
  }

  bool _calcIsIOS() {
    return _navigator.vendor.contains('Apple') &&
        RegExp(r'iP(?:hone|ad|od)').hasMatch(_navigator.platform);
  }

  /// Get/set the global volume for all sounds.
  /// @param  {Float} vol Volume from 0.0 to 1.0.
  /// @return {Howler/Float}     Returns current volume.
  double volume([double vol]) {
    // If we don't have an AudioContext created yet, run the setup.
    if (ctx == null) {
      _setupAudioContext();
    }

    if (vol != null && vol >= 0 && vol <= 1) {
      _volume = vol;

      // Don't update any of the nodes if we are muted.
      if (_muted) {
        return _volume;
      }

      // When using Web Audio, we just need to adjust the master gain.
      if (usingWebAudio) {
        masterGain.gain.setValueAtTime(vol, Howler.ctx.currentTime);
      }

      // Loop through and change volume for all HTML5 audio nodes.
      for (var i = 0; i < _howls.length; i++) {
        if (!_howls[i]._webAudio) {
          // Get all of the sounds in this Howl group.
          var ids = _howls[i]._getSoundIds();

          // Loop through all sounds and change the volumes.
          for (var j = 0; j < ids.length; j++) {
            var sound = _howls[i]._soundById(ids[j]);

            if (sound != null && sound._node != null) {
              sound._node.audio.volume = sound._volume * vol;
            }
          }
        }
      }
    }

    return _volume;
  }

  /// Handle muting and unmuting globally.
  /// @param  {Boolean} muted Is muted or not.
  _HowlerGlobal mute(bool muted) {
    // If we don't have an AudioContext created yet, run the setup.
    if (ctx == null) {
      _setupAudioContext();
    }

    _muted = muted;

    // With Web Audio, we just need to mute the master gain.
    if (usingWebAudio) {
      masterGain.gain
          .setValueAtTime(muted ? 0 : _volume, Howler.ctx.currentTime);
    }

    // Loop through and mute all HTML5 Audio nodes.
    for (var i = 0; i < _howls.length; i++) {
      if (!_howls[i]._webAudio) {
        // Get all of the sounds in this Howl group.
        var ids = _howls[i]._getSoundIds();

        // Loop through all sounds and mark the audio node as muted.
        for (var j = 0; j < ids.length; j++) {
          var sound = _howls[i]._soundById(ids[j]);

          if (sound != null && sound._node != null) {
            sound._node.audio.muted = (muted) ? true : sound._muted;
          }
        }
      }
    }

    return this;
  }

  /// Handle stopping all sounds globally.
  /// @return {Howler}
  _HowlerGlobal stop() {
    // Loop through all Howls and stop them.
    for (var i = 0; i < _howls.length; i++) {
      _howls[i].stop(null);
    }
    return this;
  }

  /// Unload and destroy all currently loaded Howl objects.
  /// @return {Howler}
  _HowlerGlobal unload() {
    for (var i = _howls.length - 1; i >= 0; i--) {
      _howls[i].unload();
    }

    // Create a new AudioContext to make sure it is fully reset.
    if (usingWebAudio && ctx != null && ctx.close != null) {
      ctx.close();
      ctx = null;
      _setupAudioContext();
    }

    return this;
  }

  /// Check for codec support of specific extension.
  /// @param  {String} ext Audio file extention.
  /// @return {bool}
  bool codecs(String ext) {
    ext = ext.replaceAll(RegExp('^x-'), '');
    return _codecs[ext];
  }

  /// Setup various state values for global tracking.
  /// @return {Howler}
  _HowlerGlobal _setup() {
    // Keeps track of the suspend/resume state of the AudioContext.
    state = ctx != null ? ctx.state : null;
    state ??= 'suspended';

    // Automatically begin the 30-second suspend process
    _autoSuspend();

    // Check if audio is available.
    if (!usingWebAudio) {
      // No audio is available on this system if noAudio is set to true.
      try {
        AudioElement();
      } catch (e) {
        noAudio = true;
        print('** NO AUDIO AVAILABLE!');
      }
    }

    // Test to make sure audio isn't disabled in Internet Explorer.
    try {
      var test = AudioElement();
      if (test.muted) {
        noAudio = true;
      }
      // ignore: empty_catches
    } catch (e) {}

    // Check for supported codecs.
    if (!noAudio) {
      _setupCodecs();
    }

    return this;
  }

  /// Check for browser support for various codecs and cache the results.
  /// @return {Howler}
  _HowlerGlobal _setupCodecs() {
    AudioElement audioTest;

    // Must wrap in a try/catch because IE11 in server mode throws an error.
    try {
      audioTest = AudioElement();
    } catch (err) {
      return this;
    }

    if (audioTest == null) return this;

    var mpegTest = canPlayType(audioTest, 'audio/mpeg;');

    _codecs = {
      'mp3': (mpegTest || canPlayType(audioTest, 'audio/mp3;')),
      'mpeg': mpegTest,
      'opus': canPlayType(audioTest, 'audio/ogg; codecs="opus"'),
      'ogg': canPlayType(audioTest, 'audio/ogg; codecs="vorbis"'),
      'oga': canPlayType(audioTest, 'audio/ogg; codecs="vorbis"'),
      'wav': canPlayType(audioTest, 'audio/wav; codecs="1"'),
      'aac': canPlayType(audioTest, 'audio/aac;'),
      'caf': canPlayType(audioTest, 'audio/x-caf;'),
      'm4a': canPlayType(audioTest, 'audio/x-m4a;') ||
          canPlayType(audioTest, 'audio/m4a;') ||
          canPlayType(audioTest, 'audio/aac;'),
      'm4b': canPlayType(audioTest, 'audio/x-m4b;') ||
          canPlayType(audioTest, 'audio/m4b;') ||
          canPlayType(audioTest, 'audio/aac;'),
      'mp4': canPlayType(audioTest, 'audio/x-mp4;') ||
          canPlayType(audioTest, 'audio/mp4;') ||
          canPlayType(audioTest, 'audio/aac;'),
      'weba': canPlayType(audioTest, 'audio/webm; codecs="vorbis"'),
      'webm': canPlayType(audioTest, 'audio/webm; codecs="vorbis"'),
      'dolby': canPlayType(audioTest, 'audio/mp4; codecs="ec-3"'),
      'flac': canPlayType(audioTest, 'audio/x-flac;') ||
          canPlayType(audioTest, 'audio/flac;')
    };

    return this;
  }

  static bool canPlayType(AudioElement audioTest, String type) {
    var canPlayType = audioTest.canPlayType('audio/mp3;');
    if (canPlayType == null || canPlayType.isEmpty) return false;
    canPlayType = canPlayType.toLowerCase();
    return canPlayType != 'no';
  }

  bool _audioUnlocked = false;
  bool _mobileUnloaded = false;
  AudioBuffer _scratchBuffer;

  /// Some browsers/devices will only allow audio to be played after a user interaction.
  /// Attempt to automatically unlock audio on the first user interaction.
  /// Concept from: http://paulbakaus.com/tutorials/html5/web-audio-on-ios/
  /// @return {Howler}
  _HowlerGlobal _unlockAudio() {
    // Only run this if Web Audio is supported and it hasn't already been unlocked.
    if (_audioUnlocked || ctx != null) {
      return this;
    }

    _audioUnlocked = false;
    autoUnlock = false;

    // Some mobile devices/platforms have distortion issues when opening/closing tabs and/or web views.
    // Bugs in the browser (especially Mobile Safari) can cause the sampleRate to change from 44100 to 48000.
    // By calling Howler.unload(), we create a new AudioContext with the correct sampleRate.
    if (!_mobileUnloaded && ctx.sampleRate != 44100) {
      _mobileUnloaded = true;
      unload();
    }

    // Scratch buffer for enabling iOS to dispose of web audio buffers correctly, as per:
    // http://stackoverflow.com/questions/24119684
    _scratchBuffer = ctx.createBuffer(1, 1, 22050);

    // Setup a touch start listener to attempt an unlock in.
    document.addEventListener('touchstart', _unlock, true);
    document.addEventListener('touchend', _unlock, true);
    document.addEventListener('click', _unlock, true);

    return this;
  }

  // Call this method on touch start to create and play a buffer,
  // then check if the audio actually played to determine if
  // audio has now been unlocked on iOS, Android, etc.
  void _unlock(e) {
    // Create a pool of unlocked HTML5 Audio objects that can
    // be used for playing sounds without user interaction. HTML5
    // Audio objects must be individually unlocked, as opposed
    // to the WebAudio API which only needs a single activation.
    // This must occur before WebAudio setup or the source.onended
    // event will not fire.
    while (_html5AudioPool.length < html5PoolSize) {
      try {
        var audioNode = _HowlAudioNode.audio(AudioElement());
        // Mark this Audio object as unlocked to ensure it can get returned
        // to the unlocked pool when released.
        audioNode._unlocked = true;

        // Add the audio node to the pool.
        _releaseHtml5Audio(audioNode);
      } catch (e) {
        noAudio = true;
        break;
      }
    }

    // Loop through any assigned audio nodes and unlock them.
    for (var i = 0; i < _howls.length; i++) {
      if (!_howls[i]._webAudio) {
        // Get all of the sounds in this Howl group.
        var ids = _howls[i]._getSoundIds();

        // Loop through all sounds and unlock the audio nodes.
        for (var j = 0; j < ids.length; j++) {
          var sound = _howls[i]._soundById(ids[j]);

          if (sound != null && sound._node != null && !sound._node._unlocked) {
            sound._node._unlocked = true;
            sound._node.audio.load();
          }
        }
      }
    }

    // Fix Android can not play in suspend state.
    _autoResume();

    // Create an empty buffer.
    var source = ctx.createBufferSource();
    source.buffer = _scratchBuffer;
    source.connectNode(ctx.destination);

    // Play the empty buffer.
    source.start(0);

    // Calling resume() on a stack initiated by user gesture is what actually unlocks the audio on Android Chrome >= 55.
    ctx.resume();

    // Setup a timeout to check that we are unlocked on the next event loop.

    source.onEnded.listen((e) {
      source.disconnect(0);

      // Update the unlocked state and prevent this check from happening again.
      _audioUnlocked = true;

      // Remove the touch start listener.
      document.removeEventListener('touchstart', _unlock, true);
      document.removeEventListener('touchend', _unlock, true);
      document.removeEventListener('click', _unlock, true);

      // Let all sounds know that audio has been unlocked.
      for (var i = 0; i < _howls.length; i++) {
        _howls[i]._emit('unlock');
      }
    });
  }

  /// Get an unlocked HTML5 Audio object from the pool. If none are left,
  /// return a new Audio object and throw a warning.
  /// @return {Audio} HTML5 Audio object.
  AudioElement _obtainHtml5Audio() {
    // Return the next object from the pool if one exists.
    if (_html5AudioPool.isNotEmpty) {
      return _html5AudioPool.removeLast();
    }

    //.Check if the audio is locked and throw a warning.
    var testPlay = AudioElement().play();

    if (testPlay != null) {
      testPlay.catchError((_) {
        window.console.warn(
            'HTML5 Audio pool exhausted, returning potentially locked audio object.');
      });
    }

    return AudioElement();
  }

  /// Return an activated HTML5 Audio object to the pool.
  /// @return {Howler}
  _HowlerGlobal _releaseHtml5Audio(_HowlAudioNode audio) {
    // Don't add audio to the pool if we don't know if it has been unlocked.
    if (audio._unlocked) {
      _html5AudioPool.add(audio);
    }

    return this;
  }

  Timer _suspendTimer;
  bool _resumeAfterSuspend = false;

  /// Automatically suspend the Web Audio AudioContext after no sound has played for 30 seconds.
  /// This saves processing/energy and fixes various browser-specific bugs with audio getting stuck.
  /// @return {Howler}
  _HowlerGlobal _autoSuspend() {
    if (!autoSuspend || ctx == null || !Howler.usingWebAudio) {
      return this;
    }

    // Check if any sounds are playing.
    for (var i = 0; i < _howls.length; i++) {
      if (_howls[i]._webAudio) {
        for (var j = 0; j < _howls[i]._sounds.length; j++) {
          if (!_howls[i]._sounds[j]._paused) {
            return this;
          }
        }
      }
    }

    if (_suspendTimer != null) {
      _suspendTimer.cancel();
      _suspendTimer = null;
    }

    _suspendTimer = Timer(Duration(seconds: 30), () {
      if (!autoSuspend) return;

      _suspendTimer = null;
      state = 'suspending';

      // Handle updating the state of the audio context after suspending.
      var handleSuspension = () {
        state = 'suspended';

        if (_resumeAfterSuspend) {
          _resumeAfterSuspend = false;
          _autoResume();
        }
      };

      ctx.suspend().then((_) {
        handleSuspension();
      }, onError: (_) {
        handleSuspension();
      });
    });

    return this;
  }

  /// Automatically resume the Web Audio AudioContext when a new sound is played.
  /// @return {Howler}
  _HowlerGlobal _autoResume() {
    if (ctx == null || !Howler.usingWebAudio) {
      return this;
    }

    if (state == 'running' &&
        ctx.state != 'interrupted' &&
        _suspendTimer != null) {
      _suspendTimer.cancel();
      _suspendTimer = null;
    } else if (state == 'suspended' ||
        state == 'running' && ctx.state == 'interrupted') {
      ctx.resume().then((_) {
        state = 'running';

        // Emit to all Howls that the audio has resumed.
        for (var i = 0; i < _howls.length; i++) {
          _howls[i]._emit('resume');
        }
      });

      if (_suspendTimer != null) {
        _suspendTimer.cancel();
        _suspendTimer = null;
      }
    } else if (state == 'suspending') {
      _resumeAfterSuspend = true;
    }

    return this;
  }
}

final _HowlerGlobal Howler = _HowlerGlobal();

typedef HowlEventListener = Function(
    Howl howl, String eventType, int id, String message);

class _HowlEventListenerWrapper {
  final int id;
  final HowlEventListener function;
  final bool once;

  _HowlEventListenerWrapper(this.function, [this.id, this.once = false]);
}

class _HowlSrc {
  List<String> _srcs;

  _HowlSrc.value(String src) {
    _srcs = [src];
  }

  _HowlSrc.list(this._srcs) {
    _srcs ??= [];
  }

  int get length => _srcs.length;

  String operator [](int index) => _srcs[index];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _HowlSrc &&
          runtimeType == other.runtimeType &&
          isEquivalentList(_srcs, other._srcs);

  int _hashcode;

  @override
  int get hashCode {
    if (_hashcode == null) {
      var h = 0;
      for (var s in _srcs) {
        h = h * 31 + s.hashCode;
      }
      _hashcode = h;
    }

    return _hashcode;
  }

  @override
  String toString() {
    return _srcs.toString();
  }
}

class _HowlSpriteParams {
  int from;
  int to;
  bool loop;

  _HowlSpriteParams(this.from, this.to, [this.loop = false]);

  _HowlSpriteParams.list(List params) {
    from = int.parse(params[0].toString());
    to = int.parse(params[1].toString());

    if (params.length <= 2) {
      loop = false;
    } else {
      var loopStr = params[2].toString().toLowerCase();
      loop = loopStr == 'true' || loopStr == '1';
    }
  }

  static Map<String, _HowlSpriteParams> toMapOfSpritesParams(
      Map<String, List> map) {
    var sprites = <String, _HowlSpriteParams>{};

    for (var entry in map.entries) {
      var key = entry.key;
      var spriteParams = _HowlSpriteParams.list(entry.value);
      sprites[key] = spriteParams;
    }

    return sprites;
  }
}

class _HowlCall {
  final String event;
  final Function action;

  _HowlCall(this.event, this.action);
}

class Howl {
  bool _autoplay;
  List<String> _format;
  bool _html5;
  bool _muted;
  bool _loop;
  int _pool;
  bool _preload;
  double _rate;
  Map<String, _HowlSpriteParams> _sprite;
  _HowlSrc _src;
  double _volume;

  String _xhrMethod;
  bool _xhrWithCredentials;
  Map<String, String> _xhrHeaders;

  double _duration;
  String _state;
  List<Sound> _sounds;
  Map<int, dynamic> _endTimers;
  List<_HowlCall> _queue;
  bool _playLock;

  // Setup event listeners.
  List<_HowlEventListenerWrapper> _onend;
  List<_HowlEventListenerWrapper> _onfade;
  List<_HowlEventListenerWrapper> _onload;
  List<_HowlEventListenerWrapper> _onloaderror;
  List<_HowlEventListenerWrapper> _onplayerror;
  List<_HowlEventListenerWrapper> _onpause;
  List<_HowlEventListenerWrapper> _onplay;
  List<_HowlEventListenerWrapper> _onstop;
  List<_HowlEventListenerWrapper> _onmute;
  List<_HowlEventListenerWrapper> _onvolume;
  List<_HowlEventListenerWrapper> _onrate;
  List<_HowlEventListenerWrapper> _onseek;
  List<_HowlEventListenerWrapper> _onunlock;
  List<_HowlEventListenerWrapper> _onresume;

  List<_HowlEventListenerWrapper> _getEventListeners(String eventType) {
    switch (eventType) {
      case 'end':
        return _onend;
      case 'fade':
        return _onfade;
      case 'load':
        return _onload;
      case 'loaderror':
        return _onloaderror;
      case 'playerror':
        return _onplayerror;
      case 'pause':
        return _onpause;
      case 'play':
        return _onplay;
      case 'stop':
        return _onstop;
      case 'mute':
        return _onmute;
      case 'volume':
        return _onvolume;
      case 'rate':
        return _onrate;
      case 'seek':
        return _onseek;
      case 'unlock':
        return _onunlock;
      case 'resume':
        return _onresume;
      default:
        return null;
    }
  }

  bool _webAudio;

  Howl(
      {List<String> src,
      bool autoplay = false,
      List<String> format,
      bool html5 = false,
      bool mute = false,
      bool loop = false,
      int pool = 5,
      bool preload = true,
      double rate = 1,
      Map<String, List> sprite,
      double volume = 1,
      String xhrMethod = 'GET',
      bool xhrWithCredentials = false,
      Map<String, String> xhrHeaders,
      HowlEventListener onend,
      HowlEventListener onfade,
      HowlEventListener onload,
      HowlEventListener onloaderror,
      HowlEventListener onplayerror,
      HowlEventListener onpause,
      HowlEventListener onplay,
      HowlEventListener onstop,
      HowlEventListener onmute,
      HowlEventListener onvolume,
      HowlEventListener onrate,
      HowlEventListener onseek,
      HowlEventListener onunlock,
      HowlEventListener onresume}) {
    _DetectUserInteraction.detect();

    if (src == null || src.isEmpty) {
      window.console
          .error('An array of source files must be passed with any new Howl.');
      return;
    }

    // If we don't have an AudioContext created yet, run the setup.
    if (Howler.ctx == null) {
      _setupAudioContext();
    }

    // Setup user-defined default properties.
    _autoplay = autoplay;
    _format = format ?? [];
    _html5 = html5;
    _muted = mute;
    _loop = loop;
    _pool = pool;
    _preload = preload;
    _rate = rate;
    _sprite =
        sprite != null ? _HowlSpriteParams.toMapOfSpritesParams(sprite) : {};
    _src = _HowlSrc.list(src);
    _volume = volume;

    xhrMethod = (xhrMethod ?? 'GET').trim().toUpperCase();
    _xhrMethod = xhrMethod.isNotEmpty ? xhrMethod : 'GET';

    _xhrWithCredentials = xhrWithCredentials;
    _xhrHeaders = xhrHeaders;

    // Setup all other default properties.
    _duration = 0;
    _state = 'unloaded';
    _sounds = [];
    _endTimers = {};
    _queue = [];
    _playLock = false;

    // Setup event listeners.
    _onend = onend != null ? [_HowlEventListenerWrapper(onend)] : [];
    _onfade = onfade != null ? [_HowlEventListenerWrapper(onfade)] : [];
    _onload = onload != null ? [_HowlEventListenerWrapper(onload)] : [];
    _onloaderror =
        onloaderror != null ? [_HowlEventListenerWrapper(onloaderror)] : [];
    _onplayerror =
        onplayerror != null ? [_HowlEventListenerWrapper(onplayerror)] : [];
    _onpause = onpause != null ? [_HowlEventListenerWrapper(onpause)] : [];
    _onplay = onplay != null ? [_HowlEventListenerWrapper(onplay)] : [];
    _onstop = onstop != null ? [_HowlEventListenerWrapper(onstop)] : [];
    _onmute = onmute != null ? [_HowlEventListenerWrapper(onmute)] : [];
    _onvolume = onvolume != null ? [_HowlEventListenerWrapper(onvolume)] : [];
    _onrate = onrate != null ? [_HowlEventListenerWrapper(onrate)] : [];
    _onseek = onseek != null ? [_HowlEventListenerWrapper(onseek)] : [];
    _onunlock = onunlock != null ? [_HowlEventListenerWrapper(onunlock)] : [];
    _onresume = [];

    // Web Audio or HTML5 Audio?
    _webAudio = Howler.usingWebAudio && !_html5;

    // Automatically try to enable audio.
    if (Howler.ctx != null && Howler.autoUnlock) {
      Howler._unlockAudio();
    }

    // Keep track of this Howl group in the global controller.
    Howler._howls.add(this);

    // If they selected autoplay, add a play event to the load queue.
    if (_autoplay) {
      _queue.add(_HowlCall('play', () => play()));
    }

    // Load the source file unless otherwise specified.
    if (_preload) {
      _loadImpl();
    }
  }

  List<int> get soundIDs => List.from(_sounds.map((s) => s._id));

  @override
  String toString() {
    return 'Howl{ playing: ${playing()}, status: ${state()}, src: $_src, sounds: $_sounds}';
  }

  /// Calls [load] than [play] and [callback] when load event happens.
  /// If [this] is already loaded, [play] and [callback] are called immediately.
  Howl loadAndPlay({dynamic sprite, bool safe = true, _SimpleCall callback}) {
    safe ??= true;

    if (isLoaded) {
      load();

      if (safe) {
        playSafe(sprite: sprite, callback: callback);
      } else {
        play(sprite);
        _doCall(callback);
      }
    } else {
      once('load', (howl, eventType, id, message) {
        if (safe) {
          playSafe(sprite: sprite, callback: callback);
        } else {
          play(sprite);
          _doCall(callback);
        }
      });

      load();
    }

    return this;
  }

  bool get isLoaded => _state == 'loaded';

  /// Load the audio file.
  ///
  /// [callback] Optional callback for when the 'load' event happens. If this is already loaded, it's called immediately.
  /// @return {Howler}
  Howl load([_SimpleCall callback]) {
    if (callback == null) {
      _loadImpl();
    } else if (isLoaded) {
      _loadImpl();
      _doCall(callback);
    } else {
      once('load', (howl, eventType, id, message) {
        _doCall(callback);
      });
      _loadImpl();
    }

    return this;
  }

  void _loadImpl() {
    String url;

    // If no audio is available, quit immediately.
    if (Howler.noAudio) {
      _emit('loaderror', null, 'No audio support.');
      return;
    }

    // Loop through the sources and pick the first one that is compatible.
    for (var i = 0; i < _src.length; i++) {
      String ext, src;

      if (_format != null && i < _format.length && _format[i] != null) {
        // If an extension was specified, use that instead.
        ext = _format[i];
      } else {
        // Make sure the source is a string.
        src = _src[i];
        if (src == null) {
          _emit('loaderror', null,
              'Non-string found in selected audio sources - ignoring.');
          continue;
        }

        var match = RegExp(r'^data:audio/([^;,]+);', caseSensitive: false)
            .firstMatch(src);
        ext = match != null ? match.group(1) : null;

        if (ext == null || ext.isEmpty) {
          var url = split(src, '?', 1)[0];
          var match = RegExp(r'\.([^.]+)$').firstMatch(url);
          ext = match != null ? match.group(1) : null;
        }

        if (ext != null) {
          ext = ext.toLowerCase();
        }
      }

      // Log a warning if no extension was found.
      if (ext == null) {
        window.console.warn(
            'No file extension was found. Consider using the "format" property or specify an extension.');
      }

      // Check if this extension is available.
      if (ext != null && Howler.codecs(ext)) {
        url = _src[i];
        break;
      }
    }

    if (url == null) {
      _emit('loaderror', null, 'No codec support for selected audio sources.');
      return;
    }

    _src = _HowlSrc.value(url);
    _state = 'loading';

    // If the hosting page is HTTPS and the source isn't,
    // drop down to HTML5 Audio to avoid Mixed Content errors.
    if (window.location.protocol == 'https:' &&
        url.substring(0, 5) == 'http:') {
      _html5 = true;
      _webAudio = false;
    }

    // Create a new sound object and add it to the pool.
    Sound(this);

    // Load and decode the audio data for playback.
    if (_webAudio) {
      _loadBuffer();
    }
  }

  /// Forces initialization of user interaction detection.
  static void detectUserInitialInteraction() {
    _DetectUserInteraction.detect();
  }

  /// Forces the detection status of initial user interaction.
  static void setUserInitialInteractionDetected() {
    _DetectUserInteraction.setInteractionDetected();
  }

  /// Returns [true] if the initial user interaction was already detected.
  static bool get userInitialInteractionDetected {
    _DetectUserInteraction.detect();
    return _DetectUserInteraction.interactionDetected;
  }

  /// Same as [play], but checks for users interaction first.
  ///
  /// If user hasn't interacted yet, this call will be put in a queue to be
  /// flushed when interaction is detected.
  int playSafe({dynamic sprite, bool internal = false, _SimpleCall callback}) {
    if (userInitialInteractionDetected) {
      var id = play(sprite, internal);
      _doCall(callback);
      return id;
    } else {
      _DetectUserInteraction.callAfterDetection(() {
        play(sprite, internal);
        _doCall(callback);
      });
      return null;
    }
  }

  /// Play a sound or resume previous playback.
  /// @param  {String/Number} sprite   Sprite name for sprite playback or sound id to continue previous.
  /// @param  {Boolean} internal Internal Use: true prevents event firing.
  /// @return {Number}          Sound ID.
  int play([dynamic sprite, bool internal = false]) {
    int id;

    if (sprite == null) {
      // Use the default sound sprite (plays the full audio length).
      sprite = '__default';

      // Check if there is a single paused sound that isn't ended.
      // If there is, play that sound. If not, continue as usual.
      if (!_playLock) {
        var num = 0;
        for (var i = 0; i < _sounds.length; i++) {
          if (_sounds[i]._paused && !_sounds[i]._ended) {
            num++;
            id = _sounds[i]._id;
          }
        }

        if (num == 1) {
          sprite = null;
        } else {
          id = null;
        }
      }
    }
    // Determine if a sprite, sound ID or nothing was passed
    else if (sprite is int) {
      id = sprite;
      sprite = null;
    } else if (sprite is String &&
        _state == 'loaded' &&
        _sprite[sprite] == null) {
      // If the passed sprite doesn't exist, do nothing.
      return null;
    }

    // Get the selected node, or get one from the pool.
    var sound = id != null ? _soundById(id) : _inactiveSound();

    // If the sound doesn't exist, do nothing.
    if (sound == null) {
      return null;
    }

    // Select the sprite definition.
    if (id != null && sprite == null) {
      sprite = sound._sprite;
      sprite ??= '__default';
    }

    // If the sound hasn't loaded, we must wait to get the audio's duration.
    // We also need to wait to make sure we don't run into race conditions with
    // the order of function calls.
    if (_state != 'loaded') {
      // Set the sprite value on this sound.
      sound._sprite = sprite;

      // Mark this sound as not ended in case another sound is played before this one loads.
      sound._ended = false;

      // Add the sound to the queue to be played on load.
      var soundId = sound._id;

      _queue.add(_HowlCall('play', () {
        play(soundId);
      }));

      return soundId;
    }

    // Don't play the sound if an id was passed and it is already playing.
    if (id != null && !sound._paused) {
      // Trigger the play event, in order to keep iterating through queue.
      if (!internal) {
        _loadQueue('play');
      }

      return sound._id;
    }

    // Make sure the AudioContext isn't suspended, and resume it if it is.
    if (_webAudio) {
      Howler._autoResume();
    }

    // Determine how long to play for and where to start playing.
    var seek = Math.max(
        0, sound._seek > 0 ? sound._seek : _sprite[sprite].from / 1000);
    var duration = Math.max(
        0, ((_sprite[sprite].from + _sprite[sprite].to) / 1000) - seek);
    var timeout = (duration * 1000) ~/ sound._rate.abs();

    var start = _sprite[sprite].from / 1000;
    var stop = (_sprite[sprite].from + _sprite[sprite].to) / 1000;

    sound._sprite = sprite;

    // Mark the sound as ended instantly so that this async playback
    // doesn't get grabbed by another call to play while this one waits to start.
    sound._ended = false;

    // Update the parameters of the sound.
    var setParams = () {
      sound._paused = false;
      sound._seek = seek;
      sound._start = start;
      sound._stop = stop;

      var loop = sound._loop;
      if (!loop) {
        var spriteConf = _sprite[sprite];
        loop = spriteConf.loop;
      }

      sound._loop = loop;
    };

    // End the sound instantly if seek is at the end.
    if (seek >= stop) {
      _ended(sound);
      return null;
    }

    // Begin the actual playback.
    var node = sound._node;

    if (_webAudio) {
      // Fire this when the sound is ready to play to begin Web Audio playback.
      HowlEventListener playWebAudio = (h, t, id, m) {
        _playLock = false;
        setParams();
        _refreshBuffer(sound);

        // Setup the playback params.
        var vol = (sound._muted || _muted) ? 0 : sound._volume;
        node.gainNode.gain.setValueAtTime(vol, Howler.ctx.currentTime);
        sound._playStart = Howler.ctx.currentTime;

        sound._loop
            ? node.bufferSource.start(0, seek, 86400)
            : node.bufferSource.start(0, seek, duration);

        // Start a new timer if none is present.
        if (timeout > 0 && timeout < 100000000) {
          _endTimers[sound._id] =
              Timer(Duration(milliseconds: timeout), () => _ended(sound));
        }

        if (!internal) {
          Timer(Duration.zero, () {
            _emit('play', sound._id);
            _loadQueue();
          });
        }
      };

      if (Howler.state == 'running' && Howler.ctx.state != 'interrupted') {
        playWebAudio(this, 'play', sound._id, null);
      } else {
        _playLock = true;

        // Wait for the audio context to resume before playing.
        once('resume', playWebAudio, null);

        // Cancel the end timer.
        _clearTimer(sound._id);
      }
    } else {
      // Fire this when the sound is ready to play to begin HTML5 Audio playback.
      var playHtml5 = () {
        node.audio.currentTime = seek;
        node.audio.muted =
            sound._muted || _muted || Howler._muted || node.audio.muted;
        node.audio.volume = sound._volume * Howler.volume();
        node.audio.playbackRate = sound._rate;

        // Some browsers will throw an error if this is called without user interaction.
        try {
          var play = node.audio.play();

          if (play != null) {
            // Implements a lock to prevent DOMException: The play() request was interrupted by a call to pause().
            _playLock = true;

            // Set param values immediately.
            setParams();

            // Releases the lock and executes queued actions.
            play.then((_) {
              _playLock = false;
              node._unlocked = true;

              if (!internal) {
                _emit('play', sound._id);
                _loadQueue();
              }
            }).catchError(() {
              _playLock = false;
              _emit(
                  'playerror',
                  sound._id,
                  'Playback was unable to start. This is most commonly an issue '
                      'on mobile devices and Chrome where playback was not within a user interaction.');

              // Reset the ended and paused values.
              sound._ended = true;
              sound._paused = true;
            });
          } else if (!internal) {
            _playLock = false;
            setParams();
            _emit('play', sound._id);
            _loadQueue();
          }

          // Setting rate before playing won't work in IE, so we set it again here.
          node.audio.playbackRate = sound._rate;

          // If the node is still paused, then we can assume there was a playback issue.
          if (node.audio.paused) {
            _emit(
                'playerror',
                sound._id,
                'Playback was unable to start. This is most commonly an issue '
                    'on mobile devices and Chrome where playback was not within a user interaction.');
            return;
          }

          // Setup the end timer on sprites or listen for the ended event.
          if (sprite != '__default' || sound._loop) {
            _endTimers[sound._id] = Timer(Duration(milliseconds: timeout), () {
              _ended(sound);
            });
          } else {
            _endTimers[sound._id] = (e) {
              // Fire ended on this audio node.
              _ended(sound);

              // Clear this listener.
              _clearTimer(sound._id);
            };

            node.eventTarget
                .addEventListener('ended', _endTimers[sound._id], false);
          }
        } catch (err) {
          _emit('playerror', sound._id, err);
        }
      };

      // If this is streaming audio, make sure the src is set and load again.
      if (node.src ==
          'data:audio/wav;base64,UklGRigAAABXQVZFZm10IBIAAAABAAEARKwAAIhYAQACABAAAABkYXRhAgAAAAEA') {
        node.src = _src[0];
        node.load();
      }

      // Play immediately if ready, or wait for the 'canplaythrough'e vent.
      if (node.audio.readyState >= 3) {
        playHtml5();
      } else {
        _playLock = true;

        // Cancel the end timer.
        _clearTimer(sound._id);

        EventListener listener = (e) {
          // Begin playback.
          playHtml5();

          // Clear this listener.
          _clearTimer(sound._id);
        };

        node.eventTarget
            .addEventListener(Howler._canPlayEvent, listener, false);
      }
    }

    return sound._id;
  }

  /// A simple play/pause switch.
  ///
  /// If [this] is currently [playing], it will [pause] the sound,
  /// otherwise it will [play].
  bool playOrPauseSwitch([int id]) {
    if (playing(id)) {
      pause();
      return false;
    } else {
      play();
      return true;
    }
  }

  /// Pause playback and save current position.
  /// @param  {Number} id The sound ID (empty to pause all in group).
  /// @return {Howl}
  Howl pause([int id, bool internal = false]) {
    // If the sound hasn't loaded or a play() promise is pending, add it to the load queue to pause when capable.
    if (_state != 'loaded' || _playLock) {
      _queue.add(_HowlCall('pause', () => pause(id)));
      return this;
    }

    // If no id is passed, get all ID's to be paused.
    var ids = _getSoundIds(id);

    for (var i = 0; i < ids.length; i++) {
      var id2 = ids[i];
      _clearTimer(id2);

      // Get the sound.
      var sound = _soundById(id2);

      if (sound != null && !sound._paused) {
        // Reset the seek position.
        sound._seek = getSeek(id2);
        sound._rateSeek = 0;
        sound._paused = true;

        // Stop currently running fades.
        _stopFade(id2);

        if (sound._node != null) {
          if (_webAudio) {
            // Make sure the sound has been created.
            if (sound._node.bufferSource == null) {
              continue;
            }

            sound._node.bufferSource.stop(0);

            // Clean up the buffer source.
            _cleanBuffer(sound._node);
          } else if (!sound._node.audio.duration.isNaN ||
              sound._node.audio.duration.isInfinite) {
            sound._node.audio.pause();
          }
        }
      }

      // Fire the pause event, unless `true` is passed as the 2nd argument.
      if (!internal) {
        _emit('pause', sound != null ? sound._id : null);
      }
    }

    return this;
  }

  Howl stopAll() {
    stopIDs(soundIDs);
    return this;
  }

  Howl stopIDs(List<int> ids) {
    for (var id in ids) {
      stop(id);
    }
    return this;
  }

  /// Stop playback and reset to start.
  /// @param  {Number} id The sound ID (empty to stop all in group).
  /// @param  {Boolean} internal Internal Use: true prevents event firing.
  /// @return {Howl}
  Howl stop(int id, [bool internal = false]) {
    // If the sound hasn't loaded, add it to the load queue to stop when capable.
    if (_state != 'loaded' || _playLock) {
      _queue.add(_HowlCall('stop', () => stop(id)));
      return this;
    }

    // If no id is passed, get all ID's to be stopped.
    var ids = _getSoundIds(id);

    for (var i = 0; i < ids.length; i++) {
      // Clear the end timer.
      _clearTimer(ids[i]);

      // Get the sound.
      var sound = _soundById(ids[i]);

      if (sound != null) {
        // Reset the seek position.
        sound._seek = sound._start;
        sound._rateSeek = 0;
        sound._paused = true;
        sound._ended = true;

        // Stop currently running fades.
        _stopFade(ids[i]);

        if (sound._node != null) {
          if (_webAudio) {
            // Make sure the sound's AudioBufferSourceNode has been created.
            if (sound._node.bufferSource != null) {
              sound._node.bufferSource.stop(0);

              // Clean up the buffer source.
              _cleanBuffer(sound._node);
            }
          } else if (!sound._node.audio.duration.isNaN ||
              sound._node.audio.duration.isInfinite) {
            sound._node.audio.currentTime = sound._start;
            sound._node.audio.pause();

            // If this is a live stream, stop download once the audio is stopped.
            if (sound._node.isInfinityDuration) {
              _clearSound(sound._node);
            }
          }
        }

        if (!internal) {
          _emit('stop', sound._id);
        }
      }
    }

    return this;
  }

  /// Mute/unmute a single sound or all sounds in this Howl group.
  /// @param  {Boolean} muted Set to true to mute and false to unmute.
  /// @param  {Number} id    The sound ID to update (omit to mute/unmute all).
  /// @return {Howl}
  Howl mute(bool muted, [int id]) {
    // If the sound hasn't loaded, add it to the load queue to mute when capable.
    if (_state != 'loaded' || _playLock) {
      _queue.add(_HowlCall('mute', () => mute(muted, id)));

      return this;
    }

    // If applying mute/unmute to all sounds, update the group's value.
    if (id == null) {
      if (muted != null) {
        _muted = muted;
      } else {
        return this;
      }
    }

    // If no id is passed, get all ID's to be muted.
    var ids = _getSoundIds(id);

    for (var i = 0; i < ids.length; i++) {
      // Get the sound.
      var sound = _soundById(ids[i]);

      if (sound != null) {
        sound._muted = muted;

        // Cancel active fade and set the volume to the end value.
        if (sound._interval != null) {
          _stopFade(sound._id);
        }

        if (_webAudio && sound._node != null) {
          sound._node.gainNode.gain.setValueAtTime(
              muted ? 0 : sound._volume, Howler.ctx.currentTime);
        } else if (sound._node != null) {
          sound._node.audio.muted = Howler._muted ? true : muted;
        }

        _emit('mute', sound._id);
      }
    }

    return this;
  }

  /// Get the volume of this sound or of the Howl group. This method can optionally take 0or 1 argument.
  ///   getVolume() -> Returns the group's volume value.
  ///   getVolume(id) -> Returns the sound id's current volume.
  /// @return {double} Returns current volume.
  double getVolume([int id]) {
    // Determine the values based on arguments.
    if (id == null) {
      // Return the value of the groups' volume.
      return _volume;
    } else {
      var sound = _soundById(id);
      return sound != null ? sound._volume : 0;
    }
  }

  /// Get/set the volume of this sound or of the Howl group. This method can optionally take 0, 1 or 2 arguments.
  ///   volume() -> Returns the group's volume value.
  ///   volume(id) -> Returns the sound id's current volume.
  ///   volume(vol) -> Sets the volume of all sounds in this Howl group.
  ///   volume(vol, id) -> Sets the volume of passed sound id.
  /// @return {Howl} Returns this.
  Howl setVolume(double vol, [int id, bool internal = false]) {
    if (vol == null || vol < 0 || vol > 1) return this;

    // If the sound hasn't loaded, add it to the load queue to change volume when capable.
    if (_state != 'loaded' || _playLock) {
      _queue.add(_HowlCall('volume', () => setVolume(vol, id)));
      return this;
    }

    // Set the group volume.
    if (id == null) {
      _volume = vol;
    }

    // Update one or all volumes.
    var ids = _getSoundIds(id);

    for (var i = 0; i < ids.length; i++) {
      var id2 = ids[i];
      var sound = _soundById(id2);

      if (sound != null) {
        sound._volume = vol;

        // Stop currently running fades.
        if (!internal) {
          _stopFade(id2);
        }

        if (_webAudio && sound._node != null && !sound._muted) {
          sound._node.gainNode.gain.setValueAtTime(vol, Howler.ctx.currentTime);
        } else if (sound._node != null && !sound._muted) {
          sound._node.audio.volume = vol * Howler.volume();
        }

        _emit('volume', sound._id);
      }
    }

    return this;
  }

  /// Same as [fade], but checks for users interaction 1st.
  ///
  /// If user hasn't interacted yet, this call will be put in a queue to be
  /// flushed when interaction is detected.
  Howl fadeSafe(double from, double to, int len,
      {int id, _SimpleCall callback}) {
    if (userInitialInteractionDetected) {
      fade(from, to, len, id);
      _doCall(callback);
    } else {
      _DetectUserInteraction.callAfterDetection(() {
        fade(from, to, len, id);
        _doCall(callback);
      });
    }
    return this;
  }

  /// Fade a currently playing sound between two volumes (if no id is passed, all sounds will fade).
  /// @param  {Number} from The value to fade from (0.0 to 1.0).
  /// @param  {Number} to   The volume to fade to (0.0 to 1.0).
  /// @param  {Number} len  Time in milliseconds to fade.
  /// @param  {Number} id   The sound id (omit to fade all sounds).
  /// @return {Howl}
  Howl fade(double from, double to, int len, [int id]) {
    // If the sound hasn't loaded, add it to the load queue to fade when capable.
    if (_state != 'loaded' || _playLock) {
      _queue.add(_HowlCall('fade', () => fade(from, to, len, id)));
      return this;
    }

    from = _clip(from, 0.0, 1.0);
    to = _clip(to, 0.0, 1.0);

    // Set the volume to the start position.
    setVolume(from, id);

    // Fade the volume of one or all sounds.
    var ids = _getSoundIds(id);

    for (var i = 0; i < ids.length; i++) {
      // Get the sound.
      var sound = _soundById(ids[i]);

      // Create a linear fade or fall back to timeouts with HTML5 Audio.
      if (sound != null) {
        // Stop the previous fade if no sprite is being used (otherwise, volume handles this).
        if (id == null) {
          _stopFade(ids[i]);
        }

        // If we are using Web Audio, let the native methods do the actual fade.
        if (_webAudio && !sound._muted) {
          var currentTime = Howler.ctx.currentTime;
          var end = currentTime + (len / 1000);
          sound._volume = from;
          sound._node.gainNode.gain.setValueAtTime(from, currentTime);
          sound._node.gainNode.gain.linearRampToValueAtTime(to, end);
        }

        _startFadeInterval(sound, from, to, len, ids[i], id == null);
      }
    }

    return this;
  }

  double _clip(double n, double min, double max) {
    if (n < min) {
      return min;
    } else if (n > max) {
      return max;
    } else {
      return n;
    }
  }

  /// Starts the internal interval to fade a sound.
  /// @param  {Object} sound Reference to sound to fade.
  /// @param  {Number} from The value to fade from (0.0 to 1.0).
  /// @param  {Number} to   The volume to fade to (0.0 to 1.0).
  /// @param  {Number} len  Time in milliseconds to fade.
  /// @param  {Number} id   The sound id to fade.
  /// @param  {Boolean} isGroup   If true, set the volume on the group.
  void _startFadeInterval(
      Sound sound, double from, double to, int len, id, isGroup) {
    var vol = from;
    var diff = to - from;
    var steps = (diff / 0.01).abs();
    var stepLen = Math.max(4, (steps > 0) ? len ~/ steps : len);
    var lastTick = DateTime.now().millisecondsSinceEpoch;

    // Store the value being faded to.
    sound._fadeTo = to;

    // Update the volume value on each interval tick.

    sound._interval = Timer.periodic(Duration(milliseconds: stepLen), (t) {
      // Update the volume based on the time since the last tick.
      var now = DateTime.now().millisecondsSinceEpoch;

      var tick = (now - lastTick) / len;
      lastTick = now;
      vol += diff * tick;

      // Make sure the volume is in the right bounds.
      if (diff < 0) {
        vol = Math.max(to, vol);
      } else {
        vol = Math.min(to, vol);
      }

      // Round to within 2 decimal points.
      vol = (vol * 100).round() / 100;

      // Change the volume.
      if (_webAudio) {
        sound._volume = vol;
      } else {
        setVolume(vol, sound._id, true);
      }

      // Set the group's volume.
      if (isGroup) {
        _volume = vol;
      }

      // When the fade is complete, stop it and fire event.
      if ((to < from && vol <= to) || (to > from && vol >= to)) {
        if (sound._interval != null) {
          sound._interval.cancel();
          sound._interval = null;
        }

        sound._fadeTo = null;

        setVolume(to, sound._id);
        _emit('fade', sound._id);
      }
    });
  }

  /// Internal method that stops the currently playing fade when
  /// a new fade starts, volume is changed or the sound is stopped.
  /// @param  {Number} id The sound id.
  /// @return {Howl}
  void _stopFade(int id) {
    var sound = _soundById(id);

    if (sound != null && sound._interval != null) {
      if (_webAudio) {
        sound._node.gainNode.gain.cancelScheduledValues(Howler.ctx.currentTime);
      }

      sound._interval.cancel();
      sound._interval = null;

      setVolume(sound._fadeTo, id);
      sound._fadeTo = null;

      _emit('fade', id);
    }
  }

  /// Get the loop parameter on a sound. This method can optionally take 0, 1 or 2 arguments.
  ///   getLoop() -> Returns the group's loop value.
  ///   getLoop(id) -> Returns the sound id's loop value.
  /// @return {Boolean} Returns current loop value.
  bool getLoop([int id]) {
    // Determine the values for loop and id.
    if (id == null) {
      // Return the grou's loop value.
      return _loop;
    } else {
      var sound = _soundById(id);
      return sound != null ? sound._loop : false;
    }
  }

  /// Set the loop parameter on a sound. This method can optionally take 0, 1 or 2 arguments.
  ///   setLoop(loop) -> Sets the loop value for all sounds in this Howl group.
  ///   setLoop(loop, id) -> Sets the loop value of passed sound id.
  /// @return {Howl} Returns this.
  Howl setLoop(bool loop, [int id]) {
    if (id == null) {
      _loop = loop;
    }

    // If no id is passed, get all ID's to be looped.
    var ids = _getSoundIds(id);

    for (var i = 0; i < ids.length; i++) {
      var sound = _soundById(ids[i]);

      if (sound != null) {
        sound._loop = loop;

        if (_webAudio &&
            sound._node != null &&
            sound._node.bufferSource != null) {
          sound._node.bufferSource.loop = loop;

          if (loop) {
            sound._node.bufferSource.loopStart = sound._start;
            sound._node.bufferSource.loopEnd = sound._stop;
          }
        }
      }
    }

    return this;
  }

  /// Get the playback rate of a sound. This method can optionally take 0, 1 or 2 arguments.
  ///   getRate() -> Returns the first sound node's current playback rate.
  ///   getRate(id) -> Returns the sound id's current playback rate.
  /// @return {double} Returns the current playback rate.
  double getRate([int id]) {
    // Determine the values based on arguments.
    // We will simply return the current rate of the first node.
    id ??= _sounds[0]._id;

    var sound = _soundById(id);
    return sound != null ? sound._rate : _rate;
  }

  /// Set the playback rate of a sound. This method can optionally take 0, 1 or 2 arguments.
  ///   setRate(rate) -> Sets the playback rate of all sounds in this Howl group.
  ///   setRate(rate, id) -> Sets the playback rate of passed sound id.
  /// @return {Howl} Returns this.
  Howl setRate(double rate, [int id]) {
    // If the sound hasn't loaded, add it to the load queue to change playback rate when capable.
    if (_state != 'loaded' || _playLock) {
      _queue.add(_HowlCall('rate', () => setRate(rate, id)));

      return this;
    }

    // Set the group rate.
    if (id == null) {
      _rate = rate;
    }

    // Update one or all volumes.
    var ids = _getSoundIds(id);

    for (var i = 0; i < ids.length; i++) {
      var id2 = ids[i];
      var sound = _soundById(id2);

      if (sound != null) {
        // Keep track of our position when the rate changed and update the playback
        // start position so we can properly adjust the seek position for time elapsed.
        if (playing(id2)) {
          sound._rateSeek = getSeek(id2);
          sound._playStart =
              _webAudio ? Howler.ctx.currentTime : sound._playStart;
        }
        sound._rate = rate;

        // Change the playback rate.
        if (_webAudio &&
            sound._node != null &&
            sound._node.bufferSource != null) {
          sound._node.bufferSource.playbackRate
              .setValueAtTime(rate, Howler.ctx.currentTime);
        } else if (sound._node != null) {
          sound._node.audio.playbackRate = rate;
        }

        // Reset the timers.
        var seek = getSeek(id2);
        var duration =
            ((_sprite[sound._sprite].from + _sprite[sound._sprite].to) / 1000) -
                seek;
        var timeout = (duration * 1000) ~/ sound._rate.abs();

        // Start a new end timer if sound is already playing.
        if (_endTimers[id2] != null || !sound._paused) {
          _clearTimer(id2);

          Timer(Duration(milliseconds: timeout), () {
            _ended(sound);
          });
        }

        _emit('rate', sound._id);
      }
    }

    return this;
  }

  /// Get the seek position of a sound. This method can optionally take 0, 1 or 2 arguments.
  ///   getSeek() -> Returns the first sound node's current seek position.
  ///   getSeek(id) -> Returns the sound id's current seek position.
  /// @return {double} Returns the current seek position.
  double getSeek([int id]) {
    // Determine the values based on arguments.
    // We will simply return the current position of the first node.
    id ??= _sounds[0]._id;

    // If there is no ID, bail out.
    if (id == null) return null;

    // If the sound hasn't loaded, add it to the load queue to seek when capable.
    if (_state != 'loaded' || _playLock) {
      return null;
    }

    // Get the sound.
    var sound = _soundById(id);

    if (sound != null) {
      if (_webAudio) {
        double realTime =
            playing(id) ? Howler.ctx.currentTime - sound._playStart : 0;
        var rateSeek = sound._rateSeek != null && sound._rateSeek > 0
            ? sound._rateSeek - sound._seek
            : 0;
        return sound._seek + (rateSeek + realTime * sound._rate.abs());
      } else {
        return sound._node.audio.currentTime;
      }
    }

    return null;
  }

  /// Set the seek position of a sound. This method can optionally take 0, 1 or 2 arguments.
  ///   setSeek(seek) -> Sets the seek position of the first sound node.
  ///   setSeek(seek, id) -> Sets the seek position of passed sound id.
  /// @return {Howl} Returns this.
  Howl setSeek(double seek, [int id]) {
    // Determine the values based on arguments.
    id ??= _sounds[0]._id;

    // If there is no ID, bail out.
    if (id == null) return this;

    // If the sound hasn't loaded, add it to the load queue to seek when capable.
    if (_state != 'loaded' || _playLock) {
      _queue.add(_HowlCall('seek', () => setSeek(seek, id)));
      return this;
    }

    // Get the sound.
    var sound = _soundById(id);

    if (sound != null) {
      // Pause the sound and update position for restarting playback.
      var playing = this.playing(id);
      if (playing) {
        pause(id, true);
      }

      // Move the position of the track and cancel timer.
      sound._seek = seek;
      sound._ended = false;
      _clearTimer(id);

      // Update the seek position for HTML5 Audio.
      if (!_webAudio &&
          sound._node != null &&
          !sound._node.audio.duration.isNaN) {
        sound._node.audio.currentTime = seek;
      }

      // Seek and emit when ready.
      var seekAndEmit = () {
        _emit('seek', id);

        // Restart the playback if the sound was playing.
        if (playing) {
          play(id, true);
        }
      };

      // Wait for the play lock to be unset before emitting (HTML5 Audio).
      if (playing && !_webAudio) {
        Timer.periodic(Duration.zero, (t) {
          if (!_playLock) {
            seekAndEmit();
            t.cancel();
          }
        });
      } else {
        seekAndEmit();
      }
    }

    return this;
  }

  /// Check if a specific sound is currently playing or not (if id is provided), or check if at least one of the sounds in the group is playing or not.
  /// @param  {Number}  id The sound id to check. If none is passed, the whole sound group is checked.
  /// @return {Boolean} True if playing and false if not.
  bool playing([int id]) {
    // Check the passed sound ID (if any).
    if (id != null) {
      var sound = _soundById(id);
      return sound != null ? !sound._paused : false;
    }

    // Otherwise, loop through all sounds and check if any are playing.
    for (var i = 0; i < _sounds.length; i++) {
      if (!_sounds[i]._paused) {
        return true;
      }
    }

    return false;
  }

  /// Get the duration of this sound. Passing a sound id will return the sprite duration.
  /// @param  {Number} id The sound id to check. If none is passed, return full source duration.
  /// @return {Number} Audio duration in seconds.
  double duration([int id]) {
    if (id == null) {
      return _duration;
    }

    // If we pass an ID, get the sound and return the sprite length.
    var sound = _soundById(id);

    if (sound != null) {
      return _sprite[sound._sprite].to / 1000;
    } else {
      return _duration;
    }
  }

  /// Returns the current loaded state of this Howl.
  /// @return {String} 'unloaded', 'loading', 'loaded'
  String state() => _state;

  /// Unload and destroy the current Howl object.
  /// This will immediately stop all sound instances attached to this group.
  void unload() {
    // Stop playing any active sounds.
    var sounds = _sounds;

    for (var i = 0; i < sounds.length; i++) {
      var sound = sounds[i];
      // Stop the sound if it is currently playing.
      if (!sound._paused) {
        stop(sound._id);
      }

      // Remove the source or disconnect.
      if (!_webAudio) {
        _clearSound(sounds[i]._node);

        // Remove any event listeners.
        sound._node.eventTarget
            .removeEventListener('error', sound._errorFn, false);
        sound._node.eventTarget
            .removeEventListener(Howler._canPlayEvent, sound._loadFn, false);

        // Release the Audio object back to the pool.
        Howler._releaseHtml5Audio(sound._node);
      }

      // Empty out all of the nodes.
      sounds[i]._node = null;

      // Make sure all timers are cleared out.
      _clearTimer(sound._id);
    }

    // Remove the references in the global Howler object.
    var index = Howler._howls.indexOf(this);
    if (index >= 0) {
      Howler._howls.removeAt(index);
    }

    // Delete this sound from the cache (if no other Howl is using it).
    var remCache = true;

    for (var i = 0; i < Howler._howls.length; i++) {
      if (Howler._howls[i]._src == _src) {
        remCache = false;
        break;
      }
    }

    if (remCache) {
      _cache.remove(_src);
    }

    // Clear global errors.
    Howler.noAudio = false;

    // Clear out `this`.
    _state = 'unloaded';
    _sounds = [];

    return null;
  }

  /// Listen to a custom event.
  /// @param  {String}   event Event name.
  /// @param  {Function} fn    Listener to call.
  /// @param  {Number}   id    (optional) Only listen to events for this sound.
  /// @param  {Number}   once  (INTERNAL) Marks event to fire only once.
  /// @return {Howl}
  Howl on(String eventType, HowlEventListener function,
      [int id, bool once = false]) {
    var events = _getEventListeners(eventType);
    var listener = _HowlEventListenerWrapper(function, id, once);
    events.add(listener);
    return this;
  }

  /// Remove a custom event. Call without parameters to remove all events.
  /// @param  {String}   event Event name.
  /// @param  {Function} fn    Listener to remove. Leave empty to remove all.
  /// @param  {Number}   id    (optional) Only remove events for this sound.
  /// @return {Howl}
  Howl off(String eventType, [int id, HowlEventListener function]) {
    var events = _getEventListeners(eventType);
    var i = 0;

    if (id != null) {
      // Loop through event store and remove the passed function.
      for (i = 0; i < events.length; i++) {
        var isId = (id == events[i].id);

        if (isId && (function == null || function == events[i].function)) {
          events.removeAt(i);
          break;
        }
      }
    } else {
      // Clear out all events of this type.
      events.clear();
    }

    return this;
  }

  Howl offAll() {
    _onend.clear();
    _onfade.clear();
    _onload.clear();
    _onloaderror.clear();
    _onplayerror.clear();
    _onpause.clear();
    _onplay.clear();
    _onstop.clear();
    _onmute.clear();
    _onvolume.clear();
    _onrate.clear();
    _onseek.clear();
    _onunlock.clear();
    _onresume.clear();

    return this;
  }

  /// Listen to a custom event and remove it once fired.
  /// @param  {String}   event Event name.
  /// @param  {Function} fn    Listener to call.
  /// @param  {Number}   id    (optional) Only listen to events for this sound.
  /// @return {Howl}
  Howl once(String event, HowlEventListener function, [int id]) {
    on(event, function, id, true);
    return this;
  }

  final Map<_HowlSrc, AudioBuffer> _cache = {};

  /// Buffer a sound from URL, Data URI or cache and decode to audio source (Web Audio API).
  /// @param  {Howl} this
  void _loadBuffer() {
    var url = _src[0];

    // Check if the buffer has already been cached and use it instead.
    var audioBuffer = _cache[url];

    if (audioBuffer != null) {
      // Set the duration from the cache.
      _duration = audioBuffer.duration;

      // Load the sound into this Howl.
      _loadSound(audioBuffer);

      return;
    }

    if (RegExp(r'^data:[^;]+;base64,').hasMatch(url)) {
      // Decode the base64 data URI without XHR, since some browsers don't support it.
      var base64Data = split(url, ',', 1)[1];
      var dataView = base64.decode(base64Data);
      _decodeAudioData(dataView.buffer);
    } else {
      HttpRequest.request(
        url,
        method: _xhrMethod,
        withCredentials: _xhrWithCredentials,
        requestHeaders: _xhrHeaders,
        responseType: 'arraybuffer',
      ).then((xhr) {
        // Make sure we get a successful response back.
        var code = xhr.status;
        if (code < 200 || code >= 400) {
          _emit('loaderror', null,
              'Failed loading audio file with status: $code');
          return;
        }

        _decodeAudioData(xhr.response);
      }, onError: (e) {
        // If there is an error, switch to HTML5 Audio.
        if (_webAudio) {
          _html5 = true;
          _webAudio = false;
          _sounds = [];
          _cache.remove(url);
          _loadImpl();
        }
      });
    }
  }

  /// Decode audio data from an array buffer.
  /// @param  {ArrayBuffer} arraybuffer The audio data.
  /// @param  {Howl}        this
  void _decodeAudioData(ByteBuffer arraybuffer) {
    // Fire a load error if something broke.
    var error = (e) {
      _emit('loaderror', null, 'Decoding audio data failed.');
    };

    // Load the sound on success.
    //var success = ;

    Howler.ctx.decodeAudioData(arraybuffer).then((buffer) {
      if (buffer != null && _sounds.isNotEmpty) {
        _cache[_src] = buffer;
        _loadSound(buffer);
      } else {
        error(null);
      }
    }, onError: error);
  }

  /// Sound is now loaded, so finish setting everything up and fire the loaded event.
  /// @param  {Howl} this
  /// @param  {Object} buffer The decoded buffer sound source.
  void _loadSound(AudioBuffer buffer) {
    // Set the duration.
    if (buffer != null && (_duration == null || _duration == 0)) {
      _duration = buffer.duration;
    }

    // Setup a sprite if none is defined.
    if (_sprite.isEmpty) {
      _sprite = {'__default': _HowlSpriteParams(0, (_duration * 1000).floor())};
    }

    // Fire the loaded event.
    if (_state != 'loaded') {
      _state = 'loaded';
      _emit('load');
      _loadQueue();
    }
  }

  /// Emit all events of a specific type and pass the sound id.
  /// @param  {String} event Event name.
  /// @param  {Number} id    Sound ID.
  /// @param  {Number} msg   Message to go with event.
  /// @return {Howl}
  void _emit(String eventType, [int id, String msg]) {
    var events = _getEventListeners(eventType);
    List<_HowlEventListenerWrapper> offEvents;

    // Loop through event store and fire all functions.
    for (var i = events.length - 1; i >= 0; i--) {
      var evt = events[i];

      // Only fire the listener if the correct ID is used.
      if (evt.id == null || evt.id == id || eventType == 'load') {
        Timer(Duration.zero, () {
          evt.function(this, eventType, id, msg);
        });

        // If this event was setup with `once`, remove it.
        if (evt.once) {
          offEvents ??= [];
          offEvents.add(evt);
        }
      }
    }

    if (offEvents != null) {
      for (var evt in offEvents) {
        off(eventType, evt.id, evt.function);
      }
    }

    // Pass the event type into load queue so that it can continue stepping.
    _loadQueue(eventType);
  }

  /// Queue of actions initiated before the sound has loaded.
  /// These will be called in sequence, with the next only firing
  /// after the previous has finished executing (even if async like play).
  /// @return {Howl}
  void _loadQueue([String event]) {
    if (_queue.isNotEmpty) {
      var task = _queue[0];

      // Run the task if no event type is passed.
      if (event == null) {
        task.action();
      }
      // Remove this task if a matching event was passed.
      else if (task.event == event) {
        _queue.removeAt(0);
        _loadQueue();
      }
    }
  }

  /// Fired when playback ends at the end of the duration.
  /// @param  {Sound} sound The sound object to work with.
  /// @return {Howl}
  void _ended(Sound sound) {
    var sprite = sound._sprite;

    // If we are using IE and there was network latency we may be clipping
    // audio before it completes playing. Lets check the node to make sure it
    // believes it has completed, before ending the playback.
    if (!_webAudio &&
        sound._node != null &&
        !sound._node.audio.paused &&
        !sound._node.audio.ended &&
        sound._node.audio.currentTime < sound._stop) {
      Timer(Duration(milliseconds: 100), () {
        _ended(sound);
      });

      return;
    }

    // Should this sound loop?
    var loop = sound._loop || _sprite[sprite].loop;

    // Fire the ended event.
    _emit('end', sound._id);

    // Restart the playback for HTML5 Audio loop.
    if (!_webAudio && loop) {
      stop(sound._id, true).play(sound._id);
    }

    // Restart this timer if on a Web Audio loop.
    if (_webAudio && loop) {
      _emit('play', sound._id);
      sound._seek = sound._start;
      sound._rateSeek = 0;
      sound._playStart = Howler.ctx.currentTime;

      var timeout = ((sound._stop - sound._start) * 1000) ~/ sound._rate.abs();

      _endTimers[sound._id] = Timer(Duration(milliseconds: timeout), () {
        _ended(sound);
      });
    }

    // Mark the node as paused.
    if (_webAudio && !loop) {
      sound._paused = true;
      sound._ended = true;
      sound._seek = sound._start;
      sound._rateSeek = 0;
      _clearTimer(sound._id);

      // Clean up the buffer source.
      _cleanBuffer(sound._node);

      // Attempt to auto-suspend AudioContext if no sounds are still playing.
      Howler._autoSuspend();
    }

    // When using a sprite, end the track.
    if (!_webAudio && !loop) {
      stop(sound._id, true);
    }
  }

  /// Clear the end timer for a sound playback.
  /// @param  {Number} id The sound ID.
  /// @return {Howl}
  void _clearTimer(id) {
    var endTimer = _endTimers[id];

    if (endTimer != null) {
      // Clear the timeout or remove the ended listener.
      if (endTimer is Timer) {
        endTimer.cancel();
      } else {
        var sound = _soundById(id);
        if (sound != null && sound._node != null) {
          sound._node.eventTarget.removeEventListener('ended', endTimer, false);
        }
      }

      _endTimers.remove(id);
    }
  }

  /// Return the sound identified by this ID, or return null.
  /// @param  {Number} id Sound ID
  /// @return {Object}    Sound object or null.
  Sound _soundById(int id) {
    // Loop through all sounds and find the one with this ID.
    for (var i = 0; i < _sounds.length; i++) {
      var sound = _sounds[i];
      if (sound._id == id) return sound;
    }

    return null;
  }

  /// Return an inactive sound from the pool or create a new one.
  /// @return {Sound} Sound playback object.
  Sound _inactiveSound() {
    _drain();

    // Find the first inactive node to recycle.
    for (var i = 0; i < _sounds.length; i++) {
      var sound = _sounds[i];

      if (sound._ended) {
        return sound.reset();
      }
    }

    // If no inactive node was found, create a new one.
    return Sound(this);
  }

  /// Drain excess inactive sounds from the pool.
  void _drain() {
    var limit = _pool;
    var cnt = 0;

    // If there are less sounds than the max pool size, we are done.
    if (_sounds.length < limit) {
      return;
    }

    // Count the number of inactive sounds.
    for (var i = 0; i < _sounds.length; i++) {
      if (_sounds[i]._ended) {
        cnt++;
      }
    }

    // Remove excess inactive sounds, going in reverse order.
    for (var i = _sounds.length - 1; i >= 0; i--) {
      if (cnt <= limit) return;

      var sound = _sounds[i];

      if (sound._ended) {
        // Disconnect the audio source when using Web Audio.
        if (_webAudio &&
            sound._node != null &&
            sound._node.bufferSource != null) {
          sound._node.bufferSource.disconnect(0);
        }

        // Remove sounds until we have the pool size.
        _sounds.removeAt(i);
        cnt--;
      }
    }
  }

  /// Get all ID's from the sounds pool.
  /// @param  {Number} id Only return one ID if one is passed.
  /// @return {Array}    Array of IDs.
  List<int> _getSoundIds([int id]) {
    if (id == null) {
      var ids = <int>[];

      for (var i = 0; i < _sounds.length; i++) {
        ids.add(_sounds[i]._id);
      }

      return ids;
    } else {
      return [id];
    }
  }

  /// Load the sound back into the buffer source.
  /// @param  {Sound} sound The sound object to work with.
  /// @return {Howl}
  void _refreshBuffer(Sound sound) {
    // Setup the buffer source for playback.
    sound._node.bufferSource = Howler.ctx.createBufferSource();
    sound._node.bufferSource.buffer = _cache[_src];

    // Connect to the correct node.
    if (sound._panner != null) {
      sound._node.bufferSource.connectNode(sound._panner);
    } else {
      sound._node.bufferSource.connectNode(sound._node.gainNode);
    }

    // Setup looping and playback rate.
    sound._node.bufferSource.loop = sound._loop;
    if (sound._loop) {
      sound._node.bufferSource.loopStart = sound._start;
      sound._node.bufferSource.loopEnd = sound._stop;
    }
    sound._node.bufferSource.playbackRate
        .setValueAtTime(sound._rate, Howler.ctx.currentTime);
  }

  /// Prevent memory leaks by cleaning up the buffer source after playback.
  /// @param  {Object} node Sound's audio node containing the buffer source.
  /// @return {Howl}
  void _cleanBuffer(_HowlAudioNode node) {
    if (Howler._scratchBuffer != null && node.bufferSource != null) {
      //node.bufferSource.onEnded = null ; TODO
      node.bufferSource.disconnect(0);

      if (Howler.isIOS) {
        try {
          node.bufferSource.buffer = Howler._scratchBuffer;
          // ignore: empty_catches
        } catch (e) {}
      }
    }
    node.bufferSource = null;
  }

  /// Set the source to a 0-second silence to stop any downloading.
  /// @param  {Object} node Audio node to clear.
  void _clearSound(node) {
    node.src =
        'data:audio/wav;base64,UklGRigAAABXQVZFZm10IBIAAAABAAEARKwAAIhYAQACABAAAABkYXRhAgAAAAEA';
  }
}

class _HowlAudioNode {
  AudioElement audio;
  GainNode gainNode;

  AudioBufferSourceNode bufferSource;
  bool _unlocked;

  EventTarget get eventTarget => gainNode ?? audio;

  _HowlAudioNode.audio(this.audio);

  _HowlAudioNode.gain(this.gainNode);

  String get src => audio.src;

  set src(String src) => audio.src = src;

  num get duration => audio.duration;

  bool get isInfinityDuration {
    var duration = this.duration;
    return duration != null && duration.isInfinite;
  }

  void load() => audio.load();
}

class Sound {
  final Howl _parent;

  double _start = 0;
  double _stop = 0;

  double _volume;

  bool _paused;
  bool _ended;
  int _id;
  String _sprite;
  double _seek;
  double _rateSeek;
  double _rate;

  bool _loop;

  bool _muted;

  _HowlAudioNode _node;

  AudioNode _panner;

  Timer _interval;

  double _fadeTo;

  double _playStart;

  EventListener _loadFn;
  EventListener _errorFn;

  Sound(this._parent) {
    var parent = _parent;

    // Setup the default parameters.
    _muted = parent._muted;
    _loop = parent._loop;
    _volume = parent._volume;
    _rate = parent._rate;
    _seek = 0;
    _paused = true;
    _ended = true;
    _sprite = '__default';

    // Generate a unique ID for this sound.
    _id = ++Howler._counter;

    // Add itself to the parent's pool.
    parent._sounds.add(this);

    // Create the new node.
    create();
  }

  /// Create and setup a new sound object, whether HTML5 Audio or Web Audio.
  /// @return {Sound}
  Sound create() {
    var parent = _parent;
    var volume = (Howler._muted || _muted || _parent._muted) ? 0 : _volume;

    if (parent._webAudio) {
      // Create the gain node for controlling volume (the source will connect to this).
      _node = _HowlAudioNode.gain(Howler.ctx.createGain());

      _node.gainNode.gain.setValueAtTime(volume, Howler.ctx.currentTime);
      //this._node.gainNode.paused = true; TODO
      _node.gainNode.connectNode(Howler.masterGain);
    } else if (!Howler.noAudio) {
      // Get an unlocked Audio object from the pool.
      _node = _HowlAudioNode.audio(Howler._obtainHtml5Audio());

      // Listen for errors (http://dev.w3.org/html5/spec-author-view/spec.html#mediaerror).
      _errorFn = _errorListener;
      _node.audio.addEventListener('error', _errorFn, false);

      // Listen for 'canplaythrough' event to let us know the sound is ready.
      _loadFn = _loadListener;
      _node.audio.addEventListener(Howler._canPlayEvent, _loadFn, false);

      // Setup the new audio node.
      _node.audio.src = parent._src[0];
      _node.audio.preload = parent._preload ? 'auto' : 'none';
      _node.audio.volume = volume * Howler.volume();

      // Begin loading the source.
      _node.audio.load();
    }

    return this;
  }

  /// Reset the parameters of this sound to the original state (for recycle).
  /// @return {Sound}
  Sound reset() {
    var parent = _parent;

    // Reset all of the parameters of this sound.
    _muted = parent._muted;
    _loop = parent._loop;
    _volume = parent._volume;
    _rate = parent._rate;
    _seek = 0;
    _rateSeek = 0;
    _paused = true;
    _ended = true;
    _sprite = '__default';

    // Generate a new ID so that it isn't confused with the previous sound.
    _id = ++Howler._counter;

    return this;
  }

  /// HTML5 Audio error listener callback.
  void _errorListener(_) {
    // Fire an error event and pass back the code.
    _parent._emit('loaderror', _id,
        _node.audio.error != null ? _node.audio.error.code : '0');

    // Clear the event listener.
    _node.eventTarget.removeEventListener('error', _errorFn, false);
  }

  /// HTML5 Audio canplaythrough listener callback.
  void _loadListener(_) {
    var parent = _parent;

    // Round up the duration to account for the lower precision in HTML5 Audio.
    parent._duration = ((_node.audio.duration * 10) / 10).ceilToDouble();

    // Setup a sprite if none is defined.
    if (parent._sprite.isEmpty) {
      parent._sprite = {
        '__default': _HowlSpriteParams(0, (parent._duration * 1000).floor())
      };
    }

    if (parent._state != 'loaded') {
      parent._state = 'loaded';
      parent._emit('load');
      parent._loadQueue();
    }

    // Clear the event listener.
    _node.eventTarget.removeEventListener(Howler._canPlayEvent, _loadFn, false);
  }

  Howl get parent => _parent;

  @override
  String toString() {
    return 'Sound{id: $_id, sprite: $_sprite, volume: $_volume, paused: $_paused, loop: $_loop, muted: $_muted}';
  }

  double get start => _start;

  double get stop => _stop;

  double get volume => _volume;

  bool get paused => _paused;

  bool get ended => _ended;

  int get id => _id;

  String get sprite => _sprite;

  double get rate => _rate;

  bool get loop => _loop;

  bool get muted => _muted;

  double get playStart => _playStart;
}

/// Setup the audio context when available, or switch to HTML5 Audio mode.
void _setupAudioContext() {
  // If we have already detected that Web Audio isn't supported, don't run this step again.
  if (!Howler.usingWebAudio) return;

  // Check if we are using Web Audio and setup the AudioContext if we are.
  try {
    Howler.ctx = AudioContext();
  } catch (e) {
    Howler.usingWebAudio = false;
  }

  // If the audio context creation still failed, set using web audio to false.
  if (Howler.ctx == null) {
    Howler.usingWebAudio = false;
  }

  // Create and expose the master GainNode when using Web Audio (useful for plugins or advanced usage).
  if (Howler.usingWebAudio) {
    Howler.masterGain = Howler.ctx.createGain();
    Howler.masterGain.gain.setValueAtTime(
        Howler._muted ? 0 : Howler._volume, Howler.ctx.currentTime);
    Howler.masterGain.connectNode(Howler.ctx.destination);
  }

  // Re-run the setup on Howler.
  Howler._setup();
}
