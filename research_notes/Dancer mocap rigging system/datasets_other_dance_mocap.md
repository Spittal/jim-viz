# Other freely downloadable dance mocap datasets (beyond AIST++/CMU/Mixamo/Rokoko), as of 2026-11-25

Scope note: licence wording was read from the primary page wherever the page could be fetched. Where a
page could not be fetched (dancedb.cs.ucy.ac.cy has a broken TLS chain; resources.mpi-inf.mpg.de/HDM05
returned 403; bones.studio licence page returned 500) the finding comes from search-result snippets and
is marked "snippet only". Quotes are verbatim but short; the fetch tool caps quote length.

## 1. Exact licence per source: redistribution, derivatives, commercial use, attribution

### Takeaway
Within this scope no dataset that contains real club/street dance is both redistributable and commercial-OK.
The only cleanly permissive mocap found is 100STYLE (CC BY 4.0, stylised locomotion, not dance) and
DeepDance (CC BY 4.0, improvised dance, but marker/joint positions in TSV, not a rotation skeleton).
Everything with hip hop, popping, locking, charleston or jazz (Motorica, FineDance, ChoreoMaster, Bandai
Namco, LaFAN1) is non-commercial, and Motorica and FineDance also forbid redistribution.

### Cited Findings

**Bandai Namco Research Motion Dataset 1 and 2: CC BY-NC 4.0**
- The repo README lists "Bandai-Namco-Research-Motiondataset-1: CC BY-NC 4.0" and "Bandai-Namco-Research-Motiondataset-2: CC BY-NC 4.0", under the sentence "The datasets and scripts are available in the following lincenses." (sic). The Blender visualisation script is MIT. — [GitHub README](https://github.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset)
- The per-dataset LICENSE file is the standard Creative Commons text headed "Attribution-NonCommercial 4.0 International". — [dataset-1 LICENSE](https://raw.githubusercontent.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset/master/dataset/Bandai-Namco-Research-Motiondataset-1/LICENSE)
- The dataset-1 README also carries "© [2022] Bandai Namco Research Inc. All Rights Reserved." — [dataset-1 README](https://raw.githubusercontent.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset/master/dataset/Bandai-Namco-Research-Motiondataset-1/README.md)
- Verdict: redistribution of converted files OK (non-commercially), derivatives OK, commercial use NOT OK, attribution required.

**100STYLE: CC BY 4.0**
- "This work is licensed under a Creative Commons Attribution 4.0 International License." — [100STYLE project page](https://www.ianxmason.com/100style/)
- The Zenodo record lists the licence as Creative Commons Attribution 4.0 International. — [Zenodo 8127870](https://zenodo.org/records/8127870)
- Verdict: redistribution OK, derivatives OK, commercial OK, attribution required.

**Ubisoft LaFAN1: CC BY-NC-ND 4.0**
- "This dataset can be used under the Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International Public License (see license.txt)." — [GitHub README](https://github.com/ubisoft/ubisoft-laforge-animation-dataset)
- license.txt is the unmodified standard text, titled "Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International Public License". — [license.txt](https://raw.githubusercontent.com/ubisoft/ubisoft-laforge-animation-dataset/master/license.txt)
- Verdict: verbatim redistribution OK (non-commercially); sharing adapted material NOT OK; commercial NOT OK; attribution required.

**Motorica Dance Dataset: custom research-only, no redistribution**
- "The Motorica Dance Dataset is free to use for research purposes by academic institutes, companies, and individuals." — [GitHub README](https://github.com/simonalexanderson/MotoricaDanceDataset)
- "Use for commercial purposes is not permitted without prior written consent." — [GitHub README](https://github.com/simonalexanderson/MotoricaDanceDataset)
- "Unauthorised redistribution of any content from the database is prohibited" — [GitHub README](https://github.com/simonalexanderson/MotoricaDanceDataset)
- "You also acknowledge that all MUSIC AUDIO has its own Copyright Holders and is not subjected to this license." — [GitHub README](https://github.com/simonalexanderson/MotoricaDanceDataset)
- The terms define commercial use to include putting the data into a commercial product or service, and direct commercial enquiries to a contact email (paraphrase; the sentences were too long to quote). — [README raw](https://raw.githubusercontent.com/simonalexanderson/MotoricaDanceDataset/main/README.md)
- Verdict: redistribution NOT OK, commercial NOT OK without written consent, attribution required ("Motorica Dance Dataset" plus repo link).

**FineDance: custom non-commercial research licence, no redistribution**
- The LICENSE file is titled "Software Copyright License for non-commercial scientific research purposes" and covers data, models and software. It permits non-commercial research, education and artistic projects; bars commercial use; and bars copying, sharing, selling, sublicensing or transferring beyond one archival copy (paraphrased by the fetch tool, not quoted). — [FineDance LICENSE](https://raw.githubusercontent.com/li-ronghui/FineDance/main/LICENSE)
- Verdict: redistribution NOT OK, commercial NOT OK, citation required.

**PopDanceSet (POPDG): repo labelled MIT; data is video-fitted from BiliBili**
- The GitHub repo shows an "MIT license" label; no separate data licence is stated. — [Luke-Luo1/POPDG](https://github.com/Luke-Luo1/POPDG)
- "the dance pose data in PopDanceSet are derived solely from monocular pose estimation algorithms coupled with manual filtering" — [PopDanceSet_Description.md](https://raw.githubusercontent.com/Luke-Luo1/POPDG/main/docs/PopDanceSet_Description.md)
- Source videos come from BiliBili. — [arXiv 2405.03178](https://arxiv.org/html/2405.03178v2)
- Verdict: ambiguous. MIT is stated for the repository, but the underlying choreography and videos belong to third-party uploaders.

**EDGE (Stanford-TML): no own motion data**
- The repo is labelled MIT and its setup downloads and processes AIST++ ("Download and process the AIST++ dataset (wavs and motion only)"); it releases a model checkpoint, not a motion dataset. — [Stanford-TML/EDGE](https://github.com/Stanford-TML/EDGE)
- Verdict: nothing to take here; the data is AIST++ (covered by another researcher).

**Dance Motion Capture Database, University of Cyprus (dancedb): conflicting terms, snippet only**
- Search snippets of the FAQ say other data on the site is under "Creative Commons Attribution-ShareAlike 3.0 Unported", that the data may be included in commercially sold products, but may not be resold directly, even in converted form. — [dancedb FAQ](https://dancedb.cs.ucy.ac.cy/main/faq) (snippet only; page not fetchable)
- Search snippets of the Performances page show a "Software Copyright License for Non-Commercial Scientific Research Purposes". — [dancedb performances](https://dancedb.cs.ucy.ac.cy/main/performances) (snippet only)
- The sister Dance Museum site's licence requires contacting UCY for commercial use, including integration into commercial products or services. — [dancemuseum licence](https://dancemuseum.cs.ucy.ac.cy/license.html) (snippet only)
- SMPL versions of the data fall under AMASS terms and need an AMASS login. — [dancedb FAQ](https://dancedb.cs.ucy.ac.cy/main/faq) (snippet only)
- Verdict: ambiguous. Treat as non-commercial until UCY confirms in writing.

**SFU Motion Capture Database: research only**
- "This dataset of motions is free for research purposes." — [mocap.cs.sfu.ca](https://mocap.cs.sfu.ca/)
- "The data cannot be used for commercial products or resale, unfortunately." — [mocap.cs.sfu.ca](https://mocap.cs.sfu.ca/)
- Verdict: commercial NOT OK. Redistribution is not addressed. Acknowledgement requested.

**HDM05: CC BY-SA 3.0 (snippet only)**
- The project page says the database is licensed under a Creative Commons Attribution-ShareAlike 3.0 Unported License. — [HDM05](https://resources.mpi-inf.mpg.de/HDM05/index.html) (snippet only; page returned 403 to direct fetch)
- Verdict: redistribution OK, derivatives OK under the same licence, commercial OK, attribution required.

**ChoreoMaster (NetEase): research only**
- "This dataset can only be used for the sole purpose of performing non-commercial scientific research." — [NetEase-GameAI/ChoreoMaster](https://github.com/NetEase-GameAI/ChoreoMaster)
- "Any other use, in particular any use for commercial purposes, is prohibited." — [NetEase-GameAI/ChoreoMaster](https://github.com/NetEase-GameAI/ChoreoMaster)
- Verdict: commercial NOT OK. Redistribution not explicitly granted.

**PhantomDance: repo labelled MIT; hand-animated, not mocap**
- The repo shows an "MIT license" label and calls itself "the first dance dataset crafted by professional animators". — [libuyu/PhantomDanceDataset](https://github.com/libuyu/PhantomDanceDataset)
- Verdict: MIT would allow everything with attribution, but the data sits on Google Drive/Baidu, not in the repo, so whether MIT covers it is not explicit.

**Truebones free packs: no licence text found**
- The "FREE TOP 40 Dance Grooves Pak in I-Clone 7 and .BVH format" listing has no licence or usage terms on its page. — [Gumroad listing](https://truebones.gumroad.com/l/nbszf)
- Verdict: unknown. Not safe to redistribute.

**DeepDance (University of Oslo): CC BY 4.0**
- The Zenodo record lists Creative Commons Attribution 4.0 International. — [Zenodo 5838179](https://zenodo.org/records/5838179)
- Verdict: redistribution OK, derivatives OK, commercial OK, attribution required. (The included audio stimuli are in the same record; "Song e" is credited to a different artist.)

**Movement Journal corpus (Zenodo, e.g. Botswana Dance I/II): CC BY 4.0 but no BVH in the record**
- The record is CC BY 4.0 and describes a BVH of 2:15, but its only listed file is a 555-byte README.md. — [Zenodo 19025804](https://zenodo.org/records/19025804)

**Duolando DD100: NTU S-Lab License 1.0**
- "This project is licensed under NTU S-Lab License 1.0" and "Redistribution and use should follow this license." — [lisiyao21/Duolando](https://github.com/lisiyao21/Duolando)

**AIOZ-GDance: non-commercial research; video-fitted**
- Its licence covers non-commercial scientific research use only. — [AIOZ-GDANCE LICENSE](https://github.com/aioz-ai/AIOZ-GDANCE/blob/main/LICENSE) (snippet only)

**BONES-SEED (Bones Studio, Hugging Face): custom "bones-seed-license", gated**
- The card names the licence "bones-seed-license", requires login and acceptance ("You need to agree to share your Hugging Face information to access this dataset."), and points to licensing@bones.studio. — [bones-studio/seed](https://huggingface.co/datasets/bones-studio/seed)

**Quaternius Universal Animation Library: CC0, no dance listed**
- Licence is CC0 and "Free to use in personal, educational and commercial projects"; the described categories are locomotion, combat, emotes and similar, with no dance mentioned. — [Quaternius](https://quaternius.com/packs/universalanimationlibrary.html)

**tulay-hub/dance-dataset: MIT label, provenance unknown**
- The README itself warns: "Before publishing or redistributing the dataset, verify license, performer privacy, attribution, filename mapping, frame rate, coordinate frame, and third-party restrictions." — [README](https://raw.githubusercontent.com/tulay-hub/dance-dataset/main/README.md)

**Other free packs with no stated licence**
- Kevdev "Human Dance Animations FREE" (itch.io, name your own price) states no licence. — [itch.io](https://kevdev.itch.io/human-dance-animations-free)
- XenoMocap "[FREE] 2025 Trendy Dance Collection" (10 titled dances, 11 clips) states no licence on the forum post; terms live on its Fab listing. — [Unreal forum](https://forums.unrealengine.com/t/xenomocap-free-2025-trendy-dance-collection-mocap-pack/2679546)

### Inferences
- CC BY-NC (Bandai Namco) allows committing converted files to a public repo, but shipping them in a sold app is commercial use. If the app may ever be sold, Bandai Namco is out unless a separate licence is obtained.
- CC BY-NC-ND (LaFAN1) is the most restrictive CC licence: retargeting to another skeleton, trimming or resampling is very likely "adapted material" that may not be shared. A pure container change is the only arguable exception. LaFAN1 is out on two counts.
- HDM05's ShareAlike would bind the converted motion files (they must stay CC BY-SA), not necessarily the app's code; that boundary is a legal judgement this research did not settle.
- A repository-level "MIT" label on PopDanceSet, PhantomDance and tulay-hub does not prove the authors hold the rights to the motion. PopDanceSet is derived from third-party videos; tulay-hub's own README tells the reader to verify the licence.
- The dancedb FAQ wording as reported in the snippet closely mirrors the CMU mocap terms, and a large part of dancedb also circulates through AMASS; the site appears to host several licence regimes side by side.

### Gaps
- dancedb licence text was not read directly (TLS certificate chain fails for every fetch). The conflict between the CC BY-SA 3.0 FAQ wording and the non-commercial licence on the Performances page is unresolved. Needs a browser visit or an email to UCY.
- HDM05 licence was not read directly (403). Confirm in a browser.
- BONES-SEED licence terms unknown (licence page returned HTTP 500; search found nothing).
- FineDance licence is paraphrased, not quoted.
- Berkeley MHAD: no licence information found, and no evidence of dance content. Not pursued further.
- "Mocap.fr" was not found as a source. No licence found for any Truebones free pack.
- NTU S-Lab License 1.0 text was not fetched; from memory it is non-commercial, unverified here.

## 2. Download without login? Direct URLs and size

### Takeaway
100STYLE, DeepDance, LaFAN1 and Bandai Namco download with no form. Motorica, FineDance, ChoreoMaster, PhantomDance and PopDanceSet are open SharePoint/Google Drive links. BONES-SEED is gated behind a Hugging Face agreement.

### Cited Findings
- 100STYLE: Zenodo, 16.2 GB total. `100STYLE.zip` 1.5 GB holds the raw BVH; `100Style-Labelled-Data.zip` 14.8 GB holds processed features. — [Zenodo 8127870](https://zenodo.org/records/8127870)
- DeepDance: Zenodo, one archive `DeepDance_v01.zip`, 206.2 MB; a newer version of the record exists. — [Zenodo 5838179](https://zenodo.org/records/5838179)
- LaFAN1: `lafan1/lafan1.zip` in the repo via Git LFS, about 137 MB. — [GitHub README](https://github.com/ubisoft/ubisoft-laforge-animation-dataset)
- Bandai Namco: BVH and JSON annotations inside `data.zip` in each dataset folder of the GitHub repo. — [dataset-1 README](https://raw.githubusercontent.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset/master/dataset/Bandai-Namco-Research-Motiondataset-1/README.md)
- Motorica: KTH SharePoint folder, https://kth-my.sharepoint.com/:f:/g/personal/simonal_ug_kth_se/IgC-FlBB7gLRR5KIF4Jmsp6dAb3zrmQYayK8Xh2wVyUcoGk?e=VYwCCW ; size not stated. — [README raw](https://raw.githubusercontent.com/simonalexanderson/MotoricaDanceDataset/main/README.md)
- FineDance: Google Drive and Baidu links, no form mentioned; size not stated. — [li-ronghui/FineDance](https://github.com/li-ronghui/FineDance)
- PopDanceSet: https://drive.google.com/file/d/11phw8Xxcnx5h4yYQVpLqDdKWSkHpBZuu/view?usp=sharing — [PopDanceSet_Description.md](https://raw.githubusercontent.com/Luke-Luo1/POPDG/main/docs/PopDanceSet_Description.md)
- ChoreoMaster: Google Drive file link. — [NetEase-GameAI/ChoreoMaster](https://github.com/NetEase-GameAI/ChoreoMaster)
- PhantomDance: Google Drive and Baidu NetDisk. — [libuyu/PhantomDanceDataset](https://github.com/libuyu/PhantomDanceDataset)
- SFU: per-clip file links, no bulk download; several dance links point at .html files instead of data. — [mocap.cs.sfu.ca](https://mocap.cs.sfu.ca/)
- BONES-SEED: 114 GB, gated. — [bones-studio/seed](https://huggingface.co/datasets/bones-studio/seed)
- DD100: Google Drive file link, no form. — [lisiyao21/Duolando](https://github.com/lisiyao21/Duolando)

### Inferences
- Only the Zenodo and GitHub-hosted sets (100STYLE, DeepDance, LaFAN1, Bandai Namco) have durable, citable URLs. Drive and SharePoint links can vanish.

### Gaps
- Sizes for Motorica, FineDance, Bandai Namco zips, ChoreoMaster, PhantomDance and PopDanceSet are not stated on their pages.
- Whether dancedb needs a login for FBX/C3D was not confirmed (site unreachable by the tools).

## 3. Formats, skeleton, frame rate, units, up axis

### Takeaway
BVH with a single consistent skeleton is available from Bandai Namco (30 fps), 100STYLE (60 fps, 28 bones), LaFAN1 (30 fps) and Motorica (120 fps). The research dance sets are SMPL-family arrays (FineDance SMPL-H, PopDanceSet SMPL, DD100 SMPL-X, PhantomDance 24-joint JSON). Joint names, clavicles, spine length, toes, units and up axis were mostly not stated on the pages read.

### Cited Findings
- Bandai Namco dataset 1: BVH plus JSON annotations, 30 fps, 175 files, 36,673 frames. — [dataset-1 README](https://raw.githubusercontent.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset/master/dataset/Bandai-Namco-Research-Motiondataset-1/README.md)
- Bandai Namco dataset 2: BVH, 384,931 frames. — [GitHub README](https://github.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset)
- 100STYLE: unedited BVH, 60 fps, 28-bone skeleton rooted at Hips, captured with an Xsens (inertial) system; 810 BVH files, over 4 million frames. — [100STYLE project page](https://www.ianxmason.com/100style/)
- LaFAN1: BVH, 30 fps, 77 sequences, 496,672 frames, about 4.6 hours, 5 subjects. — [GitHub README](https://github.com/ubisoft/ubisoft-laforge-animation-dataset)
- Motorica: BVH at 120 fps, all retargeted to a single skeleton; optical marker-based OptiTrack with 17 Prime41 cameras. — [GitHub README](https://github.com/simonalexanderson/MotoricaDanceDataset)
- Motorica fingers vary by session: session 1 has 10 markers per hand, session 2 has no finger motion, session 3 used Manus gloves with drift, session 4 has simplified finger markers (thumb, index, pinky). — [GitHub README](https://github.com/simonalexanderson/MotoricaDanceDataset)
- FineDance: motion as .npy in SMPL-H format (first 3 columns translation, rest poses), music as .wav plus librosa features. — [li-ronghui/FineDance](https://github.com/li-ronghui/FineDance)
- ChoreoMaster: .fbx motion at 30 fps with a T-pose model file; 160,136 frames. — [NetEase-GameAI/ChoreoMaster](https://github.com/NetEase-GameAI/ChoreoMaster)
- PhantomDance: JSON at 30 fps with `bone_name`, `root_positions` (T×3, metres) and `rotations` (T×N×4 quaternions, XYZW); SMPL-style 24 joints; Unity world space (x right, y up, z forward). — [libuyu/PhantomDanceDataset](https://github.com/libuyu/PhantomDanceDataset)
- SFU: .bvh, .c3d, .fbx, .hdf, .txt per clip (the two Bollywood clips only .bvh and .hdf), plus per-subject .vsk. — [mocap.cs.sfu.ca](https://mocap.cs.sfu.ca/)
- HDM05: C3D and ASF/AMC; file names carry a "_120" suffix. — [HDM05](https://resources.mpi-inf.mpg.de/HDM05/index.html) (snippet only)
- dancedb: FBX and C3D plus video for every performance. — [dancedb](https://dancedb.cs.ucy.ac.cy) (snippet only)
- DeepDance: tab-separated .tsv from a Qualisys optical system, captured at 250 Hz and downsampled to 30 fps; segments standardised across dancers and root at the origin. — [Zenodo 5838179](https://zenodo.org/records/5838179)
- DD100: SMPL-X sequences as .npy, two dancers per take; derived features are 55 joints. — [lisiyao21/Duolando](https://github.com/lisiyao21/Duolando)
- BONES-SEED: BVH on the "SOMA" skeleton (proportional and uniform variants) at 120 fps, plus Unitree G1 CSV. — [bones-studio/seed](https://huggingface.co/datasets/bones-studio/seed)
- Truebones free dance pack: iClone 7 and BVH. — [Gumroad listing](https://truebones.gumroad.com/l/nbszf)

### Inferences
- DeepDance has no joint rotations and its root is pinned to the origin, so it needs an IK/rotation solve and has no travel across the floor. It is the weakest fit for a rigged dancer despite the clean licence.
- 100STYLE is inertial (Xsens), so expect foot sliding and drift compared with optical sets; it has no finger data by nature of a 28-bone body skeleton.
- Motorica at 120 fps optical with one retargeted skeleton is technically the best match for the brief; its licence is the blocker.

### Gaps
- Not verified on any page read: joint names, clavicle presence, spine chain length, toe joints, units and up axis for Bandai Namco, LaFAN1, Motorica and 100STYLE. These need a look at a BVH header. Unverified recollection: Bandai Namco uses about 21 joints and LaFAN1 22 joints with no fingers; treat as leads only.
- DD100 capture method and fps, FineDance fps and capture system, ChoreoMaster capture method: not stated on the pages read.

## 4. Dance styles, clip counts, duration, capture quality, fingers

### Takeaway
Motorica is the only source here that covers several target styles with optical quality (hip hop, popping, locking, krump, charleston, jazz, tap). No source found covers house, shuffle, voguing, waacking, disco, rave or slow R&B by name. The permissive sets carry almost no dance.

### Cited Findings
- Motorica: 8 styles, about 6 hours. Minutes per style: Hiphop 84 (2 dancers), Krumping 18 (1), Popping 42 (2), Locking 18 (2), Jazz 52 (2), Charleston 50 (2), Tapping 11 (2), Casual 85. — [GitHub README](https://github.com/simonalexanderson/MotoricaDanceDataset)
- Bandai Namco dataset 1: 17 content types "including daily activities, fighting, and dancing", 15 styles, three professional actors; dance contents are `dance-long` and `dance-short`, normal style only. Dataset 2: 10 types, mainly locomotion and hand actions, 7 styles; no dance mentioned. — [GitHub README](https://github.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset); [dataset-1 README](https://raw.githubusercontent.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset/master/dataset/Bandai-Namco-Research-Motiondataset-1/README.md)
- LaFAN1: 8 "Dance" sequences described as free dancing, out of 77. — [GitHub README](https://github.com/ubisoft/ubisoft-laforge-animation-dataset)
- 100STYLE: 100 locomotion styles, 8 gaits each. The page classes none as dance; style names include Robot, WiggleHips, Strutting, Morris, SpinClock, SpinAntiClock, SwingShoulders, SwingArmsRound, WhirlArms, Skip, SlideFeet, BouncyLeft/Right, Star, Teapot, Zombie. — [100STYLE project page](https://www.ianxmason.com/100style/)
- FineDance: 7.7 hours downloadable, with a FineDance@Genre split covering "a broader range of dance genres"; genre list not on the README. — [li-ronghui/FineDance](https://github.com/li-ronghui/FineDance)
- PopDanceSet: 305 videos cut into 1,036 clips, 237 songs, 12,713 train + 355 test seconds; poses from HybrIK monocular estimation. — [PopDanceSet_Description.md](https://raw.githubusercontent.com/Luke-Luo1/POPDG/main/docs/PopDanceSet_Description.md)
- PopDanceSet is listed with 19 genres in the paper's comparison table. — [arXiv 2405.03178](https://arxiv.org/html/2405.03178v2) (snippet only)
- ChoreoMaster: 2,708 motion "meters", 1.48 hours released out of 9.91 hours. — [NetEase-GameAI/ChoreoMaster](https://github.com/NetEase-GameAI/ChoreoMaster)
- PhantomDance v1.2: 260 dance-music pairs, about 9.5 hours, hand-animated; preview file names suggest Chinese, Otaku, Jazz and Hip-hop. — [libuyu/PhantomDanceDataset](https://github.com/libuyu/PhantomDanceDataset)
- SFU dance: 11 clips. Cha cha (Latin), Moonwalk (Pop), seven Chinese clips including Xinjiang steps, two Bollywood. — [mocap.cs.sfu.ca](https://mocap.cs.sfu.ca/)
- dancedb: Greek and Cypriot folk, contemporary, plus flamenco, belly dance, salsa and hip-hop, per a 2019 ISMIR paper. — [ISMIR 2019 paper](https://archives.ismir.net/ismir2019/paper/000060.pdf) (snippet only)
- HDM05: more than 70 motion classes, mostly everyday and athletic; a review paper's table lists "Dance" among its classes without naming dances. — [arXiv 1903.08356](https://arxiv.org/pdf/1903.08356) (snippet only)
- DeepDance: nine dancers, six one-minute pieces, three performances each, 162 files, improvised dance with no named style. — [Zenodo 5838179](https://zenodo.org/records/5838179)
- DD100: about 117 minutes of duet dance by professional dancers; genres include Ballet, Waltz and Tango. — [lisiyao21/Duolando](https://github.com/lisiyao21/Duolando)
- BONES-SEED: 142,220 motions (71,132 original), about 288 hours, 522 performers; the Dances package holds 11,006 motions across "multiple styles". — [bones-studio/seed](https://huggingface.co/datasets/bones-studio/seed)

### Inferences
- From 100STYLE, "Robot" is a plausible robot-walk source and "WiggleHips"/"SwingShoulders"/"Strutting" are plausible hip-sway and groove sources, but these are walks in a style, not on-the-spot dancing to a beat. The in-place (ID) take of each style is the closest to a dance loop.
- Target styles with no source at all in this scope: house, shuffle, voguing, waacking, disco, rave. Lindy hop/charleston/swing exists only in Motorica (charleston, 50 minutes).
- BONES-SEED is the largest dance collection found (11,006 clips at 120 fps BVH) and worth one licence read by a human, since its terms could not be retrieved.

### Gaps
- Clip counts for Motorica, FineDance and both Bandai Namco dance categories are not stated.
- FineDance's genre list and capture system were not on the README (the paper has them; not fetched).
- Whether any Bandai Namco, LaFAN1 or 100STYLE BVH carries finger joints was not verified.

## 5. Music, BPM and beat annotations

### Takeaway
None of the sources read ships explicit BPM or beat-time annotations. Motorica, FineDance, ChoreoMaster, PhantomDance, DD100 and DeepDance ship audio or audio features, from which tempo would have to be estimated.

### Cited Findings
- Motorica: the download holds music with cleared rights (session 3 jazz by Stockholm Swing Allstars for the jazz, charleston and tap takes); session 4 music is fetched from YouTube by script; session 2 pop songs come only as extracted features in pkl DataFrames. The README does not mention tempo, BPM or beats. — [README raw](https://raw.githubusercontent.com/simonalexanderson/MotoricaDanceDataset/main/README.md)
- FineDance: `music_wav`, `music_npy` (librosa features) and `label_json` song metadata. — [li-ronghui/FineDance](https://github.com/li-ronghui/FineDance)
- ChoreoMaster: music clips plus JSON labels with two music-style fields, two motion-style fields and an 8-bit rhythm signature per meter; no BPM. — [NetEase-GameAI/ChoreoMaster](https://github.com/NetEase-GameAI/ChoreoMaster)
- PhantomDance: one WAV per motion at 16 kHz. — [libuyu/PhantomDanceDataset](https://github.com/libuyu/PhantomDanceDataset)
- DeepDance: six audio stimuli as .wav, one minute each. — [Zenodo 5838179](https://zenodo.org/records/5838179)
- DD100: .mp3 per take. — [lisiyao21/Duolando](https://github.com/lisiyao21/Duolando)
- PopDanceSet: 237 songs; preprocessing extracts baseline and Jukebox music features. — [PopDanceSet_Description.md](https://raw.githubusercontent.com/Luke-Luo1/POPDG/main/docs/PopDanceSet_Description.md)

### Inferences
- Bandai Namco, LaFAN1, 100STYLE, SFU and HDM05 pages mention no music at all, so their dance clips have no tempo reference; a beat period would have to be estimated from the motion itself.
- ChoreoMaster's per-meter rhythm signature is the only beat-level structure found, and it is under a research-only licence.
- Music in any of these sets is separately copyrighted (Motorica says so outright); only the motion is a candidate for shipping.

### Gaps
- Whether FineDance's `label_json` carries BPM was not checked.

## 6. Caveats

### Takeaway
The clean-licence sets are a poor style fit and the good-style sets are licence-blocked; several "MIT" or "free" labels do not stand up to a provenance check.

### Cited Findings
- Motorica warns: "We do not guarantee the quality of the database, which may contain errors such as noisy motion data", and notes audio-motion sync problems. — [GitHub README](https://github.com/simonalexanderson/MotoricaDanceDataset)
- PopDanceSet's own authors say monocular estimation "inherently lacks the quality of data extracted using motion capture device". — [PopDanceSet_Description.md](https://raw.githubusercontent.com/Luke-Luo1/POPDG/main/docs/PopDanceSet_Description.md)
- LaFAN1's zip is Git LFS; a plain clone gives an invalid file. — [GitHub README](https://github.com/ubisoft/ubisoft-laforge-animation-dataset)
- Bandai Namco dataset-1 README says 20 contents but lists fewer, and `dance-short` and `punch` appear only in its visualisation section. — [dataset-1 README](https://raw.githubusercontent.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset/master/dataset/Bandai-Namco-Research-Motiondataset-1/README.md)
- The Zenodo "Movement Journal" record advertises BVH but lists only a README. — [Zenodo 19025804](https://zenodo.org/records/19025804)
- Truebones' "free" Top 40 Dance pack: a search result showed a "$2+" price on the listing while the page title says FREE; no licence text either way. — [Gumroad listing](https://truebones.gumroad.com/l/nbszf)
- SFU: several dance download links point to .html files. — [mocap.cs.sfu.ca](https://mocap.cs.sfu.ca/)

### Inferences
- If the app might be sold, the realistic routes for the target styles are: (1) write to Motorica (commercial licence by consent is explicitly offered), (2) have a human read the BONES-SEED licence, (3) rely on the other researcher's sources, or (4) author the styles procedurally and use 100STYLE only for groove and gait flavour.

### Gaps
- No Kaggle or Sketchfab dance mocap with an explicit CC0/CC BY licence was found in the searches run; this is absence of results from a few queries, not an exhaustive check. Sketchfab licences are per asset.
- The Xsens/Movella free dance pack (7 FBX dance clips per a search snippet) could not be read: the page now returns 404.

## 7. Ranked shortlist

### Takeaway
(a) Redistributable and commercial-OK: 100STYLE, DeepDance, and HDM05 if its CC BY-SA 3.0 is confirmed. (b) Redistributable but non-commercial: Bandai Namco 1 and 2; LaFAN1 only unmodified. (c) Not redistributable: Motorica, FineDance, ChoreoMaster, SFU, and everything with unknown terms.

### Cited Findings
**(a) Public repo AND commercial OK**
1. 100STYLE, CC BY 4.0, BVH 60 fps, 28 bones, Xsens. Could supply: robot (Robot), hip sway (WiggleHips, SwingShoulders, Strutting), bouncy grooves (BouncyLeft/Right, Skip), spins. Not true dance. — [100STYLE project page](https://www.ianxmason.com/100style/)
2. DeepDance, CC BY 4.0, Qualisys optical, 162 one-minute improvised takes, TSV positions at 30 fps. Could supply: free improvised club-style movement, after a rotation solve. — [Zenodo 5838179](https://zenodo.org/records/5838179)
3. HDM05, CC BY-SA 3.0 (snippet only), ASF/AMC and C3D. Some "Dance" class content, unnamed. — [HDM05](https://resources.mpi-inf.mpg.de/HDM05/index.html)
4. Quaternius Universal Animation Library, CC0, but no dance listed. — [Quaternius](https://quaternius.com/packs/universalanimationlibrary.html)

**(b) Public repo OK, non-commercial only**
1. Bandai Namco dataset 1, CC BY-NC 4.0, BVH 30 fps: `dance-long`, `dance-short` (style unnamed). — [GitHub README](https://github.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset)
2. LaFAN1, CC BY-NC-ND 4.0, BVH 30 fps: 8 free-dance sequences, redistributable only unmodified. — [GitHub README](https://github.com/ubisoft/ubisoft-laforge-animation-dataset)

**(c) Not redistributable, or terms unknown**
1. Motorica: hip hop, popping, locking, krump, charleston, jazz, tap, casual. Best style and quality fit; needs written consent. — [GitHub README](https://github.com/simonalexanderson/MotoricaDanceDataset)
2. FineDance: many genres, SMPL-H, no redistribution. — [FineDance LICENSE](https://raw.githubusercontent.com/li-ronghui/FineDance/main/LICENSE)
3. ChoreoMaster: research only. — [NetEase-GameAI/ChoreoMaster](https://github.com/NetEase-GameAI/ChoreoMaster)
4. SFU: cha cha, moonwalk, Chinese, Bollywood; no commercial products. — [mocap.cs.sfu.ca](https://mocap.cs.sfu.ca/)
5. dancedb (UCY): salsa, hip-hop, flamenco, belly dance, folk; conflicting terms. — [dancedb FAQ](https://dancedb.cs.ucy.ac.cy/main/faq) (snippet only)
6. BONES-SEED: 11,006 dance clips; gated, terms unread. — [bones-studio/seed](https://huggingface.co/datasets/bones-studio/seed)
7. Ambiguous "MIT" labels: PhantomDance (hand-animated; Chinese, otaku, jazz, hip-hop), PopDanceSet (video-fitted), tulay-hub/dance-dataset (unknown origin). — [PhantomDance](https://github.com/libuyu/PhantomDanceDataset); [POPDG](https://github.com/Luke-Luo1/POPDG); [tulay-hub](https://github.com/tulay-hub/dance-dataset)
8. Truebones free packs, Kevdev, XenoMocap: no licence text found. — [Gumroad listing](https://truebones.gumroad.com/l/nbszf); [itch.io](https://kevdev.itch.io/human-dance-animations-free); [Unreal forum](https://forums.unrealengine.com/t/xenomocap-free-2025-trendy-dance-collection-mocap-pack/2679546)

### Inferences
- Style coverage against the target list, commercial-safe sources in this scope only: robot = 100STYLE (walk-based); hip sway = 100STYLE (walk-based); generic free dance = DeepDance; hip hop, lindy/charleston/swing, house, disco, popping, shuffle, voguing/waacking, rave = none.
- With non-commercial sources allowed: add an unnamed dance from Bandai Namco. Still nothing for house, shuffle, voguing, waacking, disco, rave.
- With a negotiated Motorica licence: hip hop, popping, locking, krump, charleston and jazz would be covered at 120 fps optical quality.
- PhantomDance is the only "permissive-labelled" source with hip-hop and jazz, but it is keyframe animation and the MIT scope over the Drive-hosted data should be confirmed with the authors before committing it.

### Gaps
- Category (a) has no named street or club dance style at all. This is a finding about the sources in this scope, not about AIST++/CMU/Mixamo/Rokoko, which another researcher covers.
- HDM05 and dancedb placements depend on licence text that could not be read directly.
