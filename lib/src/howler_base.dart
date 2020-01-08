/*!
 *  howler.dart v1.0.0
 *  howlerjs.com
 *
 *  (c) 2013-2019, Graciliano M. Passos, James Simpson of GoldFire Studios
 *  https://github.com/gmpassos/howler.dart
 *
 *  MIT License
 */

import 'dart:async';
import 'dart:html';
import 'dart:typed_data';

import 'dart:web_audio';
import 'dart:convert' show base64;

import 'package:swiss_knife/swiss_knife.dart';

class _HowlerGlobal {
  // Create a global ID counter.
  int _counter = 1000;

  // Pool of unlocked HTML5 Audio objects.
  List _html5AudioPool = [];
  int html5PoolSize = 10;

  // Internal properties.
  Map<String,bool> _codecs = {};
  List<Howl> _howls = [];
  bool _muted = false;
  double _volume = 1;
  String _canPlayEvent = 'canplaythrough';

  GainNode masterGain ;
  bool noAudio = false;
  bool usingWebAudio = true;
  bool autoSuspend = true;
  AudioContext ctx ;
  String state ;

  // Set to false to disable the auto audio unlocker.
  bool autoUnlock = true;

  Navigator _navigator ;

  String get userAgent => _navigator != null ? _navigator.userAgent : "" ;

  bool _ios ;
  bool get isIOS => _ios ;

  _HowlerGlobal() {
    this._navigator = window.navigator ;

    this._ios = _calcIsIOS() ;

    // Setup the various state values for global tracking.
    this._setup();
  }

  bool _calcIsIOS() {
    return _navigator.vendor.contains('Apple') && new RegExp(r'iP(?:hone|ad|od)').hasMatch(_navigator.platform) ;
  }

  /// Get/set the global volume for all sounds.
  /// @param  {Float} vol Volume from 0.0 to 1.0.
  /// @return {Howler/Float}     Returns current volume.
  double volume([double vol]) {


    // If we don't have an AudioContext created yet, run the setup.
    if ( this.ctx == null ) {
      _setupAudioContext();
    }

    if (vol != null && vol >= 0 && vol <= 1) {
      this._volume = vol ;

      // Don't update any of the nodes if we are muted.
      if (this._muted) {
        return this._volume;
      }

      // When using Web Audio, we just need to adjust the master gain.
      if (this.usingWebAudio) {
        this.masterGain.gain.setValueAtTime(vol, Howler.ctx.currentTime);
      }

      // Loop through and change volume for all HTML5 audio nodes.
      for (var i=0; i<this._howls.length; i++) {
        if (!this._howls[i]._webAudio) {
          // Get all of the sounds in this Howl group.
          var ids = this._howls[i]._getSoundIds();

          // Loop through all sounds and change the volumes.
          for (var j=0; j<ids.length; j++) {
            Sound sound = this._howls[i]._soundById(ids[j]);

            if (sound != null && sound._node != null) {
              sound._node.audio.volume = sound._volume * vol;
            }
          }
        }
      }
    }

    return this._volume;
  }

  /// Handle muting and unmuting globally.
  /// @param  {Boolean} muted Is muted or not.
  _HowlerGlobal mute(bool muted) {


    // If we don't have an AudioContext created yet, run the setup.
    if ( this.ctx == null ) {
      _setupAudioContext();
    }

    this._muted = muted;

    // With Web Audio, we just need to mute the master gain.
    if (this.usingWebAudio) {
      this.masterGain.gain.setValueAtTime(muted ? 0 : this._volume, Howler.ctx.currentTime);
    }

    // Loop through and mute all HTML5 Audio nodes.
    for (var i=0; i<this._howls.length; i++) {
      if (!this._howls[i]._webAudio) {
        // Get all of the sounds in this Howl group.
        var ids = this._howls[i]._getSoundIds();

        // Loop through all sounds and mark the audio node as muted.
        for (var j=0; j<ids.length; j++) {
          Sound sound = this._howls[i]._soundById(ids[j]);

          if (sound != null && sound._node != null) {
            sound._node.audio.muted = (muted) ? true : sound._muted;
          }
        }
      }
    }

    return this;
  }

  /// Unload and destroy all currently loaded Howl objects.
  /// @return {Howler}
  _HowlerGlobal unload() {


    for (var i=this._howls.length-1; i>=0; i--) {
      this._howls[i].unload();
    }

    // Create a new AudioContext to make sure it is fully reset.
    if ( this.usingWebAudio && this.ctx != null && this.ctx.close != null ) {
      this.ctx.close();
      this.ctx = null;
      _setupAudioContext();
    }

    return this;
  }

  /// Check for codec support of specific extension.
  /// @param  {String} ext Audio file extention.
  /// @return {bool}
  bool codecs(String ext) {
    ext = ext.replaceAll( new RegExp('^x-'), '') ;
    return this._codecs[ext] ;
  }


  /// Setup various state values for global tracking.
  /// @return {Howler}
  _HowlerGlobal _setup() {


    // Keeps track of the suspend/resume state of the AudioContext.
    this.state = this.ctx != null ? this.ctx.state : null ;
    if (this.state == null) this.state = 'suspended' ;

    // Automatically begin the 30-second suspend process
    this._autoSuspend();

    // Check if audio is available.
    if (!this.usingWebAudio) {
      // No audio is available on this system if noAudio is set to true.
      try {
        new AudioElement() ;
      }
      catch(e) {
        this.noAudio = true;
        print("** NO AUDIO AVAILABLE!");
      }
    }

    // Test to make sure audio isn't disabled in Internet Explorer.
    try {
      var test = new AudioElement();
      if (test.muted) {
        this.noAudio = true;
      }
    } catch (e) {}

    // Check for supported codecs.
    if (!this.noAudio) {
      this._setupCodecs();
    }

    return this;
  }


  /// Check for browser support for various codecs and cache the results.
  /// @return {Howler}
  _HowlerGlobal _setupCodecs() {

    AudioElement audioTest = null;

    // Must wrap in a try/catch because IE11 in server mode throws an error.
    try {
      audioTest = new AudioElement() ;
    }
    catch (err) {
      return this;
    }

    if ( audioTest == null ) return this;

    bool mpegTest = canPlayType(audioTest, 'audio/mpeg;') ;

    this._codecs = {
      'mp3': (mpegTest || canPlayType(audioTest,'audio/mp3;') ) ,
      'mpeg': mpegTest,
      'opus': canPlayType(audioTest, 'audio/ogg; codecs="opus"') ,
      'ogg': canPlayType(audioTest, 'audio/ogg; codecs="vorbis"') ,
      'oga': canPlayType(audioTest, 'audio/ogg; codecs="vorbis"') ,
      'wav': canPlayType(audioTest, 'audio/wav; codecs="1"') ,
      'aac': canPlayType(audioTest, 'audio/aac;') ,
      'caf': canPlayType(audioTest, 'audio/x-caf;') ,
      'm4a': canPlayType(audioTest, 'audio/x-m4a;') || canPlayType(audioTest, 'audio/m4a;') || canPlayType(audioTest, 'audio/aac;') ,
      'mp4': canPlayType(audioTest, 'audio/x-mp4;') || canPlayType(audioTest, 'audio/mp4;') || canPlayType(audioTest, 'audio/aac;') ,
      'weba': canPlayType(audioTest, 'audio/webm; codecs="vorbis"') ,
      'webm': canPlayType(audioTest, 'audio/webm; codecs="vorbis"') ,
      'dolby': canPlayType(audioTest, 'audio/mp4; codecs="ec-3"') ,
      'flac': canPlayType(audioTest, 'audio/x-flac;') || canPlayType(audioTest,'audio/flac;')
    };

    return this;
  }

  static bool canPlayType(AudioElement audioTest, String type) {
    var canPlayType = audioTest.canPlayType('audio/mp3;');
    if (canPlayType == null || canPlayType.isEmpty) return false ;
    canPlayType = canPlayType.toLowerCase() ;
    return canPlayType != 'no' ;
  }


  bool _audioUnlocked = false ;
  bool _mobileUnloaded = false ;
  AudioBuffer _scratchBuffer ;


