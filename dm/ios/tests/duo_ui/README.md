# iOS UI test harness

This app exercises the production iOS front end with a synthetic Metal picture and host/input stubs. It contains 70 XCTest cases covering portrait and landscape geometry, independent touch profiles, in-game editing transactions, input suppression, pause ownership, hinge visibility, and reflection preferences. It does not load or execute a game. No game assets, extracted modules, RomFS, keys, or generated game profile are required; `Fixtures/game_profile.h` supplies only the test pad layout.

## Requirements

- Xcode 27.1 or newer, selected as the active developer directory.
- An iOS 27.1 or newer simulator runtime. The project targets arm64.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) on `PATH`.

All project and header paths are relative to this directory. The app target compiles `../../Sources` while excluding the production `main.m`; `PreviewHost.m` provides the harness entry point and host stubs. The tests use a dedicated `org.nxnative.duo-ui-preview` preferences domain and restore its saved preferences after each fixture.

## Run the suite

From the repository root:

```sh
cd dm/ios/tests/duo_ui
xcodegen generate
xcrun simctl list devices available
```

Select an available simulator from the list, then set its identifier in your own shell. Do not use a physical-device identifier for this command.

```sh
DUO_UI_SIMULATOR="replace-with-your-simulator-identifier"
DUO_UI_RESULT="TestResults-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project DuoUIPreview.xcodeproj \
  -scheme DuoUIPreview \
  -destination "platform=iOS Simulator,id=$DUO_UI_SIMULATOR" \
  -derivedDataPath DerivedData \
  -resultBundlePath "$DUO_UI_RESULT" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -jobs 3 test
```

Tests share process-level input and pause fixtures, so keep parallel testing disabled. Each result bundle must have a new path. Generated projects, Info.plist, build products, result bundles, and logs are ignored and should not be committed.

## Visual preview and limits

Run the generated `DuoUIPreview` scheme in Xcode to inspect the real controls and reflection against the synthetic picture. The preview has black, white-spot, checkerboard, and animated-color patterns controlled by its own `ReflectionTestPattern` preference (1, 2, 3, and 0 respectively). Its `Documents/ui-state.json` is a runtime diagnostic, not a source fixture. Controller enumeration and accelerometer callbacks are replaced only inside the harness process; these test stubs are not included in a game IPA.

The simulator uses the classic `MTLCommandBuffer` capture path. A device build also contains a synthetic Metal 4 producer that exercises the shared-event capture bridge when available, but simulator success does not validate the device Metal 4 queue path. Device-target compilation alone is not a runtime test. This harness does not link the NVN game renderer or establish game compatibility, real-device performance, memory headroom, or signing/installability.

The automated assertions cover settings, lifecycle, rendering-surface structure, and input/pause behavior. Pixel-level blur should also be checked with the synthetic patterns: black remains black, a white spot blurs locally, and blur changes plus off/on toggles update the cached picture while the gear editor pauses the source. Physical-device Metal 4 validation remains a separate check.
