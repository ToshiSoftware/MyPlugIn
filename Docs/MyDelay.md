# MyDelay

Stereo delay. Sources: `Sources/MyDelay`; tests: `Tests/MyDelayTests`.

| Mode | Routing | Faders |
|---|---|---|
| Mono Delay | L+R into one line; the same echoes on both sides | TIME, FEEDBACK, MIX |
| Stereo Delay | L and R through their own lines, same settings | TIME, FEEDBACK, WIDTH, MIX |
| Doubler | L+R, left at TIME, right at TIME x 1.5; no feedback | TIME, WIDTH, MIX |
| Ping-Pong | L+R into the left line, which feeds the right and back | TIME, FEEDBACK, WIDTH, MIX |

| Parameter | Range | Default |
|---|---|---|
| MODE | the four modes above | Stereo Delay |
| TIME | 1 ms to 10 s (fader is logarithmic) | 250 ms |
| FEEDBACK | 0 to 100 % | 30 % |
| WIDTH | 0 (echoes centred) to 100 % (fully apart) | 100 % |
| MIX | 0 to 100 % wet | 100 % |
| SYNC | Off / On: TIME follows the host's tempo | Off |
| NOTE | 1/64, 1/32, 1/16, 1/8, 1/4, 1/2, 1 bar, 2 bars, 4 bars | 1/4 |
| TYPE | Normal, Triplet (x 2/3), Dotted (x 1.5) | Normal |

Tempo sync (2026-10-14): with SYNC on, the TIME fader steps through the note
lengths (shortest at the bottom; value shown as "1/8", "1/8T", "1/8D"), and
TIME = note length x type at the host's tempo, from the AU musical context
(`musicalContextBlock`, read at the start of each render; 120 BPM 4/4 when
the host gives none). A bar is the host's time signature in quarter notes
(MyDAW reports 4/4). The result is kept within 1 ms to 10 s. Doubler's right
side stays at TIME x 1.5. A tempo change moves TIME with the usual 40 ms
crossfade. The SYNC row above the faders shows the tempo and the time in ms.
An in-process host (MyDAW) gives its blocks through `MyFXHostContext`
instead: AVAudioEngine sets every unit's `musicalContextBlock` to nil when
it stops, so a unit reallocated after a stop lost the tempo (heard as the
120 BPM default, 2026-10-14).
Addresses 5, 6, 7 (`sync`, `sync_note`, `sync_type`).

Changing TIME crossfades between the old and new read positions (40 ms), so
it neither clicks nor bends the pitch. Changing MODE fades the echoes and
the line input out, clears the lines and fades back in (10 ms each way).
What enters a line is untouched up to full scale and eased toward 1.25
above it, so 100 % feedback holds the repeats without growing without bound.
