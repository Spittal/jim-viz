# Models

`beatnet.bin`: the beat/downbeat network from BeatNet (model 1, trained with GTZAN held out),
converted to flat float32 by `scripts/export-beatnet.py`. The Clock runs it in
`Sources/JimViz/Clock/BeatNet.swift`.

BeatNet by Mojtaba Heydari, Frank Cwitkowitz and Zhiyao Duan, "BeatNet: CRNN and Particle
Filtering for Online Joint Beat Downbeat and Meter Tracking", ISMIR 2021.
https://github.com/mjhydri/BeatNet. Weights licensed CC-BY-4.0
(https://creativecommons.org/licenses/by/4.0/). Changed: converted from PyTorch to a flat
float32 file.

`stemgen.bin`: StemgenRT's three causal stem separation models (drums, bass, vocals; v0.7
independent weights, as shipped with stemgen-rt 0.8.0), converted to flat float32 by
`scripts/export-stemgen.py`. Audio In's stems run them in `Sources/JimViz/Audio/StemSeparator.swift`.

StemgenRT by Axel Delafosse, https://github.com/sweetspotsoundsystem/stemgen-rt. Trained on
MUSDB18-HQ and MoisesDB (dataset credits in the project's MODEL_CARD.md). Weights licensed
CC BY-NC-SA 4.0 (https://creativecommons.org/licenses/by-nc-sa/4.0/): **non-commercial use
only**, and anything built from them must be shared under the same licence. The publisher's
notice is kept alongside as `stemgen-LICENSE.md`. Changed: converted from ONNX to a flat
float32 file; nothing else.

Source: `model/parallel/{drums,bass,vocals}.onnx` at commit
7d2d0c19d956f67259b8358c4127f991077e02b0, fetched from
`https://media.githubusercontent.com/media/sweetspotsoundsystem/stemgen-rt/<commit>/model/parallel/<stem>.onnx`.
SHA-256:
- drums.onnx `f2a3fc5dd90f45690536370f02d9b9377e6625ab08cb32b3e921371ad134d874`
- bass.onnx `1187b414f22344028035caba0a763d2211d13fe8bfce366c5f6b7ee4af77df40`
- vocals.onnx `f29a3d8fa596ce4672dd4dc77ccf224f2538389940264aad46ab8168311c2148`
