#!/usr/bin/python3 -I
"""Bakes AIST++ advanced dances into the Dancer's clip format (.jvmc).

    scripts/bake-motion.py [--fetch] [--audit]

AIST++ (https://google.github.io/aistplusplus_dataset/) is Google's SMPL fits of the AIST Dance
Video Database, ten street and jazz styles, licensed CC BY 4.0 (see Content/Motion/ATTRIBUTION.md).
The Dancer plays its advanced dances (AIST's sFM, about 21 a style): whole choreographed
performances of 30-50 seconds, each danced to one song of a known tempo. Its short basic
routines (sBM) aren't used. The clips are baked into the repo's Content/Motion/<style>/ and ship
with the app.

Google's own download has only some of the sequences; all 1,408 are in the EDGE project's bundle
(https://github.com/Stanford-TML/EDGE), whose `motions` folder is kept in
~/Library/Caches/jim-viz/mocap/motions. --fetch downloads the bundle, keeps that folder and
deletes the rest (it also holds AIST's music, which isn't used). --audit prints each
performance and what's kept of it, and writes nothing. Needs only the standard library.

A sequence is SMPL's joints as axis-angle turns. Its 22 body joints are the Dancer's skeleton:
  0 pelvis, 1 left hip, 2 right hip, 3 spine1, 4 left knee, 5 right knee, 6 spine2, 7 left ankle,
  8 right ankle, 9 spine3, 10 left toes, 11 right toes, 12 neck, 13 left collar, 14 right collar,
  15 head, 16 left shoulder, 17 right shoulder, 18 left elbow, 19 right elbow, 20 left wrist,
  21 right wrist.
A clip keeps a local rotation per joint in the app's axes (+x front, +y up, +z the dancer's
right), smoothed. The hips' position is in hip heights (1 = standing straight) over a floor at
0, centred on the clip's middle, and the clip is turned so the dancer faces +x on average. Its
tempo is its song's, from its name, and its first beat is its first frame.

What's kept of a performance: its bars, on its song's bar lines, less any bars standing about
at its start and end. Where the fit glitches (a limb flipping, a joint far faster than the 10
m/s or so a dancer's fastest move reaches), it's bridged with a curve from the frames either
side, over up to a second; one that can't be (a mess of them, a breaker tangled on the floor)
splits the performance in two, and a piece under two bars is dropped.

File (little-endian), read by Render/MotionClip.swift:
  "JVMC", uint32 frames, float32 fps (30), float32 bpm, float32 first beat (seconds),
  float32 beats (how many the clip plays, whole bars), uint32 joints (22), uint32 payload bytes;
  then the payload, raw DEFLATE of 91 int16 channels a frame: the hips' position (x, y, z, in
  1/4096 hip heights) and each joint's quaternion (x, y, z, w, in 1/32767). Each channel is
  stored through time as second differences (wrapping at 16 bits), the values' low bytes
  first, then their high bytes, which deflate packs about three to one. Played back at 60 fps
  on Catmull-Rom curves, it's within a millimetre of the 60 fps capture.
"""
import io, math, os, pickle, shutil, struct, sys, urllib.request, zipfile, zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.expanduser("~/Library/Caches/jim-viz/mocap")
BUNDLE = "https://drive.usercontent.google.com/download?id=1RzqSbSnbMEwLUagV0GThfpm9JJXePGkV&export=download&confirm=t"
# AIST's genres as the Dancer's styles (MotionLibrary.styles): break, pop, lock, middle hip-hop,
# LA-style hip-hop, house, waack, krump, street jazz, ballet jazz.
STYLE = {"gBR": "break", "gPO": "popping", "gLO": "locking", "gMH": "hiphop", "gLH": "lahiphop", "gHO": "house",
         "gWA": "waacking", "gKR": "krump", "gJS": "streetjazz", "gJB": "balletjazz"}
JOINTS = 22
PARENTS = [-1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 12, 13, 14, 16, 17, 18, 19]
FPS = 60          # AIST++'s
STEP = 2          # stored every other frame: 30 fps, played back with cubic interpolation
# A bar slower than this (m/s, the joints against the hips) is standing about.
IDLE = 0.15

# A reference human (metres, app axes), each joint from its parent: to find the floor under a
# clip, spot glitches and score it. The Dancer's bodies bring their own proportions.
REF = [(0, 0, 0), (0, -0.085, -0.07), (0, -0.085, 0.07), (0, 0.11, 0), (0, -0.385, 0), (0, -0.385, 0), (0, 0.135, 0),
       (0, -0.4, 0), (0, -0.4, 0), (0, 0.055, 0), (0.12, -0.055, 0), (0.12, -0.055, 0), (0, 0.21, 0), (0, 0.12, -0.08),
       (0, 0.12, 0.08), (0, 0.09, 0), (0, 0.03, -0.11), (0, 0.03, 0.11), (0, 0, -0.26), (0, 0, 0.26), (0, 0, -0.25), (0, 0, 0.25)]