  /// Some browsers/devices will only allow audio to be played after a user interaction.
  /// Attempt to automatically unlock audio on the first user interaction.
  /// Concept from: http://paulbakaus.com/tutorials/html5/web-audio-on-ios/
  /// @return {Howler}
  _HowlerGlobal _unlockAudio() {


    // Only run this on certain browsers/devices.

    var shouldUnlock = new RegExp('iPhone|iPad|iPod|Android|BlackBerry|BB10|Silk|Mobi|Chrome|Safari', caseSensitive: false).hasMatch( this.userAgent ) ;

    if (this._audioUnlocked || this.ctx != null || !shouldUnlock) return this ;

    this._audioUnlocked = false;
    this.autoUnlock = false;

    // Some mobile devices/platforms have distortion issues when opening/closing tabs and/or web views.
    // Bugs in the browser (especially Mobile Safari) can cause the sampleRate to change from 44100 to 48000.
    // By calling Howler.unload(), we create a new AudioContext with the correct sampleRate.
    if (!this._mobileUnloaded && this.ctx.sampleRate != 44100) {
      this._mobileUnloaded = true;
      this.unload();
    }

    // Scratch buffer for enabling iOS to dispose of web audio buffers correctly, as per:
    // http://stackoverflow.com/questions/24119684
    this._scratchBuffer = this.ctx.createBuffer(1, 1, 22050);

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
    for (var i = 0; i < this.html5PoolSize; i++) {
      var audioNode = new AudioElement();

      // Mark this Audio object as unlocked to ensure it can get returned
      // to the unlocked pool when released.
      audioNode.setAttribute('_unlocked', 'true') ;

      // Add the audio node to the pool.
      this._releaseHtml5Audio(audioNode);
    }

    // Loop through any assigned audio nodes and unlock them.
    for (var i = 0; i < this._howls.length; i++) {
      if (!this._howls[i]._webAudio) {
        // Get all of the sounds in this Howl group.
        var ids = this._howls[i]._getSoundIds();

        // Loop through all sounds and unlock the audio nodes.
        for (var j = 0; j < ids.length; j++) {
          Sound sound = this._howls[i]._soundById(ids[j]);

          if (sound != null && sound._node != null && !sound._node._unlocked) {
            sound._node._unlocked = true;
            sound._node.audio.load();
          }
        }
      }
    }

    // Fix Android can not play in suspend state.
    this._autoResume();

    // Create an empty buffer.
    var source = this.ctx.createBufferSource();
    source.buffer = this._scratchBuffer;
    source.connectNode(this.ctx.destination);

    // Play the empty buffer.
    source.start(0);

    // Calling resume() on a stack initiated by user gesture is what actually unlocks the audio on Android Chrome >= 55.
    this.ctx.resume();

    // Setup a timeout to check that we are unlocked on the next event loop.

    source.onEnded.listen((e) {
      source.disconnect(0);

      // Update the unlocked state and prevent this check from happening again.
      this._audioUnlocked = true;

      // Remove the touch start listener.
      document.removeEventListener('touchstart', _unlock, true);
      document.removeEventListener('touchend', _unlock, true);
      document.removeEventListener('click', _unlock, true);

      // Let all sounds know that audio has been unlocked.
      for (var i = 0; i < this._howls.length; i++) {
        this._howls[i]._emit('unlock');
      }
    });

  }


  /// Get an unlocked HTML5 Audio object from the pool. If none are left,
  /// return a new Audio object and throw a warning.
  /// @return {Audio} HTML5 Audio object.
  AudioElement _obtainHtml5Audio() {


    // Return the next object from the pool if one exists.
    if ( this._html5AudioPool.isNotEmpty ) {
      return this._html5AudioPool.removeLast() ;
    }

    //.Check if the audio is locked and throw a warning.
    var testPlay = new AudioElement().play();

    if (testPlay != null) {
      testPlay.catchError((_) {
        window.console.warn( 'HTML5 Audio pool exhausted, returning potentially locked audio object.' ) ;
      });
    }

    return new AudioElement();
  }


  /// Return an activated HTML5 Audio object to the pool.
  /// @return {Howler}
  _HowlerGlobal _releaseHtml5Audio(audio) {


    // Don't add audio to the pool if we don't know if it has been unlocked.
    if (audio._unlocked) {
      this._html5AudioPool.add(audio);
    }

    return this;
  }

  Timer _suspendTimer ;
  bool _resumeAfterSuspend = false ;

  /// Automatically suspend the Web Audio AudioContext after no sound has played for 30 seconds.
  /// This saves processing/energy and fixes various browser-specific bugs with audio getting stuck.
  /// @return {Howler}
  _HowlerGlobal _autoSuspend() {


    if (!this.autoSuspend || this.ctx == null || !Howler.usingWebAudio ) {
      return this ;
    }

    // Check if any sounds are playing.
    for (var i=0; i<this._howls.length; i++) {
      if (this._howls[i]._webAudio) {
        for (var j=0; j<this._howls[i]._sounds.length; j++) {
          if (!this._howls[i]._sounds[j]._paused) {
            return this;
          }
        }
      }
    }

    if (this._suspendTimer != null) {
      this._suspendTimer.cancel() ;
      this._suspendTimer = null ;
    }


    this._suspendTimer = new Timer(new Duration(seconds: 30), (){
      if (!this.autoSuspend) return;

      this._suspendTimer = null;
      this.state = 'suspending';

      this.ctx.suspend().then((_) {
        this.state = 'suspended';

        if ( this._resumeAfterSuspend ) {
          this._resumeAfterSuspend = false ;
          this._autoResume();
        }
      });
    }) ;

    return this;
  }


  /// Automatically resume the Web Audio AudioContext when a new sound is played.
  /// @return {Howler}
  _HowlerGlobal _autoResume() {


    if (this.ctx == null || !Howler.usingWebAudio ) {
      return this ;
    }

    if ( this.state == 'running' && this._suspendTimer != null) {
      this._suspendTimer.cancel();
      this._suspendTimer = null;
    }
    else if (this.state == 'suspended') {
      this.ctx.resume().then((_) {
        this.state = 'running';

        // Emit to all Howls that the audio has resumed.
        for (int i=0; i < this._howls.length; i++) {
          this._howls[i]._emit('resume');
        }
      });

      if (this._suspendTimer != null) {
        this._suspendTimer.cancel();
        this._suspendTimer = null;
      }

    }
    else if (this.state == 'suspending') {
      this._resumeAfterSuspend = true ;
    }

    return this;
  }

}

final _HowlerGlobal Howler = new _HowlerGlobal();

typedef HowlEventListener(Howl howl, String eventType, int id, String message);

class _HowlEventListenerWrapper {
  final int id ;
  final HowlEventListener function;
  final bool once;

  _HowlEventListenerWrapper(this.function, [this.id, this.once = false]) ;
}

class _HowlSrc {
  List<String> _srcs ;

  _HowlSrc.value(String src) {
    this._srcs = [src] ;
  }

  _HowlSrc.list(this._srcs) {
    if (this._srcs == null) this._srcs = [] ;
  }

  int get length => _srcs.length ;

  String operator [](int index) => _srcs[index] ;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is _HowlSrc &&
              runtimeType == other.runtimeType &&
              isEquivalentList( _srcs , other._srcs ) ;

  int _hashcode ;

  @override
  int get hashCode {
    if (_hashcode == null) {
      int h = 0;
      for (var s in _srcs) {
        h = h * 31 + s.hashCode;
      }
      _hashcode = h ;
    }

    return _hashcode ;
  }

  @override
  String toString() {
    return _srcs.toString() ;
  }


}

class _HowlSpriteParams {
  int from ;
  int to ;
  bool loop ;

  _HowlSpriteParams(this.from, this.to, [ this.loop = false ]);

  _HowlSpriteParams.list(List params) {
    this.from = int.parse( params[0].toString() ) ;
    this.to = int.parse( params[1].toString() ) ;

    if ( params.length <= 2 ) {
      this.loop = false ;
    }
    else {
      String loopStr = params[2].toString().toLowerCase() ;
      this.loop = loopStr == 'true' || loopStr == '1' ;
    }
  }

  static Map<String, _HowlSpriteParams> toMapOfSpritesParams(Map<String,List> map) {
    Map<String, _HowlSpriteParams> sprites = {} ;

    for (var entry in map.entries) {
      String key = entry.key ;
      var spriteParams = new _HowlSpriteParams.list( entry.value ) ;
      sprites[key] = spriteParams ;
    }

    return sprites ;
  }
}

class _HowlCall {
  final String event ;
  final Function action ;

  _HowlCall(this.event, this.action);

}

class Howl {

  bool _autoplay ;
  List<String> _format ;
  bool _html5 ;
  bool _muted ;
  bool _loop ;
  int _pool ;
  bool _preload ;
  double _rate ;
  Map<String,_HowlSpriteParams> _sprite ;
  _HowlSrc _src ;
  double _volume ;
  bool _xhrWithCredentials ;

