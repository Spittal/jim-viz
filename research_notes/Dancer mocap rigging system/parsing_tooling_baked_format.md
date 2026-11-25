# Parsing tooling and baked clip format for dance mocap (macOS, Command Line Tools only)

Conventions used in these notes:

- **[Local test]** means I ran it on this machine on 2026-11-25 (Darwin 25.5, Apple Silicon, Command Line Tools only, Swift 6.3.3). Scratch files were in `/tmp/mocapnote`; nothing was written to the repo except this note.
- **(from memory, unverified)** means I believe it but did not find or open a source for it in this session. Treat those as leads, not facts.
- All code sketches in this note were executed and their output checked, unless marked otherwise.

## 1. BVH: format, Euler order, variants, parsing and forward kinematics

### Takeaway
BVH is a whitespace-token text format that a ~40-line standard-library Python parser handles, so no dependency is needed. The one real pitfall is rotation order: compose the local rotation by right-multiplying one axis matrix per rotation channel **in the order the channels are listed** (channels `Z X Y` means `R = Rz·Rx·Ry` on column vectors, i.e. intrinsic Z-X-Y); I confirmed this against scipy.

### Cited Findings

**Format**
- A BVH file has two parts: a header that "describes the hierarchy and initial pose of the skeleton", starting with the keyword `HIERARCHY`, and a `MOTION` section — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- After `HIERARCHY` comes `ROOT <name>`, then `{`; child segments use `JOINT <name>`; each block closes with `}` — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- `OFFSET x y z` is "the X,Y and Z offset of the segment from its parent" — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- `CHANNELS n <names…>` gives the channel count and then the channel names. The page's author had "never encountered a BVH file that didn't have 6 channels for the root object and 3 channels for every other object" — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- `End Site` "ends the recursion and indicates that the current segment is an end effector (has no children)"; its OFFSET "gives the length of the preceding segment". It has no channels — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- `MOTION` is on a line by itself, followed by `Frames: N` (the colon is part of the keyword) and `Frame Time: t`, which "indicates the sampling rate of the data"; 0.033333 is 30 fps — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- Each motion line holds one frame; "The numbers appear in the order of the channel specifications as the skeleton hierarchy was parsed" (depth-first file order) — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- "the world space is defined as a right handed coordinate system with the Y axis as the world up vector" — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- "The BVH format doesn't account for scales". The page does not state a length unit — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)

