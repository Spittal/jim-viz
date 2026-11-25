good# Motion clips

The Dancer's clips, a folder a style, baked by `scripts/bake-motion.py` (which describes the
`.jvmc` file).

They are adapted from the **AIST++ Dance Motion Dataset** (<https://google.github.io/aistplusplus_dataset/>),
© Google LLC, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/):

> Ruilong Li, Shan Yang, David A. Ross, Angjoo Kanazawa. *AI Choreographer: Music Conditioned
> 3D Dance Generation with AIST++.* ICCV 2021.

AIST++ annotates the AIST Dance Video Database (<https://aistdancedb.ongaaccel.jp>):

> Shuhei Tsuchida, Satoru Fukayama, Masahiro Hamasaki, Masataka Goto. *AIST Dance Video
> Database: Multi-genre, Multi-dancer, and Multi-camera Database for Dance Information
> Processing.* ISMIR 2019.

Changes made: only the advanced dances (`sFM`) are used, taken from the full set of motions in
the EDGE project's copy of AIST++ (<https://github.com/Stanford-TML/EDGE>). Each one's SMPL pose
parameters (the `motions` annotations) are converted to a rotation per joint for SMPL's 22 body
joints in this app's axes, set on a floor, its glitches in the fit bridged (or, where they
can't be, cut out, splitting it), smoothed, trimmed of standing about at either end, turned to
face front, centred, and stored at 30 fps with the tempo of the music it was danced to. No video
or music from the AIST Dance Video Database is included. A clip keeps its sequence's name
(`gHO_sFM_cAll_d20_mHO5_ch13` is house, advanced dance 13, dancer 20, music HO5); a piece of a
split one adds `_at<bar>`, where it starts. One advanced dance, `gPO_sFM_cAll_d10_mPO2_ch03`,
barely moves and is left out.

| Folder | AIST genre |
|---|---|
| hiphop | gMH, middle hip-hop |
| lahiphop | gLH, LA-style hip-hop |
| house | gHO |
| popping | gPO, pop |
| locking | gLO, lock |
| waacking | gWA, waack |
| krump | gKR |
| break | gBR |
| streetjazz | gJS |
| balletjazz | gJB |
