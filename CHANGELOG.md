## 1.1.2

- Improve example and README.md.
- Automatically starts user interaction detection when calling `playSafe` and `fadeSafe`.
- `Howl`: added `setUserInitialInteractionDetected`

## 1.1.1

- Added `_DetectUserInteraction` to handle internally the initial user interaction. Browser will block play/resume before that.
- Added `callback` parameter to method `load`.
- New methods:
    - `loadAndPlay`: calls `load` and after 'load' event calls `play`.
    - `playSafe`: Only calls `play` after detect user interaction.
    - `fadeSafe`: Only calls `fade` after detect user interaction.
    - `playOrPauseSwitch`: A simple play/pause switch.
- Added browser tests.
- CI: Added Firefox platform.

## 1.1.0

- dartfmt.
- lint.
- Pull `Howler.js` `v2.2.0` bug fixes.

## 1.0.10

- Fix `README.md`.

## 1.0.9

- Fix `README.md`.

## 1.0.8

- Fix some errors.
    - Thanks for the fix (by https://github.com/TobiasHeidingsfeld) 
- dartfmt.
- sdk: '>=2.7.0 <3.0.0'
- swiss_knife: ^2.5.8

## 1.0.7

- swiss_knife: ^2.3.9

## 1.0.6

- swiss_knife: ^2.3.7

## 1.0.5

- swiss_knife: ^2.3.3
- Fix bug: null pointer when playing the same sample many consecutive times (thanks to https://github.com/ferni). 
- Upgrades SDK to 2.6.0

## 1.0.4

- Upgrade dependencies.

## 1.0.1

- Added logo images.

## 1.0.0

- Ported Howler.js to Dart. Original project: https://github.com/goldfire/howler.js
- Initial version, created by Stagehand