**Rotation order (the pitfall)**
- For the classic channel order "Z rotation, followed by the X rotation and finally the Y rotation", the page says to "concatenate the matrices from left to right Y, X and Z" and writes `vR = vYXZ`. That is a **row-vector** formula: Y is applied to the vector first, then X, then Z — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- The same thing in column-vector form is `R = Rz·Rx·Ry`, i.e. multiply in the order the channels are listed. **[Local test]** my FK (below) with channels `Zrotation Xrotation Yrotation` matched `scipy.spatial.transform.Rotation.from_euler('ZXY', …)` (uppercase = intrinsic) to 4 decimals on a 3-joint chain: `[0.617, 2.6634, 2.3572]` and `[0.6452, 3.8082, 2.3905]`. The extrinsic reading (`'zxy'`) gave a different answer (`[0.2572, 2.6634, 3.0903]`).
- Forum threads show people reading the Wisconsin page as "the order is Y,X,Z" and getting it wrong, and files in the wild with other orders (X-Y-Z first entry), so the order must be read per joint from the header, not assumed — [GameDev.net thread](https://gamedev.net/forums/topic/715258-combining-translation-amp-rotations-and-per-frame-rotations); [Web3D list](https://web3d.org/pipermail/x3d-public_web3d.org/2017-January/005818.html)
- Angles are degrees in every example in the reference, and the root translation is "the sum of the offset data and the translation data from the motion section" — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
- World transform: build each joint's local transform, then "concatenate it with the local transformation of its parent, then its grand parent, and so on" — [Wisconsin BVH page](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)

**Datasets and licences**
- LaFAN1 (Ubisoft) is BVH, 30 fps, 77 sequences, 5 subjects, 496,672 frames, and is licensed "Creative Commons Attribution-NonCommercial-NoDerivatives 4.0". The zip (137 MB) needs Git LFS to fetch — [LaFAN1 repo](https://github.com/ubisoft/ubisoft-laforge-animation-dataset)

**Existing parsers**
- `bvh` by 20tab (`bvh-python`): MIT. API is `Bvh(text)`, `nframes`, `frame_time`, `frame_joint_channel(frame, joint, channel)`, `joint_offset`, `joint_channels`, `joint_parent`. The README shows no forward kinematics — [20tab/bvh-python](https://github.com/20tab/bvh-python)
- `bvhtoolbox` bundles 20tab's module "because that module has not been updated on pypi.org in a while" — [bvhtoolbox on PyPI](https://pypi.org/project/bvhtoolbox/)
- `pybvh` (pure-NumPy reader/writer) and `bvhio` are listed as MIT on PyPI — [pybvh](https://pypi.org/project/pybvh/); [bvhio](https://pypi.org/project/bvhio/)
- assimp lists BVH as an importer only (no BVH exporter) — [assimp Fileformats.md](https://raw.githubusercontent.com/assimp/assimp/master/doc/Fileformats.md)

**Minimal parser + FK (Python, standard library only) — [Local test], output checked against scipy**

```python
import math

def parse_bvh(text):
    tok = text.split()
    i = tok.index('HIERARCHY') + 1
    names, parents, offsets, channels = [], [], [], []
    stack = []                                   # joint indices; -1 marks an End Site
    while tok[i] != 'MOTION':
        t = tok[i]
        if t in ('ROOT', 'JOINT'):
            names.append(tok[i + 1]); parents.append(stack[-1] if stack else -1)
            offsets.append(None); channels.append([]); pending = len(names) - 1; i += 2
        elif t == 'End':                         # "End Site"
            pending = -1; i += 2
        elif t == '{': stack.append(pending); i += 1
        elif t == '}': stack.pop(); i += 1
        elif t == 'OFFSET':
            if stack[-1] >= 0: offsets[stack[-1]] = tuple(float(x) for x in tok[i + 1:i + 4])
            i += 4                               # End Site offsets (bone tips) are dropped
        elif t == 'CHANNELS':
            n = int(tok[i + 1]); channels[stack[-1]] = tok[i + 2:i + 2 + n]; i += 2 + n
        else: raise ValueError(f'invalid BVH token {t!r}')
    assert tok[i + 1] == 'Frames:' and tok[i + 3:i + 5] == ['Frame', 'Time:']
    frames, frame_time = int(tok[i + 2]), float(tok[i + 5])
    values = [float(x) for x in tok[i + 6:]]
    width = sum(len(c) for c in channels)
    if len(values) != frames * width: raise ValueError('invalid BVH: motion size')
    return names, parents, offsets, channels, frame_time, \
           [values[f * width:(f + 1) * width] for f in range(frames)]

def axis_rot(axis, deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return {'X': ((1, 0, 0), (0, c, -s), (0, s, c)),
            'Y': ((c, 0, s), (0, 1, 0), (-s, 0, c)),
            'Z': ((c, -s, 0), (s, c, 0), (0, 0, 1))}[axis]

def mul(a, b): return tuple(tuple(sum(a[r][k] * b[k][c] for k in range(3)) for c in range(3)) for r in range(3))
def apply(m, v): return tuple(sum(m[r][k] * v[k] for k in range(3)) for r in range(3))
IDENT = ((1, 0, 0), (0, 1, 0), (0, 0, 1))

def fk(parents, offsets, channels, frame):
    """World positions and 3x3 rotations (column-vector convention) for one frame."""
    pos, rot, k = [], [], 0
    for j, chans in enumerate(channels):         # file order, so a parent always comes first
        local, t = IDENT, list(offsets[j])
        for ch in chans:
            v = frame[k]; k += 1
            if ch.endswith('position'): t['XYZ'.index(ch[0])] = v      # replaces the offset (see Gaps)
            else: local = mul(local, axis_rot(ch[0], v))               # RIGHT-multiply in listed order
        if parents[j] < 0: pos.append(tuple(t)); rot.append(local)
        else:
            p = parents[j]
            pos.append(tuple(a + b for a, b in zip(pos[p], apply(rot[p], t))))
            rot.append(mul(rot[p], local))
    return pos, rot
```

### Inferences
- A hand-written parser is the lowest-friction choice. The 20tab module is MIT but offers only channel lookup, so FK has to be written anyway; `pybvh` needs NumPy.
- Because the parser reads channel names per joint, it handles any Euler order (ZXY, ZYX, XYZ, YXZ) and joints with 3 or 6 channels without special cases.
- Split on whitespace rather than lines: it tolerates tabs, CRLF and odd indentation. The only two-word keywords are `End Site` and `Frame Time:`.
- For a baked positions-only clip, FK in the converter is all that's needed; bake world (or root-relative) joint positions and discard the Euler data.
- The licence matters more than the format: LaFAN1's NC-ND terms rule out committing converted clips to a public repo, since a baked/retargeted clip is plainly a derivative.

### Gaps
- **Position channels on non-root joints.** The Wisconsin page says root translation is offset + channel value. My sketch *replaces* the offset with the channel value for any joint, which is how I remember Blender's importer and Holden's `BVH.py` behaving (from memory, unverified). The two agree whenever the root OFFSET is zero, which is usual. Check a 6-channel-per-joint file by comparing a joint's position channels with its OFFSET before trusting either rule.
- **Dataset-specific conventions** — CMU cgspeed conversions (rotation order, inch-like units, 120 fps), Bandai Namco, Motorica, and LaFAN1's rotation order and centimetre units — were not confirmed from any source in this session. Read each file's `CHANNELS` lines and bone lengths (a thigh is roughly 0.4–0.45 m) rather than relying on lore.
- **Meredith & Maddock, "Motion Capture File Formats Explained"** was located ([PDF](https://staffwww.dcs.shef.ac.uk/people/S.Maddock/publications/MeredithMaddock2001_CS0111.pdf)) but not read.
- **Holden's `BVH.py` licence** and any Swift or C BVH parser were not checked. The Blender BVH manual page returned 403.
- The licences of the Bandai Namco, Motorica and CMU datasets were out of my scope and not checked.

## 2. Python pickles holding numpy arrays (AIST++)

### Takeaway
Plain `pickle.load` fails without numpy, but a ~35-line restricted `Unpickler` that maps numpy's reconstruct globals onto stub classes reads the arrays with the standard library alone, and is also the safe way to open downloaded pickles. I tested this against pickles written by real numpy at protocols 2, 4 and 5. If numpy is wanted anyway, `python3 -m venv` plus `pip install numpy` works with the Command Line Tools Python.

### Cited Findings

**This machine**
- **[Local test]** `/usr/bin/python3` is Python 3.9.6 from `/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9`. numpy is not installed. pip 21.2.4, `venv` and `ensurepip` are present.
- **[Local test]** `/usr/bin/python3 -m venv venv && venv/bin/python -m pip install numpy` succeeded (needs network) and installed numpy 2.0.2; scipy also installed. The venv with numpy alone was 38 MB.
- **[Local test]** A Homebrew `python3` (3.15.2) is first on `PATH` on this machine and also has no numpy. A script that says `python3` gets that one, not the system one.
- **[Local test]** `pickle.load` on a numpy pickle without numpy raises `ModuleNotFoundError: No module named 'numpy'`.

**AIST++ files**
- Motion files: `pickle.load` gives a dict with `smpl_poses` (commented `(N, 24, 3)`), `smpl_scaling` `(1,)`, `smpl_trans` `(N, 3)` — [aistplusplus_api loader.py](https://raw.githubusercontent.com/google/aistplusplus_api/main/aist_plusplus/loader.py)
- Keypoint files: dict with `keypoints3d` and `keypoints3d_optim`, each `(N, 17, 3)` — [aistplusplus_api loader.py](https://raw.githubusercontent.com/google/aistplusplus_api/main/aist_plusplus/loader.py)
- Keypoints are COCO format (17 names, "nose" … "right_ankle"); motions are SMPL format (24 joints, "root", "lhip", "rhip", "belly", …) — [aistplusplus_api README](https://github.com/google/aistplusplus_api)
- "Our annotations are frame-by-frame under exact 60 FPS" — [AIST++ download page](https://google.github.io/aistplusplus_dataset/download.html)
- "The annotations are licensed by Google LLC under CC BY 4.0 license" — [AIST++ dataset site](https://google.github.io/aistplusplus_dataset/factsfigures.html)
- An `ignore_list.txt` lists sequences with poorly reconstructed keypoints and motion, which the authors recommend excluding — [AIST++ download page](https://google.github.io/aistplusplus_dataset/download.html)
- Videos and music belong to the separate AIST Dance Video Database, whose Terms of Use must be agreed to — [AIST++ download page](https://google.github.io/aistplusplus_dataset/download.html)
- The API repo is Apache-2.0 and was archived (read-only) on 12 June 2024 — [aistplusplus_api](https://github.com/google/aistplusplus_api)

**Pickle safety**
- "The `pickle` module is not secure. Only unpickle data you trust. It is possible to construct malicious pickle data which will execute arbitrary code during unpickling." — [Python pickle docs](https://docs.python.org/3/library/pickle.html)
- The documented mitigation is overriding `Unpickler.find_class()`, which "is called whenever a global (i.e., a class or a function) is requested. Thus it is possible to either completely forbid globals or restrict them to a safe subset." — [Python pickle docs, Restricting Globals](https://docs.python.org/3/library/pickle.html#restricting-globals)

**What a pickled ndarray contains — [Local test], opcode dump of numpy 2.0.2 pickles**
- Globals requested at protocol 2: `numpy._core.multiarray._reconstruct`, `numpy.ndarray`, `numpy.dtype`, `numpy._core.multiarray.scalar` (for a numpy scalar) and `_codecs.encode` (protocol ≤ 2 stores the raw bytes as a latin1 string).
- The array's state tuple is `(version, shape, dtype, is_fortran, raw_bytes)`; the dtype's state tuple has the byte order at index 1.
- Protocol 5 takes a different path (`numpy._core.numeric._frombuffer(buffer, dtype, shape, order)`); the sketch below handles it.

**NPY format, for comparison**
- `.npy` is: magic `\x93NUMPY`, major and minor version bytes, a little-endian header length (2 bytes in v1.0, 4 in v2.0), an ASCII Python-literal dict with `descr`, `fortran_order`, `shape`, padded to a multiple of 64 bytes, then the contiguous array bytes — [numpy.lib.format](https://numpy.org/doc/stable/reference/generated/numpy.lib.format.html)

**Numpy-free restricted unpickler — [Local test], read back correct shapes and values at protocols 2, 4, 5 and blocked `os.system`**

```python
import pickle, struct

class DType:
    def __init__(self, code, align=False, copy=True): self.code, self.order = code, '='
    def __setstate__(self, st):
        self.order = st[1]                                 # '<', '>', '|' or '='
        if st[2] is not None or st[3] is not None:
            raise pickle.UnpicklingError('structured dtype not supported')

class NDArray:
    def __setstate__(self, st):
        _ver, self.shape, self.dtype, fortran, self.raw = st
        if fortran: raise pickle.UnpicklingError('fortran order not supported')
    def flat(self):                                        # row-major list of Python numbers
        if self.dtype.order == '>': raise pickle.UnpicklingError('big-endian')
        code = {'f4': 'f', 'f8': 'd', 'i4': 'i', 'i8': 'q', 'u1': 'B'}[self.dtype.code]
        return memoryview(bytes(self.raw)).cast(code).tolist()

def _reconstruct(cls, shape, typecode): return NDArray()
def _frombuffer(buf, dtype, shape, order):                 # protocol 5
    a = NDArray(); a.__setstate__((1, shape, dtype, order == 'F', bytes(buf))); return a
def _scalar(dtype, raw):
    return struct.unpack('<' + {'f4': 'f', 'f8': 'd', 'i4': 'i', 'i8': 'q'}[dtype.code], raw)[0]
def _encode(s, enc):                                       # protocol <= 2 raw bytes
    if enc != 'latin1': raise pickle.UnpicklingError('unexpected codec')
    return s.encode('latin1')

ALLOWED = {('numpy', 'ndarray'): NDArray, ('numpy', 'dtype'): DType, ('_codecs', 'encode'): _encode}
for core in ('numpy.core', 'numpy._core'):                 # numpy 1.x and 2.x module names
    ALLOWED[(core + '.multiarray', '_reconstruct')] = _reconstruct
    ALLOWED[(core + '.multiarray', 'scalar')] = _scalar
    ALLOWED[(core + '.numeric', '_frombuffer')] = _frombuffer

class ArrayUnpickler(pickle.Unpickler):
    def find_class(self, module, name):
        try: return ALLOWED[(module, name)]
        except KeyError: raise pickle.UnpicklingError(f"global '{module}.{name}' is forbidden")

# with open(path, 'rb') as f: d = ArrayUnpickler(f).load()
# d['keypoints3d'].shape -> (N, 17, 3);  d['keypoints3d'].flat() -> N*17*3 floats
```

### Inferences
- The stub unpickler is strictly safer than `pickle.load` with numpy installed, because numpy's own load path will still import whatever globals the stream names. It never imports numpy at all.
- For AIST++ specifically, the COCO-17 `keypoints3d` arrays are already world positions, so the converter needs no SMPL model and no FK: unpickle, pick joints, rescale, resample 60 → 30 fps if wanted, write. Using `smpl_poses` instead means axis-angle → rotation plus the SMPL rest skeleton, which requires the separately licensed SMPL model files (the API expects `SMPL_MALE.pkl`/`SMPL_FEMALE.pkl` per its [README](https://github.com/google/aistplusplus_api)).
- The converter should name its interpreter explicitly (`/usr/bin/python3`) or be version-agnostic, given Homebrew Python shadows the system one here.
- Run the converter with `python3 -I` and keep downloads in their own directory, so a planted module beside a download can't be imported.

### Gaps
- I tested against pickles I generated with numpy 2.0.2, **not against real AIST++ files**. AIST++ was written by an older numpy, so the module name will be `numpy.core.multiarray` (handled in the allow-list), but the pickle protocol, exact dtypes (float32 vs float64) and whether `smpl_poses` is stored as `(N, 72)` rather than `(N, 24, 3)` are unconfirmed.
- Units of `keypoints3d` (centimetres, I believe) and the rule that `smpl_trans` must be divided by `smpl_scaling` are from memory, unverified. The AIST++ fact-sheet URL I tried returned 404.
- Which Python version ships with other Command Line Tools releases was not checked; 3.9.6 is what this machine has.
- Offline `pip install` (no network) was not tested; it needs a pre-downloaded wheel (`pip download numpy` elsewhere, then `pip install --no-index --find-links`), which is standard pip behaviour I did not verify here.

## 3. FBX: what Apple's frameworks read, and conversion without Blender

### Takeaway
Model I/O does not read FBX (or DAE, glTF, BVH) on this machine, so FBX needs a third-party reader. ufbx — two files, MIT or public domain, no dependencies, with a built-in animation baker — is the lowest-friction path for Mixamo FBX, and it compiled here with plain `clang` in under two seconds.

### Cited Findings

**Apple frameworks**
- **[Local test]** `MDLAsset.canImportFileExtension` from a command-line Swift script returned `true` for `obj`, `ply`, `stl`, `abc`, `usd`, `usda`, `usdc`, `usdz` and `false` for `fbx`, `dae`, `gltf`, `glb`, `bvh`.
- `canImportFileExtension(_:)` "Returns a Boolean value that indicates whether the MDLAsset class can read asset data from files with the specified extension"; Apple's page links to an "Asset File Types" list rather than enumerating formats — [Apple MDLAsset docs](https://developer.apple.com/documentation/modelio/mdlasset)
- **[Local test]** Model I/O reads USD skeletal animation from a command-line tool. A hand-written `.usda` with a `Skeleton` and a `SkelAnimation` loaded as an `MDLSkeleton` (with `jointPaths`, bind transforms and an `MDLAnimationBindComponent`), and `asset.animations` held one `MDLPackedJointAnimation`. `asset.frameInterval` came back as 1/30 and the end time as 2/30 s, matching the file. I did not print the sampled translation/rotation values, so value correctness is unverified.
- **[Local test]** `SCNScene(url:)` loaded the same `.usda` and attached an animation to the skeleton node (animation key `/Root/Skel/Anim`).
- **[Local test]** `/usr/bin/usdcat` exists with Command Line Tools only; `usdzconvert` does not.
- Apple's support page says "If an app asks you to install the FBX C++ SDK on your Mac, you can download the latest version directly from Autodesk's website", linking to FBX SDK 2020.2.1 — [Apple: Get the FBX SDK for Mac](https://developer.apple.com/support/fbx-sdk/)
- There is an Apple forum thread titled "Reality Converter fails to convert FBX on M1 Mac" — [Apple Developer Forums](https://developer.apple.com/forums/thread/699583) (title only; thread not read)

**ufbx**
- Dual-licensed: "This software is available under 2 licenses -- choose whichever you prefer": MIT (Copyright (c) 2020 Samuli Raivio) or public domain (Unlicense) — [ufbx repo](https://github.com/ufbx/ufbx)
- Single source file plus header (`ufbx.c`, `ufbx.h`), C99/C++11, no listed dependencies; "Supports binary and ASCII FBX files starting from version 3000"; also reads `.obj`; features include skinning, blend shapes and "Animation curve evaluation / layer blending" — [ufbx repo](https://github.com/ufbx/ufbx)
- No tagged releases: "The latest commit in the master branch contains the latest stable version". Header version at fetch time: `UFBX_HEADER_VERSION ufbx_pack_version(0, 23, 1)` — [ufbx repo](https://github.com/ufbx/ufbx); [ufbx.h](https://raw.githubusercontent.com/ufbx/ufbx/master/ufbx.h)
- Animations are stacks (`ufbx_anim_stack`) of layers; "Each stack corresponds to a single animation clip, or a take". `ufbx_evaluate_scene()` returns a whole new scene with animation applied at a time (simple, heavyweight). `ufbx_bake_anim()` converts animation to linearly interpolated translation, quaternion rotation and scale tracks, resampling cubic curves and Euler rotations; `ufbx_bake_opts.resample_rate` sets the rate — [ufbx animation docs](https://ufbx.github.io/elements/animation/)
- Exact signatures, grepped from the header — [ufbx.h](https://raw.githubusercontent.com/ufbx/ufbx/master/ufbx.h):
  - `ufbx_transform ufbx_evaluate_transform(const ufbx_anim *anim, const ufbx_node *node, double time);`
  - `ufbx_scene *ufbx_evaluate_scene(const ufbx_scene *scene, const ufbx_anim *anim, double time, const ufbx_evaluate_opts *opts, ufbx_error *error);`
  - `ufbx_baked_anim *ufbx_bake_anim(const ufbx_scene *scene, const ufbx_anim *anim, const ufbx_bake_opts *opts, ufbx_error *error);`
  - `void ufbx_free_baked_anim(ufbx_baked_anim *bake);` and `void ufbx_free_scene(ufbx_scene *scene);`
  - `ufbx_vec3 ufbx_evaluate_baked_vec3(ufbx_baked_vec3_list keyframes, double time);` and `ufbx_quat ufbx_evaluate_baked_quat(ufbx_baked_quat_list keyframes, double time);`
  - `ufbx_load_opts` has `target_axes`, `target_unit_meters` ("Scale the scene so that one world-space unit is `target_unit_meters` meters") and `space_conversion`; `ufbx_bake_opts` has `resample_rate`, `minimum_sample_rate`, `trim_start_time`; `ufbx_baked_node` has `typed_id` (index into `scene.nodes[]`) and `constant_translation/rotation/scale` flags.
- **[Local test]** `clang -O1 -c ufbx.c` compiled cleanly with the Command Line Tools in about 1.7 s. `ufbx.c` is 33,212 lines / 1.18 MB; `ufbx.h` is 224 KB. I did not load an FBX file with it.

**Other converters**
- assimp imports FBX (ASCII and binary) and BVH; its exporters are DAE, STL, OBJ, PLY, X, 3DS, JSON, ASSBIN, STEP, PBRTv4, "glTF 1.0 (partial)", "glTF 2.0 (partial)", "3MF ( experimental )", "FBX ( experimental )". No BVH or USD export — [assimp Fileformats.md](https://raw.githubusercontent.com/assimp/assimp/master/doc/Fileformats.md)
- FBX2glTF is 3-clause BSD and bakes every FBX animation into a glTF animation, but building it needs the Autodesk FBX SDK and "only version 2019.2 of the FBX SDK is supported". The repo page showed no archive notice when fetched, **which contradicts the brief's description of it as archived** — [FBX2glTF](https://github.com/facebookincubator/FBX2glTF)
- Blender's `parse_fbx.py` is `SPDX-License-Identifier: GPL-2.0-or-later`. It imports only `struct`, `array`, `zlib`, `io` plus two sibling modules (`data_types`, `fbx_utils_threading`), no `bpy` or numpy. It documents the binary layout: magic `b'Kaydara FBX Binary\x20\x20\x00\x1a\x00'`, a uint32 version, 64-bit record headers from version 7500, one-byte property type codes (scalars `Y C I F D L`, strings/raw `S R`, arrays `f d l i b c`), zlib-compressed arrays when the encoding field is 1 — [Blender parse_fbx.py](https://raw.githubusercontent.com/blender/blender/main/scripts/addons_core/io_scene_fbx/parse_fbx.py)
- Autodesk forum threads discuss building the FBX SDK Python bindings on Apple Silicon and recommend SDK 2020.3.4 for macOS — [Autodesk FBX forum](https://forums.autodesk.com/t5/fbx-forum/building-fbx-sdk-on-apple-silicon-for-python/m-p/12361714)
- **[Local test]** Homebrew is installed on this machine; `assimp` and `blender` are not.

### Inferences
- **Recommended path for Mixamo FBX, if needed later:** a small C command-line converter (or a SwiftPM C target used only by a tool, not the app) built on ufbx — `ufbx_load_file` with `target_axes`/`target_unit_meters` set, then either `ufbx_bake_anim` at a fixed `resample_rate`, or simply `ufbx_evaluate_scene` per output frame and read each bone node's world transform. The second is the "heavyweight" option per the docs but trivially fast enough for an offline bake, and yields world positions directly without writing FK.
- Keep ufbx out of the app target. The app only ever reads the baked clip, so FBX parsing belongs in `scripts/` tooling; vendoring 1.4 MB of C into the app would add build time for nothing.
- ufbx's MIT/Unlicense terms are fine for a public repo. Blender's `parse_fbx.py` is GPL, so it is usable as a format reference but should not be copied into the repo; it also only parses the record tree and does not evaluate animation curves.
- The Autodesk SDK routes (FBX SDK, FBX2glTF, Reality Converter) all add a proprietary download and an install step, so they lose on friction regardless of Apple Silicon status.
- USD via Model I/O is a real zero-dependency option if a source can be obtained as USD/USDZ, but nothing on this machine converts FBX → USD.
- `brew install assimp` gives FBX → glTF 2.0, but with "partial" export and one more dependency, it is a weaker choice than ufbx for animation.

### Gaps
- Whether the Autodesk FBX SDK 2020.3.x macOS download is a universal (arm64) binary was not confirmed; the evidence is indirect forum posts.
- Autodesk's standalone "FBX Converter" availability/status: no source found.
- Reality Converter's and `usdzconvert`'s current FBX requirements were not verified beyond the Apple support page and a forum thread title.
- Mixamo specifics (FBX version, bone naming `mixamorig:`, 30 fps, centimetre units, and its licence terms for redistributing converted animation) are from memory or unknown, and unverified. The Mixamo/Adobe licence should be checked before committing any baked Mixamo clip.
- I did not test ufbx on an actual FBX, nor whether SwiftPM builds it as a C target without warnings-as-errors issues (the plain `clang` compile was clean).
- `MDLPackedJointAnimation` sampled values, and DAE animation via SceneKit, were not tested. Model I/O reports DAE as not importable; SceneKit has its own DAE loader (from memory, unverified).

## 4. glTF as an interchange format

### Takeaway
glTF 2.0 animation is a small, regular structure — JSON describing channels and samplers that index into raw little-endian binary buffers — so a pure-Swift reader with `JSONDecoder` plus `Data` slicing is feasible. Nothing in the pipeline currently produces glTF, though, so it only earns its place if a converter that outputs it is adopted.

### Cited Findings
- "glTF uses a right-handed coordinate system", with "+Y as up, +Z as forward, and -X as right" — [glTF 2.0 spec](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)
- An asset can be JSON plus external binary, or "use the GLB container to store JSON and binary data in one file without base64 encoding" — [glTF 2.0 spec](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)
- An animation has `channels` and `samplers`; "each channel refers to one sampler, using the index of the sampler", and its `target` names a node index and a `path` (`translation`, `rotation`, `scale`) — [glTF tutorial: Animations](https://github.com/KhronosGroup/glTF-Tutorials/blob/main/gltfTutorial/gltfTutorial_007_Animations.md)
- A sampler has `input` (key times), `output` (values) and `interpolation`: `STEP`, `LINEAR` or `CUBICSPLINE`. Rotations are quaternions and need slerp. With `CUBICSPLINE` each keyframe stores three elements: in-tangent, value, out-tangent — [glTF tutorial: Animations](https://github.com/KhronosGroup/glTF-Tutorials/blob/main/gltfTutorial/gltfTutorial_007_Animations.md)
- FBX2glTF and assimp can both emit glTF 2.0 with animation (assimp's export is marked partial) — [FBX2glTF](https://github.com/facebookincubator/FBX2glTF); [assimp Fileformats.md](https://raw.githubusercontent.com/assimp/assimp/master/doc/Fileformats.md)

### Inferences
- A minimal reader needs: decode the JSON; for each channel resolve sampler → accessor → bufferView → buffer; read `count` items at `bufferView.byteOffset + accessor.byteOffset`; build the node hierarchy from `nodes[].children`; then run FK per sample time. That is roughly 150 lines of Swift, more than BVH parsing but with no ambiguity about Euler order.
- glTF is local TRS per node, so it still needs FK and resampling to get baked world positions; it is not closer to the target format than BVH is.
- Given ufbx reads FBX directly and BVH/AIST++ are handled in Python, glTF adds a format without removing one. Skip it unless a source arrives as glTF.

### Gaps
- The spec page is 800k+ characters and only the first part was read. The following are from memory, unverified: sampler times are in seconds; rotation is a `VEC4` float quaternion in x, y, z, w order; lengths are metres; data is little-endian; GLB is a 12-byte header (magic `glTF`, version, length) followed by a JSON chunk and a BIN chunk; skins carry `joints` and `inverseBindMatrices`. Confirm in spec sections 3.11 and 4 before implementing.
- No existing permissive pure-Swift glTF library was evaluated.

## 5. Designing the baked clip format, and loading it in Swift

### Takeaway
At this scale, plain little-endian Float32 world positions with a fixed 32-byte header is the right format: 20 joints × 30 fps × 60 s is 432 KB, small enough that quantisation and memory-mapping buy nothing worth the extra code. A 30-line Swift loader that validates the magic and exact file size, then copies into `[Float]`, round-tripped a Python-written file correctly here.

### Cited Findings
- **[Local test]** A clip with a 32-byte header, 20 × Int32 parents and 1,800 frames × 20 joints × 3 Float32 was exactly 432,112 bytes (32 + 80 + 432,000).
- **[Local test]** The Swift loader below, compiled with `swiftc -O` under Command Line Tools, read that file back: joint count 20, frame count 1800, fps 30, bpm 120, first beat 0.25, loop 0..<1800, 108,000 floats, and a last value of 0.99977994 against Python's 0.99977993.
- **[Local test]** `Float16` is available in Swift on this machine (`MemoryLayout<Float16>.size == 2`, converts to `Float`).
- GitHub warns on files over 50 MiB, "blocks files larger than 100 MiB", limits browser uploads to 25 MiB, and recommends repositories stay under 1 GB ("less than 5 GB is strongly recommended"). Files over 100 MiB need Git LFS; large binaries can instead go in releases — [GitHub: About large files](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)

**Size arithmetic** (20 joints, 30 fps, 60 s = 1,800 frames; derived, not sourced)

| Payload per joint per frame | Bytes | Clip size |
|---|---|---|
| Position, 3 × Float32 | 12 | 432,000 B (422 KiB) |
| Position, 3 × Float16 or Int16 | 6 | 216,000 B (211 KiB) |
| Rotation quaternion, 4 × Float32 | 16 | 576,000 B (563 KiB) |
| Rotation quaternion, 4 × Int16 | 8 | 288,000 B (281 KiB) |
| Position + quaternion, Float32 | 28 | 1,008,000 B (984 KiB) |

At 60 fps (AIST++ native) every figure doubles.

**Layout used in the test** (all little-endian)

| Offset | Type | Field |
|---|---|---|
| 0 | 4 bytes | magic `JVMC` |
| 4 | UInt32 | joint count J |
| 8 | UInt32 | frame count F |
| 12 | Float32 | fps |
| 16 | Float32 | bpm |
| 20 | Float32 | first-beat offset, seconds |
| 24 | UInt32 | loop start frame |
| 28 | UInt32 | loop end frame (exclusive) |
| 32 | Int32 × J | parent index per joint, −1 for the root |
| 32 + 4J | Float32 × F × J × 3 | positions, frame-major |

**Writer (Python, standard library) — [Local test]**

```python
import struct
with open(path, 'wb') as f:
    f.write(struct.pack('<4sIIfffII', b'JVMC', joints, frames, fps, bpm, first_beat, loop_start, loop_end))
    f.write(struct.pack(f'<{joints}i', *parents))
    for frame in positions:                      # each frame: joints*3 floats
        f.write(struct.pack(f'<{joints * 3}f', *frame))
```

**Loader (Swift) — [Local test]**

```swift
import Foundation

struct MotionClip {
    var jointCount: Int, frameCount: Int
    var fps: Float, bpm: Float, firstBeat: Float
    var loop: Range<Int>
    var parents: [Int32]
    var positions: [Float]          // frameCount × jointCount × 3

    enum Invalid: Error { case clip(String) }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 32, data.prefix(4) == Data("JVMC".utf8) else { throw Invalid.clip("bad magic") }
        func u32(_ o: Int) -> Int {
            Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }))
        }
        func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(u32(o))) }
        jointCount = u32(4); frameCount = u32(8)
        fps = f32(12); bpm = f32(16); firstBeat = f32(20)
        loop = u32(24)..<u32(28)
        let parentBytes = jointCount * 4, floatCount = frameCount * jointCount * 3
        guard data.count == 32 + parentBytes + floatCount * 4 else { throw Invalid.clip("invalid shape") }
        parents = [Int32](unsafeUninitializedCapacity: jointCount) { buf, n in
            n = data.copyBytes(to: buf, from: 32..<(32 + parentBytes)) / 4
        }
        positions = [Float](unsafeUninitializedCapacity: floatCount) { buf, n in
            n = data.copyBytes(to: buf, from: (32 + parentBytes)..<data.count) / 4
        }
    }
}
```

### Inferences
- **Float32, not quantised.** Halving a 432 KB file is not worth a dequantisation step or a per-clip scale/offset in the header. Revisit only if dozens of minutes of clips accumulate.
- **Positions vs rotations.** If the dancer is drawn from joint positions (as COCO-17 keypoints force anyway, since they carry no rotations), bake world positions and do nothing at runtime. Rotations are only needed if a skinned mesh must be driven; they add FK at runtime and retargeting questions. Positions also make BVH, AIST++ keypoints and FBX converge on one format.
- **Alignment and endianness.** `loadUnaligned` avoids any alignment assumption for header fields, and `copyBytes` into a typed array sidesteps it for the payload. Apple Silicon and Intel Macs are both little-endian, so the bulk copy is a straight `memcpy`; the header reads still go through `UInt32(littleEndian:)` to make the format explicit.
- **Copy rather than mmap.** With the header at 32 bytes and 4-byte parents, the payload is 4-byte aligned, so a mapped `Data` could be bound in place. But a one-off 432 KB copy at load is negligible, and an owned `[Float]` is simpler to hand to the render thread as an immutable snapshot (per the project's rule that the render thread must not wait on UI state). Load off the render thread.
- **The `[Float]` hot path.** Sampling is two frame lookups and a lerp; no per-frame allocation.
- **Version field.** The brief asks for one. Project rules say no versioned tools or resilient schemas, and that invalid files should fail fast. The magic plus the exact-size check already rejects anything malformed, so a version number adds nothing unless old clips must be told apart; since clips are regenerated by a re-runnable script, I left it out of the tested layout. This is a judgement call for the report writer/user.
- **bpm and first beat** are per-clip metadata the converter cannot derive from mocap alone (AIST++ takes its tempo from the paired music; BVH has none). They need to come from a small sidecar manifest the converter reads.
- **Where clips live.** The project already ships `Content/` (shaders, maps, models) and loads it at runtime via `JIMVIZ_CONTENT` or the bundle's `Contents/Resources/Content`. Putting clips in `Content/` (for example `Content/Motion/*.clip`) reuses that path and avoids SwiftPM `resources:`/`Bundle.module` entirely.
- **Git.** A handful of sub-megabyte clips is far below GitHub's 50 MiB warning and 100 MiB block, so Git LFS is unnecessary. Binary files don't delta well, so every regeneration adds its full size to history: make the converter byte-deterministic so re-runs produce no diff.

### Gaps
- No measurement of load time or of sampling cost on the render thread was made; the "negligible" claim is reasoning from file size.
- SwiftPM resource handling (`.copy` vs `.process`, `Bundle.module`) was not researched because the existing `Content/` mechanism makes it unnecessary; if clips must live inside the Swift target instead, that needs checking.
- I did not check how the repo's existing `Content/` loader enumerates files, or whether `scripts/bundle.sh` copies new subfolders automatically.
- Quantisation error for Int16/Float16 positions was not measured.

## 6. Where conversion runs, what gets committed, and attribution

### Takeaway
Run conversion as a committed, deterministic script in `scripts/` that reads raw downloads from a cache outside git and writes only baked clips plus an attribution file. For CC BY 4.0 sources such as AIST++, that file must name the creator, link the source and the licence, and say the data was modified.

### Cited Findings
- CC BY 4.0 section 3(a)(1): when sharing the material, including modified versions, you must retain (if supplied) the creator's identification, a copyright notice, a notice referring to the licence, a notice referring to the disclaimer of warranties, and a URI or hyperlink to the material; indicate whether you modified it and keep any earlier modification notices; and state that it is under the licence, with its text or a link — [CC BY 4.0 legal code](https://creativecommons.org/licenses/by/4.0/legalcode.en)
- Section 3(a)(2): these conditions may be met "in any reasonable manner based on the medium, means, and context" — [CC BY 4.0 legal code](https://creativecommons.org/licenses/by/4.0/legalcode.en)
- Section 3(a)(3): if the licensor asks, the attribution must be removed where reasonably practicable. Section 3(a)(4): a licence applied to adapted material must not prevent recipients from complying with the original licence — [CC BY 4.0 legal code](https://creativecommons.org/licenses/by/4.0/legalcode.en)
- Creative Commons' recommended practice is TASL: Title, Author, Source, License — title if one was given, author as the licensor asks, a link to the original, and the specific licence with a link to its deed. There is no single required format — [CC wiki: Recommended practices for attribution](https://wiki.creativecommons.org/wiki/Recommended_practices_for_attribution)
- For modified works: note that it was changed and briefly how; for an adaptation, credit the original's TASL, state that yours is an adaptation, and give your own name and licence for the adapted work — [CC wiki: Recommended practices for attribution](https://wiki.creativecommons.org/wiki/Recommended_practices_for_attribution)
- Attribution may sit on a separate page or credits file; metadata alone is not enough, "since many users will never see it" — [CC wiki: Recommended practices for attribution](https://wiki.creativecommons.org/wiki/Recommended_practices_for_attribution)
- AIST++ annotations are "licensed by Google LLC under CC BY 4.0"; the videos and music fall under the separate AIST Dance Video Database terms — [AIST++ dataset site](https://google.github.io/aistplusplus_dataset/factsfigures.html); [AIST++ download page](https://google.github.io/aistplusplus_dataset/download.html)
- LaFAN1 is CC BY-NC-ND 4.0 — [LaFAN1 repo](https://github.com/ubisoft/ubisoft-laforge-animation-dataset)
- The project keeps caches in `~/Library/Caches/jim-viz` and shipped content in the repo's `Content/` — [Local: `/Users/jamie/code/jim-viz/AGENTS.md`, Storage section]

### Inferences
- **Layout.** `scripts/bake-motion.py` (standard library only, run as `/usr/bin/python3 -I`), reading raw files from `~/Library/Caches/jim-viz/mocap/<dataset>/` and writing `Content/Motion/<name>.clip`. A small committed manifest lists, per clip: source dataset, source file name, frame range, bpm, first beat, joint mapping. Raw downloads never enter git.
- **Determinism.** Fixed joint order, fixed resampling, no timestamps in the output, `struct.pack` with explicit `<` byte order. Then re-running yields identical bytes and `git status` stays clean.
- **Fail fast.** Consistent with the project's rules: an unexpected channel name, a motion row of the wrong width, a forbidden pickle global or a missing manifest field should raise, not default.
- **Attribution file.** A plain-text `Content/Motion/ATTRIBUTION.md` (or a section in an existing credits file) with one entry per source. For AIST++ something like: *"Motion derived from the AIST++ Dance Motion Dataset (Li, Yang, Ross, Kanazawa; Google LLC), https://google.github.io/aistplusplus_dataset/, licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Modified: selected sequences `<names>`, COCO-17 keypoints resampled to 30 fps, rescaled, trimmed to loops and re-encoded as binary clips."* Since the app is distributed as a bundle, the same file should ship inside it so the credit travels with the binary; that satisfies "reasonable manner based on the medium".
- **Licence compatibility with a public repo.** CC BY 4.0 data is fine to commit in baked form with attribution. NC-ND data (LaFAN1) is not: a baked clip is a modification, which ND forbids sharing. Keep such sources for private experiments only, with their clips git-ignored.
- **AIST++ scope.** Only the annotations are CC BY 4.0. Don't bundle AIST music or video; per-clip bpm can be recorded as a number without redistributing the audio.

### Gaps
- The CC legal text was summarised by the fetch tool rather than quoted verbatim in full; the wording above paraphrases section 3(a). Quote from the legal code directly if exact text is needed.
- The correct author/title credit line for AIST++ (the dataset site's requested citation) was not fetched; the author names above are from memory, unverified. Use the citation the dataset site asks for.
- Whether the user wants baked clips in `Content/` (in git, shipped) or in the library (`~/Library/Application Support/jim-viz`, not in git) is a product decision this research can't settle.
- Licences of CMU, Bandai Namco, Motorica and Mixamo data were not researched here.
