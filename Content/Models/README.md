# Models

`beatnet.bin`: the beat/downbeat network from BeatNet (model 1, trained with GTZAN held out),
converted to flat float32 by `scripts/export-beatnet.py`. The Clock runs it in
`Sources/JimViz/Clock/BeatNet.swift`.

BeatNet by Mojtaba Heydari, Frank Cwitkowitz and Zhiyao Duan, "BeatNet: CRNN and Particle
Filtering for Online Joint Beat Downbeat and Meter Tracking", ISMIR 2021.
https://github.com/mjhydri/BeatNet. Weights licensed CC-BY-4.0
(https://creativecommons.org/licenses/by/4.0/). Changed: converted from PyTorch to a flat
float32 file.