  double _duration ;
  String _state ;
  List<Sound> _sounds ;
  Map<int,dynamic> _endTimers ;
  List<_HowlCall> _queue ;
  bool _playLock ;

  // Setup event listeners.
  List<_HowlEventListenerWrapper> _onend ;
  List<_HowlEventListenerWrapper> _onfade ;
  List<_HowlEventListenerWrapper> _onload ;
  List<_HowlEventListenerWrapper> _onloaderror ;
  List<_HowlEventListenerWrapper> _onplayerror ;
  List<_HowlEventListenerWrapper> _onpause ;
  List<_HowlEventListenerWrapper> _onplay ;
  List<_HowlEventListenerWrapper> _onstop ;
  List<_HowlEventListenerWrapper> _onmute ;
  List<_HowlEventListenerWrapper> _onvolume ;
  List<_HowlEventListenerWrapper> _onrate ;
  List<_HowlEventListenerWrapper> _onseek ;
  List<_HowlEventListenerWrapper> _onunlock ;
  List<_HowlEventListenerWrapper> _onresume ;

  List<_HowlEventListenerWrapper> _getEventListeners(String eventType) {
    switch(eventType) {
      case 'end': return _onend ;
      case 'fade': return _onfade ;
      case 'load': return _onload ;
      case 'loaderror': return _onloaderror ;
      case 'playerror': return _onplayerror ;
      case 'pause': return _onpause ;
      case 'play': return _onplay ;
      case 'stop': return _onstop ;
      case 'mute': return _onmute ;
      case 'volume': return _onvolume ;
      case 'rate': return _onrate ;
      case 'seek': return _onseek ;
      case 'unlock': return _onunlock ;
      case 'resume': return _onresume ;
      default: return null ;
    }
  }

  bool _webAudio ;

  Howl( {
    List<String> src,
    bool autoplay: false,
    List<String> format,
    bool html5: false,
    bool mute: false,
    bool loop: false,
    int pool: 5,
    bool preload: true,
    double rate: 1,
    Map<String,List> sprite,
    double volume: 1,
    bool xhrWithCredentials: false,

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
    HowlEventListener onresume
  } )
  {

    if (src == null || src.isEmpty ) {
      window.console.error('An array of source files must be passed with any new Howl.') ;
      return;
    }



    // If we don't have an AudioContext created yet, run the setup.
    if ( Howler.ctx == null ) {
      _setupAudioContext() ;
    }

    // Setup user-defined default properties.
    this._autoplay = autoplay ;
    this._format = format != null ? format : [] ;
    this._html5 = html5 ;
    this._muted = mute ;
    this._loop = loop ;
    this._pool = pool ;
    this._preload = preload ;
    this._rate = rate ;
    this._sprite = sprite != null ? _HowlSpriteParams.toMapOfSpritesParams(sprite) : {} ;
    this._src = new _HowlSrc.list(src) ;
    this._volume = volume ;
    this._xhrWithCredentials = xhrWithCredentials ;

    // Setup all other default properties.
    this._duration = 0;
    this._state = 'unloaded';
    this._sounds = [];
    this._endTimers = {};
    this._queue = [];
    this._playLock = false;

    // Setup event listeners.
    this._onend = onend != null ? [new _HowlEventListenerWrapper(onend)] : [];
    this._onfade = onfade != null ? [new _HowlEventListenerWrapper(onfade)] : [];
    this._onload = onload != null ? [new _HowlEventListenerWrapper(onload)] : [];
    this._onloaderror = onloaderror != null ? [new _HowlEventListenerWrapper(onloaderror)] : [];
    this._onplayerror = onplayerror != null ? [new _HowlEventListenerWrapper(onplayerror)] : [];
    this._onpause = onpause != null ? [new _HowlEventListenerWrapper(onpause)] : [];
    this._onplay = onplay != null ? [new _HowlEventListenerWrapper(onplay)] : [];
    this._onstop = onstop != null ? [new _HowlEventListenerWrapper(onstop)] : [];
    this._onmute = onmute != null ? [new _HowlEventListenerWrapper(onmute)] : [];
    this._onvolume = onvolume != null ? [new _HowlEventListenerWrapper(onvolume)] : [];
    this._onrate = onrate != null ? [new _HowlEventListenerWrapper(onrate)] : [];
    this._onseek = onseek != null ? [new _HowlEventListenerWrapper(onseek)] : [];
    this._onunlock = onunlock != null ? [new _HowlEventListenerWrapper(onunlock)] : [];
    this._onresume = [];

    // Web Audio or HTML5 Audio?
    this._webAudio = Howler.usingWebAudio && !this._html5;

    // Automatically try to enable audio.
    if ( Howler.ctx != null && Howler.autoUnlock ) {
      Howler._unlockAudio();
    }

    // Keep track of this Howl group in the global controller.
    Howler._howls.add(this);

    // If they selected autoplay, add a play event to the load queue.
    if (this._autoplay) {
      this._queue.add(
          new _HowlCall('play', () {
            this.play() ;
          })
      );
    }

    // Load the source file unless otherwise specified.
    if (this._preload) {
      this.load();
    }
  }

  List<int> get soundIDs => new List.from( _sounds.map((s) => s._id) ) ;

  @override
  String toString() {
    return 'Howl{ playing: ${ this.playing() }, src: $_src, sounds: $_sounds}';
  }

  /// Load the audio file.
  /// @return {Howler}
  Howl load() {

    String url = null;

    // If no audio is available, quit immediately.
    if (Howler.noAudio) {
      this._emit('loaderror', null, 'No audio support.');
      return this ;
    }

    // Loop through the sources and pick the first one that is compatible.
    for (var i=0; i<this._src.length; i++) {
      String ext , src ;

      if (this._format != null && i < this._format.length && this._format[i] != null ) {
        // If an extension was specified, use that instead.
        ext = this._format[i];
      }
      else {
        // Make sure the source is a string.
        src = this._src[i];
        if (src == null) {
          this._emit('loaderror', null, 'Non-string found in selected audio sources - ignoring.');
          continue;
        }

        var match = new RegExp(r'^data:audio/([^;,]+);', caseSensitive: false).firstMatch(src);
        ext = match != null ? match.group(1) : null ;

        if ( ext == null || ext.isEmpty ) {
          var url = split(src, '?', 1)[0] ;
          var match = new RegExp(r'\.([^.]+)$').firstMatch(url) ;
          ext = match != null ? match.group(1) : null ;
        }

        if (ext != null) {
          ext = ext.toLowerCase();
        }
      }

      // Log a warning if no extension was found.
      if (ext == null) {
        window.console.warn('No file extension was found. Consider using the "format" property or specify an extension.');
      }

      // Check if this extension is available.
      if (ext != null && Howler.codecs(ext)) {
        url = this._src[i];
        break;
      }
    }

    if ( url == null ) {
      this._emit('loaderror', null, 'No codec support for selected audio sources.');
      return this ;
    }

    this._src = new _HowlSrc.value(url) ;
    this._state = 'loading';

    // If the hosting page is HTTPS and the source isn't,
    // drop down to HTML5 Audio to avoid Mixed Content errors.
    if (window.location.protocol == 'https:' && url.substring(0, 5) == 'http:') {
      this._html5 = true;
      this._webAudio = false;
    }

    // Create a new sound object and add it to the pool.
    new Sound(this);

    // Load and decode the audio data for playback.
    if (this._webAudio) {
      _loadBuffer();
    }

    return this;
  }