# How far under the ankle, the ball of the foot and any other joint the body reaches.
REF_SOLE, REF_TOE, REF_BODY = 0.075, 0.02, 0.06
REF_HIP_HEIGHT = 0.085 + 0.385 + 0.4 + REF_SOLE
# A joint moving faster than this (m/s) is a glitch in the fit, not dancing (dancing peaks near 10).
GLITCH = 15.0
# The longest bridge over a glitch, frames; a longer glitch is cut out.
REPAIR = 60
UPPER, LOWER = [15, 18, 19, 20, 21], [4, 5, 7, 8]

# ---------------------------------------------------------------- quaternions (w, x, y, z)

def qmul(a, b):
    aw, ax, ay, az = a; bw, bx, by, bz = b
    return (aw * bw - ax * bx - ay * by - az * bz, aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx, aw * bz + ax * by - ay * bx + az * bw)

def qconj(q): return (q[0], -q[1], -q[2], -q[3])

def qrot(q, v):
    w, x, y, z = q
    vx, vy, vz = v
    tx, ty, tz = 2 * (y * vz - z * vy), 2 * (z * vx - x * vz), 2 * (x * vy - y * vx)
    return (vx + w * tx + y * tz - z * ty, vy + w * ty + z * tx - x * tz, vz + w * tz + x * ty - y * tx)

def qexp(v):
    """An axis-angle vector as a quaternion."""
    a = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    if a < 1e-9: return (1.0, 0.0, 0.0, 0.0)
    s = math.sin(a / 2) / a
    return (math.cos(a / 2), v[0] * s, v[1] * s, v[2] * s)

def to_app(v):
    """A vector from SMPL's axes (+x the dancer's left, +y up, +z front) to the app's."""
    return (v[2], v[1], -v[0])

def q_to_app(q): return (q[0], q[3], q[2], -q[1])

# ---------------------------------------------------------------- reading a sequence

class _Arrays(pickle.Unpickler):
    """Reads a pickle of numpy arrays without numpy, and nothing else: an array comes back with
    its shape and its values."""
    def find_class(self, module, name):
        if (module, name) in (("numpy.core.multiarray", "_reconstruct"), ("numpy._core.multiarray", "_reconstruct")):
            return lambda *a: _Array()
        if (module, name) == ("numpy", "ndarray"): return _Array
        if (module, name) == ("numpy", "dtype"): return lambda code, *a: _Dtype(code)
        if (module, name) in (("numpy.core.multiarray", "scalar"), ("numpy._core.multiarray", "scalar")):
            return lambda dtype, data: struct.unpack("<" + dtype.format, data)[0]
        raise pickle.UnpicklingError("not allowed in a motion pickle: %s.%s" % (module, name))

class _Dtype:
    def __init__(self, code): self.format = {"f4": "f", "f8": "d", "i8": "q", "i4": "i"}[code]
    def __setstate__(self, state): pass

class _Array:
    def __setstate__(self, state):
        _, shape, dtype, _, data = state
        n = 1
        for s in shape: n *= s
        self.shape, self.values = shape, struct.unpack("<%d%s" % (n, dtype.format), data)

def load(data):
    """A motion pickle as, per frame, the hips' position (metres, app axes) and each joint's
    world rotation."""
    d = _Arrays(io.BytesIO(data)).load()
    poses, trans, scaling = d["smpl_poses"], d["smpl_trans"], d["smpl_scaling"].values[0]
    root, world = [], []
    for f in range(poses.shape[0]):
        p = poses.values[f * 72:(f + 1) * 72]
        w = [None] * JOINTS
        for j in range(JOINTS):
            q = q_to_app(qexp(p[j * 3:j * 3 + 3]))
            w[j] = q if j == 0 else qmul(w[PARENTS[j]], q)
        world.append(w)
        t = trans.values[f * 3:f * 3 + 3]
        root.append(to_app((t[0] / scaling, t[1] / scaling, t[2] / scaling)))
    return root, world

# ---------------------------------------------------------------- baking

def ref_positions(root, world):
    """Every joint of the reference human in a pose, the hips at `root` (metres)."""
    pos = [root] * JOINTS
    for j in range(1, JOINTS):
        o = qrot(world[PARENTS[j]], REF[j])
        p = pos[PARENTS[j]]
        pos[j] = (p[0] + o[0], p[1] + o[1], p[2] + o[2])
    return pos

