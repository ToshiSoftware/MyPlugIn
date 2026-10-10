# MyReverb

Stereo plate reverb. Sources: `Sources/MyReverb`; tests: `Tests/MyReverbTests`.

| Parameter | Address | Range | Default |
|---|---|---|---|
| HPF | 0 | Thru (0) to 1 kHz | 80 Hz |
| LPF | 1 | 200 Hz to 24 kHz (Thru) | 8 kHz |
| RT | 2 | 0.1 to 60 s | 2 s |
| PD (pre-delay) | 3 | 0 to 1 s | 20 ms |
| MIX | 4 | 0 to 100 % wet | 100 % |
| WIDTH | 5 | 0 (mono) to 100 % | 100 % |

Faders, left to right: HPF, LPF, RT, PD, WIDTH, MIX. Tapers: HPF and LPF
logarithmic (HPF bottom and LPF top are Thru), RT logarithmic, PD square law
(middle = 250 ms), WIDTH and MIX linear. WIDTH was added later; saved states
without it load at 100 %.

## Signal path

Pre-delay (crossfades between delay times), two all-pass diffusers per side,
an 8-line feedback delay network with a Hadamard matrix and an all-pass
(gain 0.5) in each feedback path, so echo density rises with every
reflection; then the stereo image stage (WIDTH), then 3rd-order Butterworth
HPF and LPF on the wet signal, then mix.

- **Lines**: 31 to 97 ms, irregularly spaced primes, each with its own
  absorbent filter. RT is the time to fall 60 dB in the low and middle
  range (each line's feedback gain comes from its own length); the treble
  decays in about 0.7 of that time, as on a plate. Long RTs are held to the
  loudness of a 2 s tail. Fully linear: no limiting anywhere.
- **Output taps**: each side also reads its lines part way along, so the
  tail peaks about 40 ms in. Each side taps only the lines its own input
  feeds, so a panned source stays on its side for the first 50 to 100 ms
  (hard left: about +30 dB, then +13 dB), then spreads evenly.
- **Stereo image**: the side signal below 200 Hz is raised x1.3, so the low
  end is slightly anti-phase between the speakers; WIDTH then scales the
  whole side signal (0 % mono, 100 % as tuned, uncorrelated). Left and right
  are equally loud. WIDTH is smoothed like MIX.

## Tuning

Tuned against impulse responses of Relab LX480 Essentials (Plate, RT 1.98 s),
captured offline from its Audio Unit, comparing the envelope, L/R
correlation per octave, level difference, echo density and the response to
a panned input:

| | LX480 Plate | MyReverb |
|---|---|---|
| Tail peak | 50 ms | 40 ms |
| 40 to 60 ms vs 130 to 160 ms | +3.5 dB | +3.9 dB |
| L/R correlation 125 Hz (early / late) | -0.13 / -0.25 | -0.50 / -0.07 |
| Hard-left input, L-R at 0-20 / 20-70 ms | +28 / +9 dB | +33 / +12 dB |
| Wet level, first second | reference | same |

The wet level matches the LX480's, so the two can be compared at equal
loudness.

## Tried and dropped

- **Separate early reflections** (left-only and right-only taps, then a
  crossed inverted copy 33 to 37 ms later): the LX480 plate has no separable
  early reflections; its first 100 ms is the start of the tail.
- **Left bias** (2 dB, after the LX480 plate's louder left side in its first
  100 ms): as a fixed gain it kept long tails on the left.
- **WIDTH above 100 %**, by more side signal or by an inverted 0.8 ms
  cross-feed (binaural): no audible gain.
- **Line length sets**, compared by ear through a PLATE menu (address 6 in
  test builds only). Measured on the 80 to 800 ms tail at RT 2 s ("repeat":
  largest autocorrelation of the envelope ripple):

  | Lines | Repeat | Notes |
  |---|---|---|
  | 34 to 85 ms | 0.16 every 80 ms | the original; heard as repeats |
  | **31 to 97 ms, irregular** | **0.12** | **chosen** |
  | 25 to 135 ms, golden ratio | 0.12 | |
  | 45 to 130 ms, geometric | 0.14 | grainier start |
  | 66 to 150 ms, Dattorro ratios | 0.22 at 10 ms | grain closest to the LX480 plate |

When comparing with another plug-in on the same channel, note that some
plug-ins change the channel layout when bypassed (the LX480 plays its left
input on both sides), which makes everything before it mono. MyDAW now
switches plug-ins off without their bypass.