  /// Play a sound or resume previous playback.
  /// @param  {String/Number} sprite   Sprite name for sprite playback or sound id to continue previous.
  /// @param  {Boolean} internal Internal Use: true prevents event firing.
  /// @return {Number}          Sound ID.
  int play([dynamic sprite, bool internal = false]) {

    int id = null;

    if (sprite == null) {
      // Use the default sound sprite (plays the full audio length).
      sprite = '__default';

      // Check if there is a single paused sound that isn't ended.
      // If there is, play that sound. If not, continue as usual.
      if (!this._playLock) {
        var num = 0;
        for (var i = 0; i < this._sounds.length; i++) {
          if (this._sounds[i]._paused && !this._sounds[i]._ended) {
            num++;
            id = this._sounds[i]._id;
          }
        }

        if (num == 1) {
          sprite = null;
        }
        else {
          id = null;
        }
      }
    }
    // Determine if a sprite, sound ID or nothing was passed
    else if (sprite is int) {
      id = sprite;
      sprite = null;
    }
    else if (sprite is String && this._state == 'loaded' && this._sprite[sprite] == null ) {
      // If the passed sprite doesn't exist, do nothing.
      return null ;
    }


    // Get the selected node, or get one from the pool.
    Sound sound = id != null ? this._soundById(id) : this._inactiveSound() ;

    // If the sound doesn't exist, do nothing.
    if ( sound == null ) {
      return null;
    }

    // Select the sprite definition.
    if (id != null && sprite == null ) {
      sprite = sound._sprite ;
      if (sprite == null) sprite = '__default' ;
    }

    // If the sound hasn't loaded, we must wait to get the audio's duration.
    // We also need to wait to make sure we don't run into race conditions with
    // the order of function calls.
    if (this._state != 'loaded') {
      // Set the sprite value on this sound.
      sound._sprite = sprite;

      // Mark this sound as not ended in case another sound is played before this one loads.
      sound._ended = false;

      // Add the sound to the queue to be played on load.
      int soundId = sound._id;

      this._queue.add(
          new _HowlCall('play', () {
            this.play(soundId);
          })
      );

      return soundId;
    }

    // Don't play the sound if an id was passed and it is already playing.
    if (id != null && !sound._paused) {
      // Trigger the play event, in order to keep iterating through queue.
      if (!internal) {
        this._loadQueue('play');
      }

      return sound._id;
    }

    // Make sure the AudioContext isn't suspended, and resume it if it is.
    if (this._webAudio) {
      Howler._autoResume();
    }

    // Determine how long to play for and where to start playing.
    double seek = Math.max(0, sound._seek > 0 ? sound._seek : this._sprite[sprite].from / 1000);
    double duration = Math.max(0, ((this._sprite[sprite].from + this._sprite[sprite].to) / 1000) - seek);
    int timeout = (duration * 1000) ~/ sound._rate.abs() ;

    double start = this._sprite[sprite].from / 1000;
    double stop = (this._sprite[sprite].from + this._sprite[sprite].to) / 1000 ;

    bool loop = sound._loop;
    if (!loop) {
      var spriteConf = this._sprite[sprite];
      loop = spriteConf.loop ;
    }

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
      sound._loop = loop;
    };

    // End the sound instantly if seek is at the end.
    if (seek >= stop) {
      this._ended(sound);
      return null ;
    }

    // Begin the actual playback.
    _HowlAudioNode node = sound._node;

    if (this._webAudio) {
      // Fire this when the sound is ready to play to begin Web Audio playback.
      HowlEventListener playWebAudio = (h,t,id,m) {
        this._playLock = false;
        setParams();
        this._refreshBuffer(sound);

        // Setup the playback params.
        var vol = (sound._muted || this._muted) ? 0 : sound._volume;
        node.gainNode.gain.setValueAtTime(vol, Howler.ctx.currentTime);
        sound._playStart = Howler.ctx.currentTime;

        sound._loop ? node.bufferSource.start(0, seek, 86400) : node.bufferSource.start(0, seek, duration);

        // Start a new timer if none is present.
        if (timeout > 0 && timeout < 100000000) {
          this._endTimers[sound._id] = new Timer(new Duration(milliseconds: timeout), () {
            this._ended(sound) ;
          }) ;
        }

        if ( !internal ) {
          new Timer(Duration.zero, () {
            this._emit('play', sound._id);
            this._loadQueue();
          });
        }
      };

      if (Howler.state == 'running') {
        playWebAudio(this, 'play', sound._id, null);
      }
      else {
        this._playLock = true;

        // Wait for the audio context to resume before playing.
        this.once('resume', playWebAudio, null);

        // Cancel the end timer.
        this._clearTimer(sound._id);
      }
    }
    else {
      // Fire this when the sound is ready to play to begin HTML5 Audio playback.
      var playHtml5 = () {
        node.audio.currentTime = seek;
        node.audio.muted = sound._muted || this._muted || Howler._muted || node.audio.muted;
        node.audio.volume = sound._volume * Howler.volume();
        node.audio.playbackRate = sound._rate;

        // Some browsers will throw an error if this is called without user interaction.
        try {
          var play = node.audio.play();

          if ( play != null ) {
            // Implements a lock to prevent DOMException: The play() request was interrupted by a call to pause().
            this._playLock = true;

            // Set param values immediately.
            setParams();

            // Releases the lock and executes queued actions.
            play.then((_) {
              this._playLock = false;
              node._unlocked = true;

              if ( !internal ) {
                this._emit('play', sound._id);
                this._loadQueue();
              }
            }
            ).catchError(() {
              this._playLock = false;
              this._emit('playerror', sound._id, 'Playback was unable to start. This is most commonly an issue ' +
                  'on mobile devices and Chrome where playback was not within a user interaction.');

              // Reset the ended and paused values.
              sound._ended = true;
              sound._paused = true;
            });
          }
          else if ( !internal ) {
            this._playLock = false;
            setParams();
            this._emit('play', sound._id);
            this._loadQueue();
          }

          // Setting rate before playing won't work in IE, so we set it again here.
          node.audio.playbackRate = sound._rate;

          // If the node is still paused, then we can assume there was a playback issue.
          if ( node.audio.paused ) {
            this._emit('playerror', sound._id, 'Playback was unable to start. This is most commonly an issue ' +
                'on mobile devices and Chrome where playback was not within a user interaction.');
            return;
          }

          // Setup the end timer on sprites or listen for the ended event.
          if (sprite != '__default' || sound._loop) {
            this._endTimers[sound._id] = new Timer(new Duration(milliseconds: timeout) , () {
              this._ended(sound) ;
            }) ;
          }
          else {
            this._endTimers[sound._id] = (e) {
              // Fire ended on this audio node.
              this._ended(sound);

              // Clear this listener.
              this._clearTimer(sound._id);
            };

            node.eventTarget.addEventListener('ended', this._endTimers[sound._id], false);
          }
        }
        catch (err) {
          this._emit('playerror', sound._id, err);
        }
      };

      // Play immediately if ready, or wait for the 'canplaythrough'e vent.

      if (node.audio.readyState >= 3) {
        playHtml5();
      }
      else {
        this._playLock = true;

        // Cancel the end timer.
        this._clearTimer(sound._id);

        EventListener listener = (e) {
          // Begin playback.
          playHtml5();

          // Clear this listener.
          this._clearTimer(sound._id);
        };

        node.eventTarget.addEventListener(Howler._canPlayEvent, listener, false);
      }
    }

