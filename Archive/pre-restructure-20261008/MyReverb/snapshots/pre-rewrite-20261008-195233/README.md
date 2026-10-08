# MyReverb

AUv3 stereo effect plugin for macOS.

The current frame is intentionally a transparent audio unit. Its parameter tree already uses the corrected specification:

- HPF: Thru to 1 kHz, default 80 Hz
- LPF: 200 Hz to Thru, default 8 kHz
- RT: 0.1 to 60 seconds, default 2 seconds
- PD: 0 to 1 second, default 20 ms
- MIX: 0 to 100 percent, default 100 percent wet

The next DSP slice is pre-delay, followed by a small feedback delay network and third-order Butterworth filters.