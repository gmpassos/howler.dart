[![howler.dart](https://github.com/gmpassos/howler.dart/blob/master/logo/howler-dart-logo.png?raw=true "howler.dart")](https://github.com/gmpassos/howler.dart)


[![pub package](https://img.shields.io/pub/v/howler.svg?logo=dart&logoColor=00b9fc)](https://pub.dartlang.org/packages/howler.dart)
[![CI](https://img.shields.io/github/workflow/status/gmpassos/howler.dart/Dart%20CI/master?logo=github-actions&logoColor=white)](https://github.com/gmpassos/howler.dart/actions)
[![GitHub Tag](https://img.shields.io/github/v/tag/gmpassos/howler.dart?logo=git&logoColor=white)](https://github.com/gmpassos/howler.dart/releases)
[![New Commits](https://img.shields.io/github/commits-since/gmpassos/howler.dart/latest?logo=git&logoColor=white)](https://github.com/gmpassos/howler.dart/network)
[![Last Commits](https://img.shields.io/github/last-commit/gmpassos/howler.dart?logo=git&logoColor=white)](https://github.com/gmpassos/howler.dart/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/gmpassos/howler.dart?logo=github&logoColor=white)](https://github.com/gmpassos/howler.dart/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/gmpassos/howler.dart?logo=github&logoColor=white)](https://github.com/gmpassos/howler.dart)
[![License](https://img.shields.io/github/license/gmpassos/howler.dart?logo=open-source-initiative&logoColor=green)](https://github.com/gmpassos/howler.dart/blob/master/LICENSE)
[![Funding](https://img.shields.io/badge/Donate-yellow?labelColor=666666&style=plastic&logo=liberapay)](https://liberapay.com/gmpassos/donate)
[![Funding](https://img.shields.io/liberapay/patrons/gmpassos.svg?logo=liberapay)](https://liberapay.com/gmpassos/donate)


# Description
[howler.dart](https://howlerjs.com) is an audio library for the modern web.
It defaults to [Web Audio API](https://webaudio.github.io/web-audio-api/) and
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
    
    howl.play(); // Play sound.
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


