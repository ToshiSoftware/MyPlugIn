# MyPlugIn

Audio effects for MyDAW, built in as MyDAW's own plug-ins and also packaged
as AUv3 extensions for other hosts (Logic, ...).

| Effect | Subtype | Notes |
|---|---|---|
| MyReverb | `MRev` | Plate reverb: HPF, LPF, RT, PD, WIDTH, MIX ([Docs/MyReverb.md](Docs/MyReverb.md)) |
| MyDelay | `MDly` | Mono / Stereo / Doubler / Ping-Pong delay ([Docs/MyDelay.md](Docs/MyDelay.md)) |
| MyChannelStrip | `MStp` | 4-band EQ with spectrum, compressor, output gain ([Docs/MyChannelStrip.md](Docs/MyChannelStrip.md)) |
| MyMaximizer | `MMax` | Mastering limiter: input gain, upward compression, look-ahead ceiling with attack/release (10 ms latency), history graph ([Docs/MyMaximizer.md](Docs/MyMaximizer.md)) |
| MyChorusPan | `MChP` | Modulation in four modes, each with its own settings and an INIT button for the recommended ones: Chorus Pedal, Dimension (buttons 1 to 4), Flanger Pedal, Auto Pan; SPEED lamp ([Docs/MyChorusPan.md](Docs/MyChorusPan.md)) |

In MyDAW they are "MyDAW: MyReverb" etc. (`aufx` subtype `MyDA`); in other
hosts "Toka: MyReverb" etc. (`aufx` subtype `Toka`). Subtypes, parameter
addresses and identifiers are saved in projects: never change them.

## Layout

```
Package.swift            one package; `plugIns` lists the effects
Sources/
  MyPlugInCore/          shared by every effect
    AudioUnit/           MyFXAudioUnit (base AU), MyFXParameter, MyFXKernel
                         (latencySamples is reported as the AU's latency),
                         MyFXExtensionViewController (AUv3 extensions)
    Editor/              editor in MyDAW's mixer look (300 x 424 unless an effect
                         sets MyFXAudioUnit.editorSize), with the channel name
                         from the host's AU contextName; meter rows (optional
                         CLIP lamp), vertical and horizontal faders
    Rendering/           render block, input/output peak meters
  MyReverb/, MyDelay/,   one folder per effect: Parameter, Kernel, AudioUnit, Editor
  MyChannelStrip/, MyMaximizer/
  MyPlugInCatalog/       the list of effects; hosts register them all from here
Tests/                   one test target per effect, plus Core and Catalog
Tools/
  new-plugin.sh          creates an effect from Templates/NewPlugIn
  make-host-project.py   writes Hosts/MyPlugInHost from Package.swift
  MyPlugInSnapshots/     writes every editor to PNG
Templates/NewPlugIn/     template effect (gain + mix) with tests
Hosts/MyPlugInHost/      MyPlugIn.app with one AUv3 extension per effect
Docs/                    per-effect notes
Archive/                 earlier code, for reference only
```

An effect is four files: its parameters (`MyFXParameter` enum), its signal
path (`MyFXKernel`), a small `MyFXAudioUnit` subclass, and its editor (fader
tapers and layout). Everything else - parameter tree, state, formats,
bypass, reset, rendering, meters, editor frame - comes from MyPlugInCore.

MyDAW compiles all of `Sources/` into its own single module, so:
- targets import each other only `#if canImport(...)`;
- type names carry a prefix: `MyFX...` in the core, `Reverb...`/`Delay...` in effects.

## Work

```sh
# Test everything (keep build products out of Google Drive)
swift test --scratch-path ~/Library/Caches/MyPlugIn-build

# Look at every editor
swift run --scratch-path ~/Library/Caches/MyPlugIn-build MyPlugInSnapshots ~/Desktop/editors

# New effect (name "My" + capital; four-character subtype)
Tools/new-plugin.sh MyChorus Chrs

# Into MyDAW, then build MyDAW
../MyDAW/scripts/sync-myplugin.sh
```

`new-plugin.sh` adds the effect to `Package.swift`, MyPlugInCatalog and the
host app; MyDAW lists it after the next sync and build, with no change in
MyDAW's code. For other hosts see [Hosts/MyPlugInHost/README.md](Hosts/MyPlugInHost/README.md).
