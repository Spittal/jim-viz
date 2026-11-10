#!/usr/bin/env python3
# Usage: export-stemgen.py onnx_dir Content/Models/stemgen.bin
#
# Converts StemgenRT's three causal stem models (drums.onnx, bass.onnx, vocals.onnx from
# https://github.com/sweetspotsoundsystem/stemgen-rt, model/parallel; weights CC BY-NC-SA 4.0) to
# the flat little-endian float32 file `StemSeparator.swift` reads. Needs numpy and onnx:
#   uv run --no-project --with numpy --with onnx python scripts/export-stemgen.py ...
# Where the ONNX files come from is in Content/Models/README.md.
#
# The export renamed most matrices (`onnx::MatMul_4331`); each is identified by the bias its
# MatMul feeds, the rest by shape. Every matrix is written as [out][in], row-major, one per band
# for the per-band maps. Per model, in order (bw = band width, gw = global width, nb = bands,
# w = a band's FFT bins, lw = its bins in the 4096-point analysis):
#   per band: encoder weight (bw × 6w), encoder bias (bw)
#   bass only, per band: long encoder weight (bw × 2lw)
#   band identity (nb × bw), input norm (bw)
#   per layer (2): local GRU weight_ih, weight_hh (3bw × bw), bias_ih, bias_hh (3bw),
#     local norm (bw), global in weight (gw × nb·bw), bias (gw),
#     global GRU weight_ih, weight_hh (3gw × gw), bias_ih, bias_hh (3gw), global norm (gw),
#     global out weight (nb·bw × gw), bias (nb·bw)
#   per band: mask hidden weight (bw × bw), bias (bw)
#   per band: mask head weight (4w × bw), bias (4w)
#   drums only: waveform encode (256 × 512), gates weight (256 × gw), gates bias (256),
#     decode (512 × 256)
# Models in order: drums, bass, vocals.
import sys, pathlib
import numpy as np, onnx
from onnx import numpy_helper

BAND_EDGES = (0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 80, 96, 128, 160, 192, 240, 288, 352, 416, 513)
BASS_EDGES = (0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 160, 256, 384, 513)
GEOMETRY = {"drums": (96, 192, BAND_EDGES, False, 256), "bass": (80, 160, BASS_EDGES, True, 0),
            "vocals": (96, 192, BAND_EDGES, False, 0)}


def groups(edges):
    """Runs of equal-width bands, which the export stores as one stacked matrix."""
    out = []
    for i, (l, r) in enumerate(zip(edges, edges[1:])):
        if out and out[-1][2] == r - l: out[-1] = (out[-1][0], i + 1, r - l)
        else: out.append((i, i + 1, r - l))
    return out


def tensors(path, stem):
    g = onnx.load(path).graph
    inits = {i.name: numpy_helper.to_array(i).astype(np.float32) for i in g.initializer}
    consumers = {}
    for n in g.node:
        for x in n.input: consumers.setdefault(x, []).append(n)
    prefix = f"children_by_source.{stem}.model."
    W = {k[len(prefix):]: v for k, v in inits.items() if k.startswith(prefix)}
    bw, gw, edges, long_fft, basis = GEOMETRY[stem]
    unnamed = []
    for name, value in inits.items():
        if not name.startswith("onnx::"): continue
        out, bias = consumers[name][0].output[0], None
        for _ in range(4):
            nxt = consumers.get(out, [])
            if not nxt: break
            named = [x for x in nxt[0].input if x.startswith(prefix)]
            if named and nxt[0].op_type == "Add":
                bias = named[0][len(prefix):]
                break
            out = nxt[0].output[0]
        if bias and bias.endswith(".bias"): W[bias[:-5] + ".weight"] = np.swapaxes(value, -1, -2)
        elif value.shape == (512, basis): W["waveform_encode.weight"] = value.T
        elif value.shape == (basis, 512): W["waveform_decode.weight"] = value.T
        else: unnamed.append((int(name.rsplit("_", 1)[1]), value))
    if long_fft:  # long encoders have no bias; they come in graph order, one per group
        for i, (_, v) in enumerate(sorted(unnamed, key=lambda kv: kv[0])):
            W[f"backbone.long_encoders.{i}.weight"] = np.swapaxes(v, -1, -2)
    elif unnamed:
        sys.exit(f"{stem}: unidentified tensors {[n for n, _ in unnamed]}")

    def per_band(key, with_bias=True):
        for gi, (first, last, _) in enumerate(groups(edges)):
            for j in range(last - first):
                yield W[f"backbone.{key}.{gi}.weight"][j]
                if with_bias: yield W[f"backbone.{key}.{gi}.bias"][j]

    out = list(per_band("encoders"))
    if long_fft: out += list(per_band("long_encoders", with_bias=False))
    out += [W["backbone.band_identity"], W["backbone.input_norm.weight"]]
    for l in range(2):
        out += [W[f"backbone.local.{l}.{k}_l0"] for k in ("weight_ih", "weight_hh", "bias_ih", "bias_hh")]
        out += [W[f"backbone.local_norm.{l}.weight"], W[f"backbone.global_in.{l}.weight"], W[f"backbone.global_in.{l}.bias"]]
        out += [W[f"backbone.global_memory.{l}.{k}_l0"] for k in ("weight_ih", "weight_hh", "bias_ih", "bias_hh")]
        out += [W[f"backbone.global_norm.{l}.weight"], W[f"backbone.global_out.{l}.weight"], W[f"backbone.global_out.{l}.bias"]]
    nb = len(edges) - 1
    for b in range(nb):
        out += [W["backbone.mask_hidden.weight"][b], W["backbone.mask_hidden.bias"][b]]
    out += list(per_band("mask_heads"))
    if basis:
        out += [W["waveform_encode.weight"], W["waveform_gates.weight"], W["waveform_gates.bias"], W["waveform_decode.weight"]]
    return out


src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
flat = [t.reshape(-1) for stem in GEOMETRY for t in tensors(str(src / f"{stem}.onnx"), stem)]
data = np.concatenate(flat).astype("<f4")
assert np.isfinite(data).all()
dst.write_bytes(data.tobytes())
print(f"Wrote {dst} ({data.size:,} weights)")
