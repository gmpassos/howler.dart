import 'package:howler/howler.dart';

void main() {
  var howl = Howl(
      src: [
        'audio/track.mp3',
        'audio/track.wav'
      ], // source in MP3 and WAV fallback
      loop: true,
      volume: 0.60 // Play with 60% of original volume.
      );

  howl.play(); // Play sound.
  howl.fade(0.0, 0.60, 10000); // Make a fade, from volume 0% to 60% in 10s
}