def smooth(rows, passes):
    """A zero-phase low-pass along time: a binomial kernel, `passes` times. rows[f] is a flat list."""
    for _ in range(passes):
        n = len(rows)
        out = []
        for f in range(n):
            a, b, c, d, e = rows[max(f - 2, 0)], rows[max(f - 1, 0)], rows[f], rows[min(f + 1, n - 1)], rows[min(f + 2, n - 1)]
            out.append([(a[k] + 4 * b[k] + 6 * c[k] + 4 * d[k] + e[k]) / 16 for k in range(len(c))])
        rows = out
    return rows

def pose_of(row):
    """A row of world rotations' joints on the reference body, in metres."""
    w = []
    for j in range(JOINTS):
        q = row[3 + j * 4:7 + j * 4]
        l = math.sqrt(sum(c * c for c in q))
        w.append(tuple(c / l for c in q))
    return ref_positions(tuple(c * REF_HIP_HEIGHT for c in row[:3]), w)

def glitches(positions):
    """Which frames the fit glitched getting to from the one before."""
    return [f > 0 and max(math.dist(x, y) for x, y in zip(positions[f], positions[f - 1])) * FPS > GLITCH
            for f in range(len(positions))]

def repair(rows, bad):
    """Bridges each glitch (frames under a tenth of a second apart count as one) with a curve
    from the good frames either side, meeting their speed: over a tenth of a second either side
    if that's slow enough to pass for dancing, or wider, up to REPAIR frames in all, where the
    fit jumped to another pose and stayed there. The rows hold world rotations, so a limb the fit
    twisted one way and its child back the other (SMPL's legs, often) keeps pointing where it
    was, and only turns about its own length while it's bridged. Returns how many it bridged."""
    n, f, done = len(rows), 0, 0
    while f < n:
        if not bad[f]: f += 1; continue
        last = f
        while last + 1 < n and (bad[last + 1] or any(bad[last + 1:last + 7])): last += 1
        first, f = f, last + 1
        for pad in (6, 12, 20, 30):
            a, b = first - pad - 1, last + pad
            if a < 1 or b > n - 2 or b - a > REPAIR: break
            span = b - a
            bridge = []
            for i in range(1, span):
                t = i / span
                h00, h10, h01, h11 = 2*t**3 - 3*t**2 + 1, t**3 - 2*t**2 + t, -2*t**3 + 3*t**2, t**3 - t**2
                bridge.append([h00 * rows[a][k] + h10 * (rows[a][k] - rows[a - 1][k]) * span + h01 * rows[b][k]
                               + h11 * (rows[b + 1][k] - rows[b][k]) * span for k in range(len(rows[a]))])
            poses = [pose_of(rows[a])] + [pose_of(r) for r in bridge] + [pose_of(rows[b])]
            if all(not g for g in glitches(poses)):
                rows[a + 1:b] = bridge
                done += 1
                break
    return done

def prepare(root, world):
    """A sequence at 60 fps as rows: the hips' position in hip heights over the floor, then each
    joint's local rotation (w, x, y, z), kept on one side of the sphere through time, its short
    glitches bridged, smoothed and normalised. With each frame's joints on the reference body
    (metres, hips at their place), whether the fit still glitched getting there from the frame
    before, and how many glitches were bridged."""
    n = len(root)
    # The floor is where the lowest of it mostly is: the feet, or the hands or head of a breaker.
    lows = []
    for p, w in zip(root, world):
        pos = ref_positions(p, w)
        feet = min(pos[7][1] - REF_SOLE, pos[8][1] - REF_SOLE, pos[10][1] - REF_TOE, pos[11][1] - REF_TOE)
        lows.append(min(feet, min(q[1] for q in pos) - REF_BODY))
    floor = sorted(lows)[int(n * 0.05)]
    # World rotations, each joint's kept on one side of the sphere, its short glitches bridged.
    rows, last = [], None
    for p, w in zip(root, world):
        row = [p[0] / REF_HIP_HEIGHT, (p[1] - floor) / REF_HIP_HEIGHT, p[2] / REF_HIP_HEIGHT]
        for j in range(JOINTS):
            q = w[j]
            if last is not None and sum(x * y for x, y in zip(q, last[3 + j * 4:7 + j * 4])) < 0: q = tuple(-x for x in q)
            row.extend(q)
        rows.append(row); last = row
    bridged = repair(rows, glitches([pose_of(r) for r in rows]))
    # Local rotations, kept on one side of the sphere, then smoothed.
    local, last = [], None
    for r in rows:
        w = []
        for j in range(JOINTS):
            q = r[3 + j * 4:7 + j * 4]
            l = math.sqrt(sum(c * c for c in q))
            w.append(tuple(c / l for c in q))
        row = list(r[:3])
        for j in range(JOINTS):
            q = w[j] if j == 0 else qmul(qconj(w[PARENTS[j]]), w[j])
            if last is not None and sum(x * y for x, y in zip(q, last[3 + j * 4:7 + j * 4])) < 0: q = tuple(-x for x in q)
            row.extend(q)
        local.append(row); last = row
    rows = smooth(local, 2)
    for row in rows:
        for j in range(JOINTS):
            q = row[3 + j * 4:7 + j * 4]
            l = math.sqrt(sum(c * c for c in q))
            row[3 + j * 4:7 + j * 4] = [c / l for c in q]
    # The joints again, from the local rotations, to find what's left.
    positions = []
    for row in rows:
        w = [None] * JOINTS
        for j in range(JOINTS):
            q = tuple(row[3 + j * 4:7 + j * 4])
            w[j] = q if j == 0 else qmul(w[PARENTS[j]], q)
        positions.append(ref_positions(tuple(c * REF_HIP_HEIGHT for c in row[:3]), w))
    return rows, positions, glitches(positions), bridged

