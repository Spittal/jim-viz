#!/usr/bin/env python3
# Usage: add_pad.py in.wav out.wav
# Adds a loud sustained saw pad and sub bass to the test track, changing chord off the beat, so
# the onset check can score hits under sustained harmony (chord changes must not fire kicks).
import math, struct, wave, sys
w = wave.open(sys.argv[1]); sr = w.getframerate(); n = w.getnframes()
x = list(struct.unpack('<%dh' % n, w.readframes(n))); w.close()
beat = 60 / 124
chords = [[220, 261.6, 329.6], [196, 246.9, 293.7], [174.6, 220, 261.6], [196, 246.9, 311.1]]
out = []
for i in range(n):
    t = i / sr
    seg = int((t - beat * 0.75) // (beat * 2)) if t >= beat * 0.75 else -1
    ch = chords[seg % 4]
    since = t - (beat * 0.75 + seg * beat * 2) if seg >= 0 else t
    env = min(1, since / 0.03)
    pad = sum(((t * f * (1 + d)) % 1) * 2 - 1 for f in ch for d in (-0.004, 0.004)) / 6
    sub = math.sin(2 * math.pi * ch[0] / 4 * t)
    out.append(x[i] / 32767 + env * (0.35 * pad + 0.4 * sub))
peak = max(abs(v) for v in out)
o = wave.open(sys.argv[2], 'wb'); o.setnchannels(1); o.setsampwidth(2); o.setframerate(sr)
o.writeframes(b''.join(struct.pack('<h', int(v / peak * 0.8 * 32767)) for v in out)); o.close()
