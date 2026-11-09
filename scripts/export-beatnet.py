#!/usr/bin/env python3
# Usage: export-beatnet.py model_1_weights.pt Content/Models/beatnet.bin
#
# Converts BeatNet's PyTorch weights (https://github.com/mjhydri/BeatNet, CC-BY-4.0) to the flat
# little-endian float32 file `BeatNet.swift` reads. Needs only numpy: the .pt zip is decoded with
# an unpickler that rebuilds tensors and refuses everything else, so no pickled code runs.
#
# Order: conv1.weight (2×1×10), conv1.bias (2), linear0.weight (150×262), linear0.bias (150),
# then per LSTM layer 0 and 1: weight_ih (600×150), weight_hh (600×150), bias_ih (600),
# bias_hh (600), then linear.weight (3×150), linear.bias (3). Row-major.
import collections, pickle, sys, zipfile
import numpy as np

ORDER = ["conv1.weight", "conv1.bias", "linear0.weight", "linear0.bias"]
for l in range(2):
    ORDER += [f"lstm.weight_ih_l{l}", f"lstm.weight_hh_l{l}", f"lstm.bias_ih_l{l}", f"lstm.bias_hh_l{l}"]
ORDER += ["linear.weight", "linear.bias"]


def load(path):
    z = zipfile.ZipFile(path)
    root = z.namelist()[0].split("/")[0]

    class Storage:
        def __init__(self, name):
            if name != "FloatStorage": raise pickle.UnpicklingError(name)

    def rebuild(stor, offset, size, stride, *_):
        a = stor[offset:]
        return np.lib.stride_tricks.as_strided(a, shape=size, strides=[s * 4 for s in stride]).copy()

    class Unpickler(pickle.Unpickler):
        def find_class(self, mod, name):
            if (mod, name) == ("torch._utils", "_rebuild_tensor_v2"): return rebuild
            if (mod, name) == ("collections", "OrderedDict"): return collections.OrderedDict
            if mod == "torch" and name == "FloatStorage": return Storage(name)
            raise pickle.UnpicklingError(f"refusing {mod}.{name}")

        def persistent_load(self, pid):
            return np.frombuffer(z.read(f"{root}/data/{pid[2]}"), dtype="<f4")

    return Unpickler(z.open(f"{root}/data.pkl")).load()


sd = load(sys.argv[1])
assert sd["linear0.weight"].shape == (150, 262), sd["linear0.weight"].shape
out = np.concatenate([sd[k].astype("<f4").ravel() for k in ORDER])
out.tofile(sys.argv[2])
print(f"wrote {len(out)} floats to {sys.argv[2]}")