    return sound._id ;
  }


  /// Pause playback and save current position.
  /// @param  {Number} id The sound ID (empty to pause all in group).
  /// @return {Howl}
  Howl pause(int id, [bool internal = false]) {


    // If the sound hasn't loaded or a play() promise is pending, add it to the load queue to pause when capable.
    if (this._state != 'loaded' || this._playLock) {
      this._queue.add(
          new _HowlCall('pause', () {
            this.pause(id);
          })
      );

      return this;
    }

    // If no id is passed, get all ID's to be paused.
    var ids = this._getSoundIds(id);

    for (var i=0; i<ids.length; i++) {
      int id2 = ids[i];
      this._clearTimer(id2);

      // Get the sound.
      var sound = this._soundById(id2);

      if (sound != null && !sound._paused) {
        // Reset the seek position.
        sound._seek = this.getSeek(id2);
        sound._rateSeek = 0;
        sound._paused = true;

        // Stop currently running fades.
        this._stopFade(id2);

        if (sound._node != null) {
          if (this._webAudio) {
            // Make sure the sound has been created.
            if ( sound._node.bufferSource == null ) {
              continue;
            }

            sound._node.bufferSource.stop(0);

            // Clean up the buffer source.
            this._cleanBuffer(sound._node);
          }
          else if ( !sound._node.audio.duration.isNaN || sound._node.audio.duration.isInfinite) {
            sound._node.audio.pause();
          }
        }
      }

      // Fire the pause event, unless `true` is passed as the 2nd argument.
      if ( !internal ) {
        this._emit('pause', sound != null ? sound._id : null);
      }
    }

    return this;
  }

  Howl stopAll() {
    stopIDs( this.soundIDs ) ;
    return this ;
  }

  Howl stopIDs(List<int> ids) {
    for (int id in ids) {
      stop(id) ;
    }
    return this ;
  }

  /// Stop playback and reset to start.
  /// @param  {Number} id The sound ID (empty to stop all in group).
  /// @param  {Boolean} internal Internal Use: true prevents event firing.
  /// @return {Howl}
  Howl stop(int id, [bool internal = false]) {


    // If the sound hasn't loaded, add it to the load queue to stop when capable.
    if (this._state != 'loaded' || this._playLock) {
      this._queue.add(
          new _HowlCall('stop', () {
            this.stop(id);
          })
      );

      return this;
    }

    // If no id is passed, get all ID's to be stopped.
    var ids = this._getSoundIds(id);

    for (var i=0 ; i<ids.length ; i++) {
      // Clear the end timer.
      this._clearTimer(ids[i]);

      // Get the sound.
      var sound = this._soundById(ids[i]);

      if (sound != null) {
        // Reset the seek position.
        sound._seek = sound._start ;
        sound._rateSeek = 0;
        sound._paused = true;
        sound._ended = true;

        // Stop currently running fades.
        this._stopFade(ids[i]);

        if (sound._node != null) {
          if (this._webAudio) {
            // Make sure the sound's AudioBufferSourceNode has been created.
            if ( sound._node.bufferSource != null ) {
              sound._node.bufferSource.stop(0);

              // Clean up the buffer source.
              this._cleanBuffer(sound._node);
            }
          }
          else if ( !sound._node.audio.duration.isNaN || sound._node.audio.duration.isInfinite ) {
            sound._node.audio.currentTime = sound._start ;
            sound._node.audio.pause();
          }
        }

        if ( !internal ) {
          this._emit('stop', sound._id);
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
    if ( this._state != 'loaded'|| this._playLock ) {
      this._queue.add(
          new _HowlCall('mute', () {
            this.mute(muted, id);
          })
      );

      return this;
    }

    // If applying mute/unmute to all sounds, update the group's value.
    if (id == null) {
      if (muted != null) {
        this._muted = muted;
      }
      else {
        return this ;
      }
    }

    // If no id is passed, get all ID's to be muted.
    List<int> ids = this._getSoundIds(id);

    for (var i=0; i<ids.length; i++) {
      // Get the sound.
      var sound = this._soundById(ids[i]);

      if (sound != null) {
        sound._muted = muted;

        // Cancel active fade and set the volume to the end value.
        if ( sound._interval != null ) {
          this._stopFade(sound._id);
        }

        if (this._webAudio && sound._node != null) {
          sound._node.gainNode.gain.setValueAtTime(muted ? 0 : sound._volume, Howler.ctx.currentTime);
        }
        else if (sound._node != null) {
          sound._node.audio.muted = Howler._muted ? true : muted;
        }

        this._emit('mute', sound._id);
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
      return this._volume;
    }
    else {
      Sound sound = this._soundById(id) ;
      return sound != null ? sound._volume : 0 ;
    }
  }


  /// Get/set the volume of this sound or of the Howl group. This method can optionally take 0, 1 or 2 arguments.
  ///   volume() -> Returns the group's volume value.
  ///   volume(id) -> Returns the sound id's current volume.
  ///   volume(vol) -> Sets the volume of all sounds in this Howl group.
  ///   volume(vol, id) -> Sets the volume of passed sound id.
  /// @return {Howl} Returns this.
  Howl setVolume(double vol, [int id, bool internal = false]) {
    if (vol == null || vol < 0 || vol > 1) return this ;

    // If the sound hasn't loaded, add it to the load queue to change volume when capable.
    if ( this._state != 'loaded'|| this._playLock ) {
      this._queue.add(
          new _HowlCall('volume', () {
            this.setVolume(vol, id) ;
          }
          ));

      return this;
    }

    // Set the group volume.
    if (id == null) {
      this._volume = vol;
    }

    // Update one or all volumes.
    List<int> ids = this._getSoundIds(id);

    for (var i=0; i < ids.length; i++) {
      var id2 = ids[i];
      Sound sound = this._soundById( id2 );

      if (sound != null) {
        sound._volume = vol ;

        // Stop currently running fades.
        if ( !internal ) {
          this._stopFade(id2);
        }

        if (this._webAudio && sound._node != null && !sound._muted) {
          sound._node.gainNode.gain.setValueAtTime(vol, Howler.ctx.currentTime);
        }
        else if (sound._node != null && !sound._muted) {
          sound._node.audio.volume = vol * Howler.volume();
        }

        this._emit('volume', sound._id);
      }
    }

    return this;
  }


  /// Fade a currently playing sound between two volumes (if no id is passsed, all sounds will fade).
  /// @param  {Number} from The value to fade from (0.0 to 1.0).
  /// @param  {Number} to   The volume to fade to (0.0 to 1.0).
  /// @param  {Number} len  Time in milliseconds to fade.
  /// @param  {Number} id   The sound id (omit to fade all sounds).
  /// @return {Howl}
  Howl fade(double from, double to, int len, [int id]) {


    // If the sound hasn't loaded, add it to the load queue to fade when capable.
    if (this._state != 'loaded' || this._playLock) {
      this._queue.add(
          new _HowlCall('fade', () {
            this.fade(from, to, len, id);
          })
      );

      return this;
    }

    // Set the volume to the start position.
    this.setVolume(from, id);

    // Fade the volume of one or all sounds.
    List<int> ids = this._getSoundIds(id);

    for (var i=0; i<ids.length; i++) {
      // Get the sound.
      Sound sound = this._soundById(ids[i]);

      // Create a linear fade or fall back to timeouts with HTML5 Audio.
      if (sound != null) {
        // Stop the previous fade if no sprite is being used (otherwise, volume handles this).
        if (id == null) {
          this._stopFade(ids[i]);
        }

        // If we are using Web Audio, let the native methods do the actual fade.
        if (this._webAudio && !sound._muted) {
          var currentTime = Howler.ctx.currentTime;
          var end = currentTime + (len / 1000);
          sound._volume = from;
          sound._node.gainNode.gain.setValueAtTime(from, currentTime);
          sound._node.gainNode.gain.linearRampToValueAtTime(to, end);
        }

        this._startFadeInterval(sound, from, to, len, ids[i], id == null);
      }
    }

    return this;
  }


  /// Starts the internal interval to fade a sound.
  /// @param  {Object} sound Reference to sound to fade.
  /// @param  {Number} from The value to fade from (0.0 to 1.0).
  /// @param  {Number} to   The volume to fade to (0.0 to 1.0).
  /// @param  {Number} len  Time in milliseconds to fade.
  /// @param  {Number} id   The sound id to fade.
  /// @param  {Boolean} isGroup   If true, set the volume on the group.
  void _startFadeInterval(Sound sound, double from, double to, int len, id, isGroup) {


    double vol = from;
    double diff = to - from;
    double steps = (diff / 0.01).abs() ;
    int stepLen = Math.max(4, (steps > 0) ? len ~/ steps : len);
    int lastTick = DateTime.now().millisecondsSinceEpoch ;

    // Store the value being faded to.
    sound._fadeTo = to;

    // Update the volume value on each interval tick.

    sound._interval = new Timer.periodic(new Duration(milliseconds: stepLen), (t) {

      // Update the volume based on the time since the last tick.
      var now = DateTime.now().millisecondsSinceEpoch;

      var tick = (now - lastTick) / len;
      lastTick = now;
      vol += diff * tick;

      // Make sure the volume is in the right bounds.
      vol = Math.max(0, vol);
      vol = Math.min(1, vol);

      // Round to within 2 decimal points.
      vol = (vol * 100).round() / 100;

      // Change the volume.
      if (this._webAudio) {
        sound._volume = vol;
      }
      else {
        this.setVolume(vol, sound._id, true);
      }

      // Set the group's volume.
      if (isGroup) {
        this._volume = vol;
      }

      // When the fade is complete, stop it and fire event.
      if ( (to < from && vol <= to) || (to > from && vol >= to) ) {

        if (sound._interval != null) {
          sound._interval.cancel() ;
          sound._interval = null;
        }

        sound._fadeTo = null;

        this.setVolume(to, sound._id);
        this._emit('fade', sound._id);
      }

    }) ;

  }

  /// Internal method that stops the currently playing fade when
  /// a new fade starts, volume is changed or the sound is stopped.
  /// @param  {Number} id The sound id.
  /// @return {Howl}
  void _stopFade(int id) {
    Sound sound = this._soundById(id);

    if (sound != null && sound._interval != null) {
      if (this._webAudio) {
        sound._node.gainNode.gain.cancelScheduledValues(Howler.ctx.currentTime);
      }

      sound._interval.cancel();
      sound._interval = null;

      this.setVolume(sound._fadeTo, id);
      sound._fadeTo = null;

      this._emit('fade', id);
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
      return this._loop ;
    }
    else {
      Sound sound = this._soundById(id);
      return sound != null ? sound._loop : false;
    }
  }


  /// Set the loop parameter on a sound. This method can optionally take 0, 1 or 2 arguments.
  ///   setLoop(loop) -> Sets the loop value for all sounds in this Howl group.
  ///   setLoop(loop, id) -> Sets the loop value of passed sound id.
  /// @return {Howl} Returns this.
  Howl setLoop(bool loop, [int id]) {
    if (id == null) {
      this._loop = loop;
    }

    // If no id is passed, get all ID's to be looped.
    var ids = this._getSoundIds(id);

    for (var i=0; i<ids.length; i++) {
      Sound sound = this._soundById(ids[i]);

      if (sound != null) {
        sound._loop = loop;

        if (this._webAudio && sound._node != null && sound._node.bufferSource != null) {
          sound._node.bufferSource.loop = loop;

          if (loop) {
            sound._node.bufferSource.loopStart = sound._start ;
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
    if (id == null) {
      // We will simply return the current rate of the first node.
      id = this._sounds[0]._id;
    }
    else {
      Sound sound = this._soundById(id);
      return sound != null ? sound._rate : this._rate;
    }
  }


  /// Set the playback rate of a sound. This method can optionally take 0, 1 or 2 arguments.
  ///   setRate(rate) -> Sets the playback rate of all sounds in this Howl group.
  ///   setRate(rate, id) -> Sets the playback rate of passed sound id.
  /// @return {Howl} Returns this.
  Howl setRate(double rate, [int id]) {
    // If the sound hasn't loaded, add it to the load queue to change playback rate when capable.
    if (this._state != 'loaded' || this._playLock) {
      this._queue.add(
          new _HowlCall('rate', () {
            this.setRate(rate, id);
          })
      );

      return this;
    }

    // Set the group rate.
    if (id == null) {
      this._rate = rate;
    }

    // Update one or all volumes.
    List<int> ids = this._getSoundIds(id) ;

    for (var i=0; i < ids.length; i++) {
      int id2 = ids[i];
      Sound sound = this._soundById(id2);

      if (sound != null) {
        // Keep track of our position when the rate changed and update the playback
        // start position so we can properly adjust the seek position for time elapsed.
        if (this.playing(id2)) {
          sound._rateSeek = this.getSeek(id2);
          sound._playStart = this._webAudio ? Howler.ctx.currentTime : sound._playStart;
        }
        sound._rate = rate;

        // Change the playback rate.
        if (this._webAudio && sound._node != null && sound._node.bufferSource != null ) {
          sound._node.bufferSource.playbackRate.setValueAtTime(rate, Howler.ctx.currentTime);
        }
        else if (sound._node != null) {
          sound._node.audio.playbackRate = rate;
        }

        // Reset the timers.
        double seek = this.getSeek(id2);
        double duration = ((this._sprite[sound._sprite].from + this._sprite[sound._sprite].to) / 1000) - seek;
        int timeout = (duration * 1000) ~/ sound._rate.abs() ;

        // Start a new end timer if sound is already playing.
        if ( this._endTimers[id2] != null || !sound._paused ) {
          this._clearTimer(id2);

          new Timer( new Duration(milliseconds: timeout), () {
            this._ended(sound) ;
          });
        }

        this._emit('rate', sound._id);
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
    if (id == null) {
      // We will simply return the current position of the first node.
      id = this._sounds[0]._id;
    }

    // If there is no ID, bail out.
    if (id == null) return null ;

    // If the sound hasn't loaded, add it to the load queue to seek when capable.
    if (this._state != 'loaded' || this._playLock) {
      return null ;
    }

    // Get the sound.
    var sound = this._soundById(id);

    if (sound != null) {
      if (this._webAudio) {
        double realTime = this.playing(id) ? Howler.ctx.currentTime - sound._playStart : 0 ;
        double rateSeek = sound._rateSeek != null && sound._rateSeek > 0 ? sound._rateSeek - sound._seek : 0 ;
        return sound._seek + (rateSeek + realTime * sound._rate.abs());
      }
      else {
        return sound._node.audio.currentTime ;
      }
    }
  }


  /// Set the seek position of a sound. This method can optionally take 0, 1 or 2 arguments.
  ///   setSeek(seek) -> Sets the seek position of the first sound node.
  ///   setSeek(seek, id) -> Sets the seek position of passed sound id.
  /// @return {Howl} Returns this.
  Howl setSeek(double seek, [int id]) {
    // Determine the values based on arguments.
    if (id == null) {
      id = this._sounds[0]._id;
    }

    // If there is no ID, bail out.
    if (id == null) return this;

    // If the sound hasn't loaded, add it to the load queue to seek when capable.
    if (this._state != 'loaded' || this._playLock) {
      this._queue.add(
          new _HowlCall('seek', () {
            this.setSeek(seek, id) ;
          })
      );

      return this;
    }

    // Get the sound.
    Sound sound = this._soundById(id);

    if (sound != null) {
      // Pause the sound and update position for restarting playback.
      var playing = this.playing(id);
      if (playing) {
        this.pause(id, true);
      }

      // Move the position of the track and cancel timer.
      sound._seek = seek;
      sound._ended = false;
      this._clearTimer(id);

      // Update the seek position for HTML5 Audio.
      if ( !this._webAudio && sound._node != null && !sound._node.audio.duration.isNaN ) {
        sound._node.audio.currentTime = seek;
      }

      // Seek and emit when ready.
      var seekAndEmit = () {
        this._emit('seek', id);

        // Restart the playback if the sound was playing.
        if (playing) {
          this.play(id, true);
        }
      };

      // Wait for the play lock to be unset before emitting (HTML5 Audio).
      if (playing && !this._webAudio) {

        new Timer.periodic(Duration.zero, (t) {
          if (!this._playLock) {
            seekAndEmit();
            t.cancel();
          }
        });

      }
      else {
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
      Sound sound = this._soundById(id);
      return sound != null ? !sound._paused : false ;
    }

    // Otherwise, loop through all sounds and check if any are playing.
    for (var i=0; i < this._sounds.length; i++) {
      if (!this._sounds[i]._paused) {
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
      return this._duration;
    }

    // If we pass an ID, get the sound and return the sprite length.
    Sound sound = this._soundById(id);

    if (sound != null) {
      return this._sprite[sound._sprite].to / 1000;
    }
    else {
      return this._duration ;
    }
  }


  /// Returns the current loaded state of this Howl.
  /// @return {String} 'unloaded', 'loading', 'loaded'
  String state() {
    return this._state;
  }


  /// Unload and destroy the current Howl object.
  /// This will immediately stop all sound instances attached to this group.
  void unload() {
    // Stop playing any active sounds.
    List<Sound> sss = this._sounds ;

    for (int i=0; i < sss.length; i++) {
      var sound = sss[i] ;
      // Stop the sound if it is currently playing.
      if (!sound._paused) {
        this.stop(sound._id);
      }

      // Remove the source or disconnect.
      if (!this._webAudio) {
        // Set the source to 0-second silence to stop any downloading (except in IE).
        /*
        var checkIE = /MSIE |Trident\//.test(Howler._navigator && Howler._navigator.userAgent);
        if (!checkIE) {
          sound._node.src = 'data:audio/wav;base64,UklGRigAAABXQVZFZm10IBIAAAABAAEARKwAAIhYAQACABAAAABkYXRhAgAAAAEA';
        }
        */

        // Remove any event listeners.
        sound._node.eventTarget.removeEventListener('error', sound._errorFn, false);
        sound._node.eventTarget.removeEventListener(Howler._canPlayEvent, sound._loadFn, false);

        // Release the Audio object back to the pool.
        Howler._releaseHtml5Audio(sound._node);
      }

      // Empty out all of the nodes.
      sss[i]._node = null ;

      // Make sure all timers are cleared out.
      this._clearTimer(sound._id);
    }

    // Remove the references in the global Howler object.
    var index = Howler._howls.indexOf(this);
    if (index >= 0) {
      Howler._howls.removeAt(index);
    }

    // Delete this sound from the cache (if no other Howl is using it).
    var remCache = true;

    for (int i=0; i<Howler._howls.length; i++) {
      if ( Howler._howls[i]._src == this._src ) {
        remCache = false;
        break;
      }
    }

    if ( remCache ) {
      _cache.remove(this._src);
    }

    // Clear global errors.
    Howler.noAudio = false;

    // Clear out `this`.
    this._state = 'unloaded';
    this._sounds = [];

    return null;
  }


  /// Listen to a custom event.
  /// @param  {String}   event Event name.
  /// @param  {Function} fn    Listener to call.
  /// @param  {Number}   id    (optional) Only listen to events for this sound.
  /// @param  {Number}   once  (INTERNAL) Marks event to fire only once.
  /// @return {Howl}
  Howl on(String eventType, HowlEventListener function, int id, [bool once = false]) {

    var events = this._getEventListeners(eventType) ;
    var listener = new _HowlEventListenerWrapper(function, id, once) ;
    events.add(listener) ;
    return this;
  }

  /// Remove a custom event. Call without parameters to remove all events.
  /// @param  {String}   event Event name.
  /// @param  {Function} fn    Listener to remove. Leave empty to remove all.
  /// @param  {Number}   id    (optional) Only remove events for this sound.
  /// @return {Howl}
  Howl off(String eventType, [int id, HowlEventListener function]) {
    var events = this._getEventListeners(eventType) ;
    var i = 0;

    if (id != null) {
      // Loop through event store and remove the passed function.
      for (i=0; i < events.length; i++) {
        var isId = (id == events[i].id) ;

        if ( isId && (function == null || function == events[i].function) ) {
          events.removeAt(i);
          break;
        }
      }
    }
    else {
      // Clear out all events of this type.
      events.clear() ;
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
  }


  /// Listen to a custom event and remove it once fired.
  /// @param  {String}   event Event name.
  /// @param  {Function} fn    Listener to call.
  /// @param  {Number}   id    (optional) Only listen to events for this sound.
  /// @return {Howl}
  Howl once(String event, HowlEventListener function, int id) {
    this.on(event, function, id, true);
    return this;
  }

  final Map<_HowlSrc,AudioBuffer> _cache = {};

  /// Buffer a sound from URL, Data URI or cache and decode to audio source (Web Audio API).
  /// @param  {Howl} this
  void _loadBuffer() {
    String url = this._src[0] ;

    // Check if the buffer has already been cached and use it instead.
    var audioBuffer = _cache[url];

    if ( audioBuffer != null ) {
      // Set the duration from the cache.
      this._duration = audioBuffer.duration ;

      // Load the sound into this Howl.
      _loadSound(audioBuffer);

      return;
    }

    if ( new RegExp(r'^data:[^;]+;base64,').hasMatch(url) ) {
      // Decode the base64 data URI without XHR, since some browsers don't support it.
      var base64Data = split(url,',',1)[1] ;
      Uint8List dataView = base64.decode(base64Data) ;
      _decodeAudioData(dataView.buffer);
    }
    else {

      HttpRequest.request(url,
        method: 'GET',
        withCredentials: _xhrWithCredentials,
        responseType: 'arraybuffer',
      ).then( (xhr) {
        // Make sure we get a successful response back.
        var code = xhr.status ;
        if (code < 200 ||  code >= 400) {
          this._emit('loaderror', null, 'Failed loading audio file with status: $code');
          return;
        }

        _decodeAudioData(xhr.response);
      }, onError: () {
        // If there is an error, switch to HTML5 Audio.
        if (this._webAudio) {
          this._html5 = true;
          this._webAudio = false;
          this._sounds = [];
          _cache.remove(url) ;
          this.load();
        }
      });

    }
  }


  /// Decode audio data from an array buffer.
  /// @param  {ArrayBuffer} arraybuffer The audio data.
  /// @param  {Howl}        this
  void _decodeAudioData(ByteBuffer arraybuffer) {
    // Fire a load error if something broke.
    var error = () {
      this._emit('loaderror', null, 'Decoding audio data failed.');
    };

    // Load the sound on success.
    //var success = ;

    Howler.ctx.decodeAudioData(arraybuffer).then( (buffer) {
      if (buffer != null && this._sounds.length > 0) {
        _cache[this._src] = buffer ;
        _loadSound(buffer);
      }
      else {
        error();
      }
    }
        , onError: error) ;
  }


  /// Sound is now loaded, so finish setting everything up and fire the loaded event.
  /// @param  {Howl} this
  /// @param  {Object} buffer The decoded buffer sound source.
  void _loadSound(AudioBuffer buffer) {
    // Set the duration.
    if (buffer != null && (this._duration == null || this._duration == 0) ) {
      this._duration = buffer.duration;
    }

    // Setup a sprite if none is defined.
    if ( this._sprite.length == 0 ) {
      this._sprite = {'__default': new _HowlSpriteParams(0, (this._duration * 1000).floor() ) } ;
    }

    // Fire the loaded event.
    if (this._state != 'loaded') {
      this._state = 'loaded';
      this._emit('load');
      this._loadQueue();
    }
  }


  /// Emit all events of a specific type and pass the sound id.
  /// @param  {String} event Event name.
  /// @param  {Number} id    Sound ID.
  /// @param  {Number} msg   Message to go with event.
  /// @return {Howl}
  void _emit(String eventType, [int id, String msg]) {
    List<_HowlEventListenerWrapper> events = _getEventListeners(eventType) ;
    List<_HowlEventListenerWrapper> offEvents ;

    // Loop through event store and fire all functions.
    for (var i = events.length-1 ; i >= 0 ; i--) {
      _HowlEventListenerWrapper evt = events[i] ;

      // Only fire the listener if the correct ID is used.
      if ( evt.id == null || evt.id == id || eventType == 'load') {
        new Timer(Duration.zero, () {
          evt.function(this, eventType, id, msg);
        });

        // If this event was setup with `once`, remove it.
        if (evt.once) {
          if (offEvents == null) offEvents = [] ;
          offEvents.add(evt) ;
        }
      }
    }

    if (offEvents != null) {
      for (var evt in offEvents) {
        this.off(eventType, evt.id, evt.function);
      }
    }

    // Pass the event type into load queue so that it can continue stepping.
    this._loadQueue(eventType);
  }

  /// Queue of actions initiated before the sound has loaded.
  /// These will be called in sequence, with the next only firing
  /// after the previous has finished executing (even if async like play).
  /// @return {Howl}
  void _loadQueue([String event]) {
    if (this._queue.length > 0) {
      _HowlCall task = this._queue[0];

      // Run the task if no event type is passed.
      if (event == null) {
        task.action() ;
      }
      // Remove this task if a matching event was passed.
      else if (task.event == event) {
        this._queue.removeAt(0) ;
        this._loadQueue();
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
    if (!this._webAudio && sound._node != null && !sound._node.audio.paused && !sound._node.audio.ended && sound._node.audio.currentTime < sound._stop) {
      new Timer(new Duration(milliseconds:  100), () {
        this._ended(sound) ;
      }) ;

      return ;
    }

    // Should this sound loop?
    var loop = sound._loop || this._sprite[sprite].loop ;

    // Fire the ended event.
    this._emit('end', sound._id);

    // Restart the playback for HTML5 Audio loop.
    if (!this._webAudio && loop) {
      this.stop(sound._id, true).play(sound._id);
    }

    // Restart this timer if on a Web Audio loop.
    if (this._webAudio && loop) {
      this._emit('play', sound._id);
      sound._seek = sound._start ;
      sound._rateSeek = 0;
      sound._playStart = Howler.ctx.currentTime;

      var timeout = ((sound._stop - sound._start) * 1000) ~/ sound._rate.abs() ;

      this._endTimers[sound._id] = new Timer(new Duration(milliseconds: timeout), () {
        this._ended(sound) ;
      });
    }

    // Mark the node as paused.
    if (this._webAudio && !loop) {
      sound._paused = true;
      sound._ended = true;
      sound._seek = sound._start ;
      sound._rateSeek = 0;
      this._clearTimer(sound._id);

      // Clean up the buffer source.
      this._cleanBuffer(sound._node);

      // Attempt to auto-suspend AudioContext if no sounds are still playing.
      Howler._autoSuspend();
    }

    // When using a sprite, end the track.
    if (!this._webAudio && !loop) {
      this.stop(sound._id, true);
    }
  }

  /// Clear the end timer for a sound playback.
  /// @param  {Number} id The sound ID.
  /// @return {Howl}
  void _clearTimer(id) {
    var endTimer = this._endTimers[id];

    if ( endTimer != null ) {
      // Clear the timeout or remove the ended listener.
      if ( endTimer is Timer ) {
        endTimer.cancel() ;
      }
      else {
        Sound sound = this._soundById(id);
        if (sound != null && sound._node != null) {
          sound._node.eventTarget.removeEventListener('ended', endTimer, false);
        }
      }

      this._endTimers.remove(id) ;
    }
  }

  /// Return the sound identified by this ID, or return null.
  /// @param  {Number} id Sound ID
  /// @return {Object}    Sound object or null.
  Sound _soundById(int id) {
    // Loop through all sounds and find the one with this ID.
    for (var i=0; i<this._sounds.length; i++) {
      Sound sound = this._sounds[i];
      if (sound._id == id) return sound ;
    }

    return null;
  }


  /// Return an inactive sound from the pool or create a new one.
  /// @return {Sound} Sound playback object.
  Sound _inactiveSound() {
    this._drain();

    // Find the first inactive node to recycle.
    for (var i=0; i < this._sounds.length; i++) {
      var sound = this._sounds[i];

      if (sound._ended) {
        return sound.reset();
      }
    }

    // If no inactive node was found, create a new one.
    return new Sound(this) ;
  }


  /// Drain excess inactive sounds from the pool.
  void _drain() {
    var limit = this._pool;
    var cnt = 0;

    // If there are less sounds than the max pool size, we are done.
    if (this._sounds.length < limit) {
      return;
    }

    // Count the number of inactive sounds.
    for (int i=0; i<this._sounds.length; i++) {
      if (this._sounds[i]._ended) {
        cnt++;
      }
    }

    // Remove excess inactive sounds, going in reverse order.
    for (int i=this._sounds.length - 1; i>=0; i--) {
      if (cnt <= limit) return;

      var sound = this._sounds[i];

      if (sound._ended) {
        // Disconnect the audio source when using Web Audio.
        if (this._webAudio && sound._node != null) {
          sound._node.bufferSource.disconnect(0);
        }

        // Remove sounds until we have the pool size.
        this._sounds.removeAt(i) ;
        cnt--;
      }
    }
  }


  /// Get all ID's from the sounds pool.
  /// @param  {Number} id Only return one ID if one is passed.
  /// @return {Array}    Array of IDs.
  List<int> _getSoundIds([int id]) {
    if (id == null) {
      List<int> ids = [];

      for (var i=0; i < this._sounds.length; i++) {
        ids.add( this._sounds[i]._id );
      }

      return ids;
    }
    else {
      return [id];
    }
  }


  /// Load the sound back into the buffer source.
  /// @param  {Sound} sound The sound object to work with.
  /// @return {Howl}
  void _refreshBuffer(Sound sound) {
    // Setup the buffer source for playback.
    sound._node.bufferSource = Howler.ctx.createBufferSource();
    sound._node.bufferSource.buffer = _cache[this._src];

    // Connect to the correct node.
    if ( sound._panner != null ) {
      sound._node.bufferSource.connectNode(sound._panner);
    }
    else {
      sound._node.bufferSource.connectNode(sound._node.gainNode);
    }

    // Setup looping and playback rate.
    sound._node.bufferSource.loop = sound._loop;
    if ( sound._loop ) {
      sound._node.bufferSource.loopStart = sound._start ;
      sound._node.bufferSource.loopEnd = sound._stop ;
    }
    sound._node.bufferSource.playbackRate.setValueAtTime(sound._rate, Howler.ctx.currentTime);
  }


  /// Prevent memory leaks by cleaning up the buffer source after playback.
  /// @param  {Object} node Sound's audio node containing the buffer source.
  /// @return {Howl}
  void _cleanBuffer(_HowlAudioNode node) {
    if (Howler._scratchBuffer != null && node.bufferSource != null ) {
      //node.bufferSource.onEnded = null ; TODO
      node.bufferSource.disconnect(0);

      if ( Howler.isIOS ) {
        try { node.bufferSource.buffer = Howler._scratchBuffer; } catch(e) {}
      }
    }
    node.bufferSource = null;
  }

}

class _HowlAudioNode {

  AudioElement audio ;
  GainNode gainNode ;

  AudioBufferSourceNode bufferSource ;
  bool _unlocked ;

  EventTarget get eventTarget => gainNode != null ? gainNode : audio ;

  _HowlAudioNode.audio(this.audio) ;
  _HowlAudioNode.gain(this.gainNode) ;

}

class Sound {

  final Howl _parent ;

  double _start = 0 ;
  double _stop = 0 ;

  double _volume ;

  bool _paused ;
  bool _ended ;
  int _id ;
  String _sprite ;
  double _seek ;
  double _rateSeek;
  double _rate;

  bool _loop;

  bool _muted;

  _HowlAudioNode _node ;

  AudioNode _panner ;

  Timer _interval ;

  double _fadeTo ;

  double _playStart ;

  EventListener _loadFn ;
  EventListener _errorFn ;

  Sound(this._parent) {

    var parent = this._parent;

    // Setup the default parameters.
    this._muted = parent._muted;
    this._loop = parent._loop;
    this._volume = parent._volume;
    this._rate = parent._rate;
    this._seek = 0;
    this._paused = true;
    this._ended = true;
    this._sprite = '__default';

    // Generate a unique ID for this sound.
    this._id = ++Howler._counter;

    // Add itself to the parent's pool.
    parent._sounds.add(this);

    // Create the new node.
    this.create();
  }


  /// Create and setup a new sound object, whether HTML5 Audio or Web Audio.
  /// @return {Sound}
  Sound create() {

    var parent = this._parent;
    var volume = (Howler._muted || this._muted || this._parent._muted) ? 0 : this._volume ;

    if (parent._webAudio) {
      // Create the gain node for controlling volume (the source will connect to this).
      this._node = new _HowlAudioNode.gain( Howler.ctx.createGain() ) ;

      this._node.gainNode.gain.setValueAtTime(volume, Howler.ctx.currentTime);
      //this._node.gainNode.paused = true; TODO
      this._node.gainNode.connectNode(Howler.masterGain);
    }
    else {
      // Get an unlocked Audio object from the pool.
      this._node = new _HowlAudioNode.audio( Howler._obtainHtml5Audio() ) ;

      // Listen for errors (http://dev.w3.org/html5/spec-author-view/spec.html#mediaerror).
      this._errorFn = this._errorListener ;
      this._node.audio.addEventListener('error', this._errorFn, false);

      // Listen for 'canplaythrough' event to let us know the sound is ready.
      this._loadFn = this._loadListener ;
      this._node.audio.addEventListener(Howler._canPlayEvent, this._loadFn, false);

      // Setup the new audio node.
      this._node.audio.src = parent._src[0] ;
      this._node.audio.preload = 'auto';
      this._node.audio.volume = volume * Howler.volume();

      // Begin loading the source.
      this._node.audio.load();
    }

    return this;
  }


  /// Reset the parameters of this sound to the original state (for recycle).
  /// @return {Sound}
  Sound reset() {

    var parent = this._parent;

    // Reset all of the parameters of this sound.
    this._muted = parent._muted;
    this._loop = parent._loop;
    this._volume = parent._volume;
    this._rate = parent._rate;
    this._seek = 0;
    this._rateSeek = 0;
    this._paused = true;
    this._ended = true;
    this._sprite = '__default';

    // Generate a new ID so that it isn't confused with the previous sound.
    this._id = ++Howler._counter;

    return this;
  }

  /// HTML5 Audio error listener callback.
  void _errorListener(_) {


    // Fire an error event and pass back the code.
    this._parent._emit('loaderror', this._id, this._node.audio.error != null ? this._node.audio.error.code : "0");

    // Clear the event listener.
    this._node.eventTarget.removeEventListener('error', this._errorFn, false);
  }


  /// HTML5 Audio canplaythrough listener callback.
  void _loadListener(_) {

    var parent = this._parent;

    // Round up the duration to account for the lower precision in HTML5 Audio.
    parent._duration = ((this._node.audio.duration * 10) / 10).ceilToDouble() ;

    // Setup a sprite if none is defined.
    if ( parent._sprite.length == 0 ) {
      parent._sprite = {'__default': new _HowlSpriteParams( 0, (parent._duration * 1000).floor() )};
    }

    if (parent._state != 'loaded') {
      parent._state = 'loaded';
      parent._emit('load');
      parent._loadQueue();
    }

    // Clear the event listener.
    this._node.eventTarget.removeEventListener(Howler._canPlayEvent, this._loadFn, false);
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
    Howler.ctx = new AudioContext();
  }
  catch (e) {
    Howler.usingWebAudio = false;
  }

  // If the audio context creation still failed, set using web audio to false.
  if (Howler.ctx == null) {
    Howler.usingWebAudio = false;
  }

  // Create and expose the master GainNode when using Web Audio (useful for plugins or advanced usage).
  if ( Howler.usingWebAudio) {
    Howler.masterGain = Howler.ctx.createGain() ;
    Howler.masterGain.gain.setValueAtTime(Howler._muted ? 0 : 1, Howler.ctx.currentTime);
    Howler.masterGain.connectNode(Howler.ctx.destination);
  }

  // Re-run the setup on Howler.
  Howler._setup();
}

