# MyReverb

Stereo plate reverb. Sources: `Sources/MyReverb`; tests: `Tests/MyReverbTests`.

| Parameter | Range | Default |
|---|---|---|
| HPF | Thru (0) to 1 kHz | 80 Hz |
| LPF | 200 Hz to 24 kHz (Thru) | 8 kHz |
| RT | 0.1 to 60 s | 2 s |
| PD (pre-delay) | 0 to 1 s | 20 ms |
| MIX | 0 to 100 % wet | 100 % |

Signal path: pre-delay (crossfades between delay times), two all-pass
diffusers per side, an 8-line feedback delay network with a Hadamard matrix
and an all-pass (gain 0.5) in each feedback path so echo density rises with
every reflection, then 3rd-order Butterworth HPF and LPF on the wet signal,
then mix.

RT is the time for the tail to fall 60 dB in the low and middle range (each
line's feedback gain is set from its own length); the treble decays in about
half that time, as on a plate. Long RTs are held to the loudness of a 2 s
tail. Fully linear: no limiting anywhere.

Fader tapers: HPF and LPF logarithmic (HPF bottom and LPF top are Thru), RT
logarithmic, PD square law (middle = 250 ms), MIX linear.
