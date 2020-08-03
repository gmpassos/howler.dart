import 'package:howler/howler.dart';

void main() {
  var howl = Howl(
      src: [
        'audio/track.mp3',
        'audio/track.wav'
      ], // source in MP3 and WAV fallback
      loop: true, // Loops the sound when play ends.
      volume: 0.60, // Play with 60% of original volume.
      preload: false // Automatically loads source.
      );

  // Calls `load` and after 'load' event, calls `play` and `callback`:
  howl.loadAndPlay(
      safe: true, // Checks for initial user interaction before play.
      callback: () {
        // Callback is called only after play call.
        // Make a fade, from volume 0% to 60% in 10s:
        howl.fade(0.0, 0.60, 10000);
      });
}
