# MyReverb

Stereo plate reverb for macOS: an AUv3 app extension, and a built-in effect of MyDAW.

## Parameters

| Parameter | Range | Default |
|---|---|---|
| HPF | Thru (0) to 1 kHz | 80 Hz |
| LPF | 200 Hz to 24 kHz (Thru) | 8 kHz |
| RT | 0.1 to 60 s | 2 s |
| PD (pre-delay) | 0 to 1 s | 20 ms |
| MIX | 0 to 100 % wet | 100 % |

The tank is an 8-line feedback delay network with an all-pass (gain 0.5)
in each feedback path, so echo density rises with every reflection.
HPF and LPF are 3rd-order Butterworth filters on the wet signal. RT is the
time for the tail to fall 60 dB in the low and middle range; the treble
decays in about half that time, as on a plate.

## Layout

- `MyReverbKit/` – Swift package with all the code; one target, no internal imports.
  - `ReverbParameter.swift` – parameter addresses, ranges, defaults, display strings.
  - `ReverbComponents.swift` – pre-delay, diffusers, 8-line FDN tank, Butterworth sections.
  - `ReverbKernel.swift` – the signal path, smoothing, reset and bypass; no AU APIs.
  - `MyReverbAudioUnit.swift` – the `AUAudioUnit` subclass (events, formats, state).
  - `MyReverbEditor.swift` – fader tapers and the five-fader editor, returned by `requestViewController`.
  - `Tests/` – RT accuracy, levels, clicks, filters, pre-delay, reset, AU rendering and state.
- `MyReverbExtension/` – the AUv3 extension (`aufx` `MRev` `Toka`), a factory around `MyReverbAudioUnit`.
- `MyReverbApp/` – the container app that installs the extension.

## Build and test

```sh
# Tests (keep build products out of Google Drive)
cd MyReverbKit
swift test --scratch-path ~/Library/Caches/MyReverbKit-build

# Extension: build the MyReverb scheme in Xcode, run the app once, then
auval -v aufx MRev Toka
```

The editor frame, meters and render block come from `../MyFXShared`, shared
with MyDelay.

## MyDAW

MyDAW compiles copies of `MyReverbKit/Sources/MyReverbKit/*.swift` (in
`MyDAW/Sources/BuiltIn/MyReverb`, with MyFXShared) and registers the unit
in-process as `aufx` `MRev` `MyDA`, named "MyDAW: MyReverb". After changing
the sources here, run `MyDAW/scripts/sync-builtin-plugins.sh` and rebuild MyDAW.