def sections(positions, bad, bpm):
    """What to keep of a performance, as (first frame, bars) on its bar lines: its runs of bars
    clear of glitches (with a fifth of a second to spare), less any standing about at each end."""
    n, bar = len(positions), 4 * 60.0 / bpm * FPS
    def frame(k): return math.ceil(k * bar)
    def clean(k): return not any(bad[max(frame(k) - 12, 0):min(frame(k + 1) + 13, n)])
    def busy(k):
        a, b = frame(k), min(frame(k + 1), n - 1)
        moved = sum(math.dist(positions[f][j], positions[f - 1][j]) - 0 for f in range(a + 1, b + 1) for j in UPPER + LOWER)
        travel = sum(math.dist(positions[f][0], positions[f - 1][0]) for f in range(a + 1, b + 1)) * len(UPPER + LOWER)
        return max(moved - travel, moved * 0.5) * FPS / ((b - a) * len(UPPER + LOWER)) > IDLE
    bars = [k for k in range(int((n - 3) / bar)) if frame(k + 1) + 2 < n]
    runs, run = [], []
    for k in bars:
        if clean(k): run.append(k)
        else:
            if run: runs.append(run)
            run = []
    if run: runs.append(run)
    kept = []
    for run in runs:
        while run and not busy(run[0]): run = run[1:]
        while run and not busy(run[-1]): run = run[:-1]
        if len(run) >= 2: kept.append((frame(run[0]), len(run)))
    return kept

def score(positions):
    """How much happens: the arms and head, and the legs, moving against the body (m/s); how
    varied its poses are (m); how fast it travels (m/s); and those weighed together."""
    n = len(positions)
    rel = [[(p[j][0] - p[0][0], p[j][1] - p[0][1], p[j][2] - p[0][2]) for j in range(JOINTS)] for p in positions]
    def speed(joints): return sum(math.dist(rel[f][j], rel[f - 1][j]) for f in range(1, n) for j in joints) * FPS / ((n - 1) * len(joints))
    upper, lower = speed(UPPER), speed(LOWER)
    travel = sum(math.hypot(positions[f][0][0] - positions[f - 1][0][0], positions[f][0][2] - positions[f - 1][0][2])
                 for f in range(1, n)) * FPS / (n - 1)
    spread = 0.0
    for j in UPPER + LOWER:
        mean = [sum(r[j][k] for r in rel) / n for k in range(3)]
        spread += math.sqrt(sum(math.dist(r[j], mean) ** 2 for r in rel) / n)
    spread /= len(UPPER + LOWER)
    return {"upper": upper, "lower": lower, "travel": travel, "spread": spread,
            "score": upper + 0.6 * lower + 4 * spread - 1.5 * travel}

