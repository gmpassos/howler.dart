[![howler.dart](https://github.com/gmpassos/howler.dart/blob/master/logo/howler-dart-logo.png?raw=true "howler.dart")](https://github.com/gmpassos/howler.dart)

# Description
[howler.dart](https://howlerjs.com) is an audio library for the modern web.
It defaults to [Web Audio API](http://webaudio.github.io/web-audio-api/) and
falls back to [HTML5 Audio](https://html.spec.whatwg.org/multipage/embedded-content.html#the-audio-element).
This makes working with audio in Dart easy and reliable across all platforms.

Additional information, live demos and a user showcase are available at [howlerjs.com](https://howlerjs.com).


## Usage

A simple usage example:

```dart
import 'package:howler/howler.dart';

main() {

    var howl = new Howl(
        src: ['audio/track.mp3','audio/track.wav'], // source in MP3 and WAV fallback
        loop: true,
        volume: 0.60 // Play with 60% of original volume.
    ) ;
    
    howl.play(); // Play sounce
    howl.fade(0.0, 0.60, 10000) ; // Make a fade, from volume 0% to 60% in 10s

}
```


## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/gmpassos/howler.dart/issues

## Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

MIT [license](https://github.com/angular/angular.js/blob/master/LICENSE).

## Original project in JavaScript

This library was originally written in JavaScript by [James Simpson](https://twitter.com/GoldFireStudios).
It was ported to Dart 2 code by [Graciliano M. Passos](https://github.com/gmpassos).

You can find the original project at [GitHub(howler.js)](https://github.com/goldfire/howler.js). 

Project site: [howlerjs.com](https://howlerjs.com)


