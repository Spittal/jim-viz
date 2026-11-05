#!/usr/bin/env python3
# Usage: gen_test_track.py out.wav truth.txt
# Synthesizes a 124 BPM test loop with known kick/clap/hat times. Writes WAV + truth file.
import math, random, struct, wave, sys
sr = 48000; bpm = float(sys.argv[3]) if len(sys.argv) > 3 else 124.0; beat = 60 / bpm; bars = 8
n = int(sr * beat * 4 * bars) + sr
buf = [0.0] * n
random.seed(1)
def add(t0, fn, dur):
    s = int(t0 * sr)
    for i in range(int(dur * sr)):
        if s + i < n: buf[s + i] += fn(i / sr)
kicks, claps, hats = [], [], []
for b in range(bars * 4):
    t = b * beat
    # Breakdown in bar 5-6: no kicks, to test auto-gain and false positives.
    if not (16 <= b < 24):
        kicks.append(t)
        ph = [0.0]
        def kick(x, ph=ph):
            f = 45 + 110 * math.exp(-x * 30)
            ph[0] += 2 * math.pi * f / sr
            return 0.9 * math.sin(ph[0]) * math.exp(-x * 7)
        add(t, kick, 0.35)
    if b % 2 == 1:
        claps.append(t)
        st = [0.0, 0.0]
        def clap(x, st=st):
            w = random.random() * 2 - 1
            st[0] += 0.35 * (w - st[0])          # low-pass ~3 kHz
            hp = st[0] - st[1]; st[1] += 0.06 * (st[0] - st[1])  # high-pass ~500 Hz
            return 1.2 * hp * math.exp(-x * 25)
        add(t, clap, 0.2)
    for h in (0.0, 0.5):
        th = t + h * beat
        hats.append(th)
        hs = [0.0]
        def hat(x, hs=hs):
            w = random.random() * 2 - 1
            out = w - hs[0]; hs[0] = w            # first difference = high-pass
            return 0.12 * out * math.exp(-x * 90)
        add(th, hat, 0.05)
# Bass line: sustained notes so bass level isn't only kicks.
for b in range(bars * 4):
    f = [55, 55, 65.4, 49][b % 4]
    add(b * beat + beat * 0.5, lambda x, f=f: 0.25 * math.sin(2 * math.pi * f * x) * min(1, x * 40) * math.exp(-x * 4), beat * 0.45)
# Crude high-pass on claps/hats is implicit; normalize.
peak = max(abs(v) for v in buf)
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(b''.join(struct.pack('<h', int(max(-1, min(1, v / peak * 0.8)) * 32767)) for v in buf))
with open(sys.argv[2], 'w') as f:
    for name, ts in (('kick', kicks), ('snare', claps), ('hat', hats)):
        f.write(name + ' ' + ' '.join('%.4f' % t for t in ts) + '\n')