def encode(rows, start, bars, bpm):
    """Frames from `start` for `bars` bars as a clip, faced front and centred."""
    bar = 4 * 60.0 / bpm * FPS
    rows = [list(r) for r in rows[start:min(start + math.ceil(bars * bar) + 2 * STEP + 1, len(rows))]][::STEP]
    # Facing +x on average, centred over the floor.
    fx = fz = 0.0
    for r in rows:
        f = qrot(tuple(r[3:7]), (1, 0, 0)); fx += f[0]; fz += f[2]
    a = math.atan2(fz, fx)
    turn = (math.cos(a / 2), 0.0, math.sin(a / 2), 0.0)
    for r in rows:
        r[:3] = qrot(turn, tuple(r[:3])); r[3:7] = qmul(turn, tuple(r[3:7]))
    xs, zs = [r[0] for r in rows], [r[2] for r in rows]
    cx, cz = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2
    channels = [[] for _ in range(3 + JOINTS * 4)]
    last = [None] * JOINTS
    for r in rows:
        values = [round((r[0] - cx) * 4096), round(r[1] * 4096), round((r[2] - cz) * 4096)]
        for j in range(JOINTS):
            w, x, y, z = r[3 + j * 4:7 + j * 4]
            q = [x, y, z, w]
            if last[j] is not None and sum(c * d for c, d in zip(q, last[j])) < 0: q = [-c for c in q]
            last[j] = q
            values += [round(c * 32767) for c in q]
        for c, v in zip(channels, values): c.append(max(-32767, min(32767, v)))
    data = []
    for c in channels:
        for _ in range(2):
            c = [c[0]] + [((c[i] - c[i - 1] + 32768) % 65536) - 32768 for i in range(1, len(c))]
        data += c
    raw = struct.pack("<%dh" % len(data), *data)
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)
    payload = packer.compress(raw[0::2] + raw[1::2]) + packer.flush()
    return struct.pack("<4sIffffII", b"JVMC", len(rows), FPS / STEP, bpm, 0.0, bars * 4, JOINTS, len(payload)) + payload

def tempo(name):
    """The tempo of the music a sequence was danced to, from its name (…_mHO3_…)."""
    music = [p for p in name.split("_") if p.startswith("m")][0]
    k = int(music[3])
    return 110 + 5 * k if music[1:3] == "HO" else 80 + 10 * k

def main():
    args = sys.argv[1:]
    audit = "--audit" in args
    out = os.path.join(REPO, "Content", "Motion")
    source = os.path.join(CACHE, "motions")
    if "--fetch" in args and not os.path.isdir(source):
        os.makedirs(CACHE, exist_ok=True)
        bundle = os.path.join(CACHE, "edge_aistpp.zip")
        print("fetching", BUNDLE)
        with urllib.request.urlopen(BUNDLE) as r, open(bundle + ".part", "wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk: break
                f.write(chunk)
        with zipfile.ZipFile(bundle + ".part") as z:
            os.makedirs(source)
            for entry in z.namelist():
                if entry.startswith("edge_aistpp/motions/") and entry.endswith(".pkl"):
                    with open(os.path.join(source, os.path.basename(entry)), "wb") as f: f.write(z.read(entry))
        os.remove(bundle + ".part")
    if not os.path.isdir(source): sys.exit("missing %s (run with --fetch)" % source)

    names = sorted(f[:-4] for f in os.listdir(source) if f.endswith(".pkl") and "_sFM_" in f)
    if not audit:
        for genre in STYLE: shutil.rmtree(os.path.join(out, STYLE[genre]), ignore_errors=True)
    total, clips, seconds = 0, 0, 0.0
    for i, name in enumerate(names):
        genre, bpm = name[:3], tempo(name)
        with open(os.path.join(source, name + ".pkl"), "rb") as f: rows, positions, bad, bridged = prepare(*load(f.read()))
        bar = 4 * 60.0 / bpm * FPS
        kept = sections(positions, bad, bpm)
        if audit:
            whole = int((len(rows) - 3) / bar)
            print("%-9s %s %3d BPM %5.1f s  %2d bars, %d glitches bridged, kept %s" % (STYLE[genre], name, bpm, len(rows) / FPS,
                  whole, bridged, ", ".join("%d-%d" % (s / bar, s / bar + b - 1) for s, b in kept) or "nothing"))
            continue
        for start, bars in kept:
            data = encode(rows, start, bars, bpm)
            clip = name + ("" if len(kept) == 1 and start == 0 else "_at%d" % round(start / bar))
            os.makedirs(os.path.join(out, STYLE[genre]), exist_ok=True)
            with open(os.path.join(out, STYLE[genre], clip + ".jvmc"), "wb") as f: f.write(data)
            total += len(data); clips += 1; seconds += bars * bar / FPS
        print("\rbaked %d/%d" % (i + 1, len(names)), end="", file=sys.stderr)
    if not audit: print("\n%d clips, %.1f minutes, %.1f MB" % (clips, seconds / 60, total / 1e6))

if __name__ == "__main__":
    main()
