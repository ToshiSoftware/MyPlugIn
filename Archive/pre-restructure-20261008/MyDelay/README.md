# MyDelay

Stereo delay, a built-in effect of MyDAW. Same look as MyReverb (MyFXShared).

## Modes

| Mode | Routing | Faders |
|---|---|---|
| Mono Delay | L+R into one line; the same echoes on both sides | TIME, FEEDBACK, MIX |
| Stereo Delay | L and R through their own lines, same settings | TIME, FEEDBACK, WIDTH, MIX |
| Doubler | L+R, left at TIME, right at TIME x 1.5; no feedback | TIME, WIDTH, MIX |
| Ping-Pong | L+R into the left line, which feeds the right and back | TIME, FEEDBACK, WIDTH, MIX |

## Parameters

| Parameter | Range | Default |
|---|---|---|
| MODE | the four modes above | Stereo Delay |
| TIME | 1 ms to 10 s (fader is logarithmic) | 250 ms |
| FEEDBACK | 0 to 100 % | 30 % |
| WIDTH | 0 (echoes centred) to 100 % (fully apart) | 100 % |
| MIX | 0 to 100 % wet | 100 % |

Changing TIME crossfades between the old and new read positions (40 ms), so
it neither clicks nor bends the pitch. Changing MODE fades the echoes out,
clears the lines and fades back in (10 ms each way). What enters a line is
untouched up to full scale and eased toward 1.25 above it, so 100 % feedback
holds the repeats without growing without bound.

## Layout and tests

- `MyDelayKit/Sources/MyDelayKit/` – `DelayParameter`, `DelayKernel` (DSP, no AU APIs),
  `MyDelayAudioUnit`, `MyDelayEditor`.
- `MyDelayKit/Tests/` – echo times, levels and sides per mode, width, mix, full
  feedback, clicks on time and mode changes, reset, bypass, AU rendering and state.

```sh
cd MyDelayKit
swift test --scratch-path ~/Library/Caches/MyDelayKit-build
```

After changing the sources, run `MyDAW/scripts/sync-builtin-plugins.sh` and
rebuild MyDAW. MyDAW registers the unit as `aufx` `MDly` `MyDA`, "MyDAW: MyDelay".
