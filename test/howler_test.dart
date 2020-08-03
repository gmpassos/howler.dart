import 'package:howler/howler.dart';
import 'package:swiss_knife/swiss_knife.dart';
import 'package:test/test.dart';

@TestOn('browser')
void _sleep(int sleepMs) async {
  if (sleepMs <= 0) return;
  print('SLEEP> ${sleepMs}ms');
  await Future.delayed(Duration(milliseconds: sleepMs), () {});
}

void _sleepUntilCondition(
    String conditionName, int timeout, bool Function() conditionTester) async {
  print('-------------------------------------');
  print('SLEEP UNTIL CONDITION[$conditionName]> timeout: $timeout');

  var init = DateTime.now().millisecondsSinceEpoch;

  while (true) {
    if (conditionTester()) {
      print('CONDITION[$conditionName] OK');
      break;
    }

    var elapsed = DateTime.now().millisecondsSinceEpoch - init;
    var remaining = timeout - elapsed;

    if (remaining > 0) {
      var sleep = remaining;
      if (sleep < 100) {
        sleep = 100;
      } else if (sleep > 500) {
        sleep = 500;
      }

      print(
          'sleep: $sleep ; elapsed: $elapsed ; remaining: $remaining ; timeout: $timeout');
      await _sleep(sleep);
    } else {
      break;
    }
  }
  print('-------------------------------------');
}

void main() {
  group('Browser Tests', () {
    setUp(() {});

    test('Basic load', () async {
      print('Uri Base: ${getUriBase()}');

      var howl = Howl(src: [
        'piano-sample.mp3',
      ], loop: false, preload: false, volume: 0.60);

      prints('Howl: $howl');

      expect(howl, isNotNull);

      expect(howl.getVolume(), 0.60);

      expect(howl.isLoaded, isFalse);
      howl.load();
      await _sleepUntilCondition('howl.isLoaded', 5000, () => howl.isLoaded);
      expect(howl.isLoaded, isTrue);

      expect(howl.playing(), isFalse);
      howl.play();
      howl.fade(0, 0.90, 100);
      await _sleepUntilCondition('howl.playing()', 5000, () => howl.playing());
      expect(howl.playing(), isTrue);

      await _sleepUntilCondition(
          'howl.getVolume() == 0.90', 5000, () => howl.getVolume() == 0.90);
      expect(howl.getVolume(), equals(0.90));
    });
  });
}
