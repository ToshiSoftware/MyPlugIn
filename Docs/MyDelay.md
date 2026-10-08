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

Changing TIME crossfades between the old and new read positions (40 ms), so
it neither clicks nor bends the pitch. Changing MODE fades the echoes and
the line input out, clears the lines and fades back in (10 ms each way).
What enters a line is untouched up to full scale and eased toward 1.25
above it, so 100 % feedback holds the repeats without growing without bound.
