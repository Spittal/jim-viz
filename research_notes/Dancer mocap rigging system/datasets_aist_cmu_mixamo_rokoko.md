# Dance mocap sources: AIST++ / AIST Dance DB, CMU Mocap (+ cgspeed BVH), Mixamo, Rokoko — licences, contents, download logistics (checked 2026-11-25)

Method notes. "Checked" means I ran it on 2026-11-25: HTTP HEAD requests, a full download of the AIST++ `motions.zip`, `splits.zip` and `ignore_list.txt`, a central-directory listing of the two keypoint zips by HTTP range request, and a read of one CMU BVH and one ASF/AMC. The AIST++ pickles were read with a restricted unpickler (no numpy), so shapes, dtypes and value ranges are measured, not quoted. Licence wording is quoted from the raw page text fetched with curl unless marked as a paraphrase.

## 1. Licence: exact name and wording on redistribution, derivatives, commercial use, attribution (per source)

### Takeaway
Only the CMU database (original ASF/AMC and the Hahne BVH conversion) is clearly safe to convert, commit to a public repo and ship in a sold app: "You may include this data in commercially-sold products, but you may not resell this data directly, even in converted form." AIST++ annotations are labelled CC BY 4.0 by Google, but the upstream AIST Dance DB terms demand a commercial licence agreement for "any output developed or obtained through its use" in a product, so AIST++ is not safe for a sold app without AIST's written agreement. Mixamo and Rokoko both forbid distributing the raw animation files, which rules out a public repo.

### Cited Findings

**AIST++ annotations (Google)**
- Licence statement, in full: "The annotations are licensed by Google LLC under CC BY 4.0 license." The page links to https://creativecommons.org/licenses/by/4.0/ — [AIST++ Description page](https://google.github.io/aistplusplus_dataset/factsfigures.html)
- The same site sends users to AIST's terms for videos, images and music: "Before the downloading, please make sure you have read and agree with the Terms of Use of the AIST Dance Video Database." This sentence sits under the heading "Download the videos/images/music", not under "Download the annotations" — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)
- Requested citation: Li, Yang, Ross, Kanazawa, "AI Choreographer: Music Conditioned 3D Dance Generation with AIST++", ICCV 2021; "Please also consider citing the original AIST Dance Video Database" — [AIST++ Description page](https://google.github.io/aistplusplus_dataset/factsfigures.html)
- The code repo `google/aistplusplus_api` is Apache-2.0 (GitHub licence API). The data repo `google/aistplusplus_dataset` has no licence file detected (GitHub API returns `license: null`) — [aistplusplus_api LICENSE](https://github.com/google/aistplusplus_api/blob/main/LICENSE); [aistplusplus_dataset repo](https://github.com/google/aistplusplus_dataset)

**AIST Dance Video Database (videos and music; the source of AIST++)**
- No named licence; copyright line is "Copyright © 2019 National Institute of Advanced Industrial Science and Technology (AIST)" — [AIST Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/)
- Verbatim terms: "Please fill in the Application Form before using AIST Dance Video Database (AIST Dance DB)." — [AIST Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/)
- "AIST Dance DB is free to use for academic research. It is free to use for research purposes by academic institutions, companies, and individuals." — [AIST Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/)
- "If AIST Dance DB itself or any output developed or obtained through its use (including results, models, systems, and technologies) is subsequently incorporated into, deployed in, or otherwise used for the provision, operation, or offering of any product or service, you must contact aistdancedb-ml@aist.go.jp and enter into a commercial license agreement with AIST before such use. Unauthorized redistribution of any content of AIST Dance DB is prohibited." — [AIST Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/)
- Attribution: "it is necessary for you to clearly indicate the name of the database, "AIST Dance Video Database" or "AIST Dance DB", when using the database", and cite Tsuchida, Fukayama, Hamasaki, Goto, ISMIR 2019; fallback wording for non-academic use: "We have used the AIST Dance Video Database (https://aistdancedb.ongaaccel.jp)." — [AIST Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/)
- The AIST FAQ has three questions, all about research papers, demonstrations and streamed presentations. It says nothing on commercial use or derived data — [AIST FAQ](https://aistdancedb.ongaaccel.jp/faq/)

**CMU Graphics Lab Motion Capture Database (original)**
- No named licence (not CC, not MIT); it is a plain-language grant on the site. Home page: "This dataset of motions is free for all uses." — [mocap.cs.cmu.edu](http://mocap.cs.cmu.edu/)
- Home page, verbatim: "This data is free for use in research projects. You may include this data in commercially-sold products, but you may not resell this data directly, even in converted form. If you publish results obtained using this data, we would appreciate it if you would send the citation to your published paper to jkh+mocap@cs.cmu.edu, and also would add this text to your acknowledgments section: The data used in this project was obtained from mocap.cs.cmu.edu. The database was created with funding from NSF EIA-0196217." — [mocap.cs.cmu.edu](http://mocap.cs.cmu.edu/)
- FAQ "How can I use this data?": "The motion capture data may be copied, modified, or redistributed without permission." — [CMU FAQ](http://mocap.cs.cmu.edu/faqs.php)
- Disclaimer: "We do not guarantee the quality of the data." — [CMU FAQ](http://mocap.cs.cmu.edu/faqs.php)

**cgspeed / Bruce Hahne "Motionbuilder-friendly" BVH conversion**
- READMEFIRST v1.1 (June 26, 2010), "USAGE RIGHTS": "CMU places no restrictions on the use of the original dataset, and I (Bruce) place no additional restrictions on the use of this particular BVH conversion." — [READMEFIRST.txt in the GitHub mirror](https://github.com/una-dinosauria/cmu-mocap/blob/master/READMEFIRST.txt)
- The README quotes an older CMU paragraph: "Use this data! This data is free for use in research and commercial projects worldwide." This older wording lacks the "may not resell this data directly" clause that the CMU home page carries today — [READMEFIRST.txt](https://github.com/una-dinosauria/cmu-mocap/blob/master/READMEFIRST.txt); differs from [mocap.cs.cmu.edu](http://mocap.cs.cmu.edu/)
- The cgspeed release page says the files are "free to use worldwide for any purpose" and "provided as-is, without support or guarantees" (short quotes relayed by the fetch tool; the surrounding text is paraphrased) — [cgspeed release page](https://sites.google.com/a/cgspeed.com/cgspeed/motion-capture/the-motionbuilder-friendly-bvh-conversion-release-of-cmus-motion-capture-database)
- CMU itself points to this conversion: "Bruce Hahn has converted our data into MotionBuilder-friendly bvh, and 3dsMax-friendly bvh; they are hosted at cgspeed", with the caveat "we have NOT downloaded or tested these files ourselves" — [CMU Resources](http://mocap.cs.cmu.edu/resources.php)
- GitHub mirrors `una-dinosauria/cmu-mocap` (206 stars) and `Shriinivas/cmubvh` (62 stars) carry no LICENSE file (GitHub API `license: null`); they rely on READMEFIRST.txt. The mirror's own README says "AFAIK, yes" to "Can I use this data?" — [una-dinosauria/cmu-mocap](https://github.com/una-dinosauria/cmu-mocap); [Shriinivas/cmubvh](https://github.com/Shriinivas/cmubvh)

**Adobe Mixamo**
- Official FAQ (helpx, "Last updated on Sep 14, 2021"; read from the Wayback snapshot of 2026-11-24 because helpx returns "Access Denied" to curl): "You can use both characters and animations royalty free for personal, commercial, and non-profit projects including: Incorporate characters into illustrations and graphic art. 3D print characters. Create films. Create video games." — [Mixamo FAQ, Wayback 2026-11-24](http://web.archive.org/web/20261124211331/https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html); live page: https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html
- The official FAQ contains no sentence on redistribution of raw files. That rule appears only in the Adobe Community FAQ post below — [Mixamo FAQ, Wayback 2026-11-24](http://web.archive.org/web/20261124211331/https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html)
- Adobe Community FAQ post (author "TylerG 3D", 29 Sep 2022), verbatim: "Adobe retains the rights to our software and content, you retain the rights to your designs and creations and how the content is used." — [Adobe Community: Mixamo FAQ, licensing](https://community.adobe.com/t5/mixamo-discussions/mixamo-faq-licensing-royalties-ownership-eula-and-tos/td-p/13234775)
- Same post, "NO, you cannot create...": "Blueprints, templates, or asset packages for video game engines which redistribute character or animation raw files as the product"; "Packages for 3D stock or asset store websites where character or animation raw files will be sold or distrubuted"; "Any type of free distribution of character or animation raw files" — [Adobe Community: Mixamo FAQ, licensing](https://community.adobe.com/t5/mixamo-discussions/mixamo-faq-licensing-royalties-ownership-eula-and-tos/td-p/13234775)
- Same post: "really the only thing you can't do is distribute the raw character and animation files. ... If you download an asset for a team then all members of that project team may access and use the file. You may not distribute the files to customers or non-team members however." — [Adobe Community: Mixamo FAQ, licensing](https://community.adobe.com/t5/mixamo-discussions/mixamo-faq-licensing-royalties-ownership-eula-and-tos/td-p/13234775)
- Same post: "The only research application Mixamo content can't be used in is training machine-learning models." Attribution: "are not required to give credit to Adobe, Mixamo, or Fuse in any way." — [Adobe Community: Mixamo FAQ, licensing](https://community.adobe.com/t5/mixamo-discussions/mixamo-faq-licensing-royalties-ownership-eula-and-tos/td-p/13234775)
- A Community Expert replied on 8 Nov 2026: "Yes, no rules are changed till now". Two 2026 questions about shipping animation data inside an app (5 Nov) and about publishing derived joint coordinates (22 Aug) got no ruling from Adobe staff; the 5 Nov one was answered only with a link to the helpx FAQ — [Adobe Community: Mixamo FAQ, licensing](https://community.adobe.com/t5/mixamo-discussions/mixamo-faq-licensing-royalties-ownership-eula-and-tos/td-p/13234775)

**Rokoko (free mocap assets, Motion Library)**
- Marketing claim on the free pack: "A collection of 263 high-quality character animation assets that you can use in any animation, VFX, game, 3D project you want, including for commercial use." No licence text is on that page — [Rokoko free mocap assets](https://www.rokoko.com/mocap/free-mocap-assets)
- Rokoko Studio and Vision Standard Terms of Use, clause 5.1: Rokoko Assets "can be both sample data/assets produced and owned by us as well as Motion Library Assets owned by third parties. The license to each Rokoko Asset is limited to the period in which you have an Account." — [Rokoko Studio Terms of Use](https://www.rokoko.com/studio-term-of-use)
- Clause 5.3: "You may download and make copies of the Rokoko Assets for legitimate purposes, including back-up purposes, subject to the Terms. In addition, we acknowledge that copies of the Rokoko Assets may be made when the Rokoko Assets have been integrated as part of digital media productions. Unless expressly provided for in the license terms of the specific Rokoko Asset, you may not reproduce, distribute, sublicense, rent, lease or lend any Rokoko Asset other than as follows from the above." — [Rokoko Studio Terms of Use](https://www.rokoko.com/studio-term-of-use)
- Clause 5.4: "You may not use any assets obtained or provided under this agreement for the purpose of developing, training, or enhancing machine learning and/or AI models or algorithms, whether for commercial or non-commercial purposes, without the explicit written consent of the Company." — [Rokoko Studio Terms of Use](https://www.rokoko.com/studio-term-of-use)
- The website Terms of Service add: "You agree not to reproduce, duplicate, copy, sell, resell or exploit any portion of the Service ... without express written permission by us." — [Rokoko Terms of Service](https://www.rokoko.com/terms-of-service)

### Inferences
- Verdict table for "convert, commit to a public GitHub repo, ship in a possibly sold macOS app":

| Source | Public repo (converted) | Ship in sold app | Why |
|---|---|---|---|
| CMU ASF/AMC, or Hahne BVH | Yes | Yes | Explicit grant to copy, modify, redistribute and include in commercial products. The only limit is not reselling the data itself. |
| AIST++ annotations | Legally contested | No, without an AIST commercial agreement | Google's CC BY 4.0 label would allow both with attribution, but AIST's terms claim any "output developed or obtained through" the DB that ends up in a product. |
| AIST videos / music | No | No | "Unauthorized redistribution of any content of AIST Dance DB is prohibited." |
| Mixamo | No | Yes, if embedded and not offered as files | Raw-file distribution is banned, "free distribution" included. A public repo of converted clips is a free distribution of the animation data. |
| Rokoko free assets | No | Probably, as part of a "digital media production" | Clause 5.3 bans distribution outside an integrated production; the licence is also tied to holding an account. |

- A public repository is a redistribution of the CMU data, and it is free, so it does not "resell this data directly". A sold app that plays the clips is "include this data in commercially-sold products". The clause would bite only if the app's selling point were the mocap files themselves (for example an export feature that hands the clips back out).
- AIST++ carries a real conflict between two rights statements. The SMPL fits and 3D keypoints were computed by Google from AIST's videos; Google labels them CC BY 4.0, and CC BY permits commercial use and redistribution of adaptations. AIST's own terms were written to reach derived "results, models, systems, and technologies" used in a product. AIST++ motions are exactly such an output. The cautious reading is that the motion annotations alone can be redistributed in converted form for non-commercial or research use with attribution to both, but a sold app needs AIST's agreement first. I found no statement from AIST or Google that resolves this.
- The AIST commercial clause as quoted may be newer than the AIST++ release (2021); I did not check archived versions of the terms page. Whatever it said in 2021, the current wording is what applies to a 2026 product.
- For Mixamo, baking clips into the app's own binary format and shipping them inside the app bundle matches the "video games" permission, but the open-source repo is the problem: anyone could clone the converted data. Keeping Mixamo-derived data out of git (fetched or converted locally at build time by the developer) is the only arrangement consistent with the stated rule, and the app could then no longer be built from the public repo alone.
- CMU asks for an acknowledgement only "if you publish results", so attribution is a courtesy for an app. Adding the two-sentence credit to the app's acknowledgements costs nothing.

### Gaps
- I could not fetch the Mixamo "Additional Terms" PDF or the Adobe General Terms clauses that govern Mixamo content; the helpx site blocks automated fetches, and the community post only links to `adobe.com/legal/terms.html`. The redistribution rule above therefore rests on a 2022 community FAQ post by an Adobe-affiliated author plus a 2026 Community Expert confirmation, not on contract text.
- No licence file ships with the Rokoko free pack that I could inspect; the pack sits behind an email form. Whether the pack's own licence "expressly provides" more than clause 5.3 is unknown.
- No statement found from AIST on whether pose annotations derived from its videos count as "content of AIST Dance DB" for the redistribution ban.
- The CMU site does not define "resell this data directly". There is no formal licence document.

## 2. Download access: account or form needed, direct URLs, sizes (HEAD-checked 2026-11-25)

### Takeaway
CMU (official zips and the GitHub BVH mirror) and the AIST++ annotation zips download with no login. The official AIST++ `motions.zip` on GitHub is incomplete: it holds 411 of 1,408 sequences, and the old Google Storage URLs return 403. AIST videos and music need an application form; Mixamo needs an Adobe ID; Rokoko's free pack needs an email form.

### Cited Findings

**AIST++ annotations — no account, GitHub release assets**
- The release note (v1.0, published 2026-04-08) says: "As the original google storage links (`https://storage.cloud.google.com/aist_plusplus_public/...`) have expired, we now move the dataset release to Github assets." — [aistplusplus_dataset release v1.0](https://github.com/google/aistplusplus_dataset/releases/tag/v1.0)
- Checked URLs, all HTTP 200 with these byte sizes (from `Content-Length` and the GitHub releases API):

| File | Bytes | Website label | URL |
|---|---|---|---|
| motions.zip | 78,684,689 (75 MB) | "Motion Data Only (306MB)" | https://github.com/google/aistplusplus_dataset/releases/download/v1.0/motions.zip |
| keypoints3d.zip | 876,142,511 (836 MB) | "3D Keypoints Only (834MB)" | https://github.com/google/aistplusplus_dataset/releases/download/v1.0/keypoints3d.zip |
| keypoints2d.zip | 1,316,187,461 (1.23 GB) | "2D Keypoints Only (1.2GB)" | https://github.com/google/aistplusplus_dataset/releases/download/v1.0/keypoints2d.zip |
| cameras.zip | 27,294 | "Camera Data Only (19KB)" | https://github.com/google/aistplusplus_dataset/releases/download/v1.0/cameras.zip |
| splits.zip | 16,454 | — | https://github.com/google/aistplusplus_dataset/releases/download/v1.0/splits.zip |
| ignore_list.txt | 1,217 | — | https://github.com/google/aistplusplus_dataset/releases/download/v1.0/ignore_list.txt |

  — [GitHub releases API for google/aistplusplus_dataset](https://api.github.com/repos/google/aistplusplus_dataset/releases); labels from [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)
- Old Google Storage URLs return HTTP 403 (checked: `https://storage.googleapis.com/aist_plusplus_public/20210308/{fullset,motions,keypoints3d,splits,cameras}.zip` and `ignore_list.txt`) — [release note confirming expiry](https://github.com/google/aistplusplus_dataset/releases/tag/v1.0)
- `motions.zip` is incomplete. I downloaded it: 411 `.pkl` files, against 1,408 names in `splits/all.txt`. An open issue (1 Nov 2026) reports the same and gives the pattern: "all.txt (1,408) − crossmodal_train.txt (980) − ignore_list.txt (45) = 411". A commenter on 19 Nov 2026 says mail to `aistplusplus-external@google.com` bounced. No maintainer reply — [Issue #2, google/aistplusplus_dataset](https://github.com/google/aistplusplus_dataset/issues/2)
- `keypoints3d.zip` is complete: its central directory (read by range request) lists 1,408 `.pkl` files. `keypoints2d.zip` lists 1,510 (it also has the 100 `sMM` moving-camera sequences) — [keypoints3d.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/keypoints3d.zip); [keypoints2d.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/keypoints2d.zip)
- A complete copy of the motions exists in a third-party bundle: the issue reports that EDGE's `edge_aistpp.zip` "has all 1,408 motion .pkl files" and that they are "byte-identical to the 411 in the release where they overlap". The URL returns HTTP 200, filename `edge_aistpp.zip`, 3,791,378,057 bytes (3.5 GB). I did not download it. EDGE's README says its dataset script fetches "the AIST++ dataset (wavs and motion only)", so the bundle also holds AIST music, which is AIST DB content — [Issue #2](https://github.com/google/aistplusplus_dataset/issues/2); [Google Drive direct link](https://drive.usercontent.google.com/download?id=1RzqSbSnbMEwLUagV0GThfpm9JJXePGkV&export=download&confirm=t); [Stanford-TML/EDGE README](https://github.com/Stanford-TML/EDGE)

**AIST Dance Video DB (videos, music) — application form**
- "Please fill in the Application Form before using AIST Dance Video Database (AIST Dance DB)." — [AIST Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/)
- Google's `downloader.py` pulls the annotated subset of videos from AIST's servers: `wget https://raw.githubusercontent.com/google/aistplusplus_api/main/downloader.py`, then `python downloader.py --download_folder=$DOWNLOAD_FOLDER --num_processes=5` — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)

**CMU original — no account**
- "May I have a copy of the entire database? Sure! Please don't crawl this database for all motions. Here is a zipfile of all asf's and amc's." — [CMU FAQ](http://mocap.cs.cmu.edu/faqs.php)
- Checked, HTTP 200: `http://mocap.cs.cmu.edu/allasfamc.zip` (1,083,549,385 bytes, 1.0 GB); `http://mocap.cs.cmu.edu/allc3d_0.zip` (145,250,202 bytes); `http://mocap.cs.cmu.edu/allc3d_56789.zip` (1,039,158,054 bytes). Other C3D parts are named `allc3d_1a.zip`, `allc3d_1b.zip`, `allc3d_234.zip`; the C3D set sums "to over 4GB" — [CMU FAQ](http://mocap.cs.cmu.edu/faqs.php)
- Single files resolve at `http://mocap.cs.cmu.edu/subjects/<SS>/<SS>.asf` and `.../<SS>_<TT>.amc` (checked: `subjects/05/05.asf` 7,270 bytes; `subjects/05/05_02.amc` 893,895 bytes). The server's HTTPS certificate chain is incomplete; curl needs `-k` or plain HTTP — [mocap.cs.cmu.edu](http://mocap.cs.cmu.edu/)

**CMU BVH (Hahne conversion) — no account**
- cgspeed hosts 17 zips per release on MediaFire (2010 re-release and 2008 original), 32–94 MB each, grouped by subject range; for example "BVH directories 86-94 | 88 MB" at `http://www.mediafire.com/?r6y8sc60mabhneu` and "60-75 | 87 MB" at `http://www.mediafire.com/?5cgy081zdfyvtkf`. Both return HTTP 200 on an HTML landing page; MediaFire needs a browser click-through. The page notes MediaFire deleted all files once, in March 2011 — [cgspeed release page](https://sites.google.com/a/cgspeed.com/cgspeed/motion-capture/the-motionbuilder-friendly-bvh-conversion-release-of-cmus-motion-capture-database)
- GitHub mirror `una-dinosauria/cmu-mocap`: about 1.04 GB repo, branch `master`, last push 2024-02-29, 113 subject folders under `data/` named with three digits. Per-file raw URLs work without login, e.g. `https://raw.githubusercontent.com/una-dinosauria/cmu-mocap/master/data/093/93_03.bvh` (339,383 bytes, HTTP 200) and `.../data/060/60_01.bvh` (1,708,036 bytes). Whole-repo zip: `https://codeload.github.com/una-dinosauria/cmu-mocap/zip/refs/heads/master` (HTTP 200) — [una-dinosauria/cmu-mocap](https://github.com/una-dinosauria/cmu-mocap)
- Mirror `Shriinivas/cmubvh` (about 1.07 GB, branch `main`, last push 2023-11-06) keeps cgspeed's zip grouping as folders `Sequence-086-094` etc. `sfd158/cmu-mocap` and `meshula/cmu-mocap` are forks of `una-dinosauria` — [Shriinivas/cmubvh](https://github.com/Shriinivas/cmubvh)
- Both mirrors include the index files `cmu-mocap-index-text.txt` (68,400 bytes) and `cmu-mocap-index-spreadsheet.xls` — [una-dinosauria/cmu-mocap](https://github.com/una-dinosauria/cmu-mocap)

**Mixamo — Adobe ID required**
- "Mixamo is available free for anyone with an Adobe ID and does not require a subscription to Creative Cloud." It "is not available for Enterprise and Federated IDs" or for users with a China country code — [Mixamo FAQ, Wayback 2026-11-24](http://web.archive.org/web/20261124211331/https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html)

**Rokoko — email form (free pack) or account (Motion Library)**
- The free pack's "Download free assets" button opens a sign-up form asking for name, email, role, company size and main 3D tool; the confirmation says the link is sent by email (fetch-tool summary of the page) — [Rokoko free mocap assets](https://www.rokoko.com/mocap/free-mocap-assets)
- Motion Library assets are licensed "for as long as you have a valid Account with us" — [Rokoko Studio Terms of Use](https://www.rokoko.com/studio-term-of-use)

### Inferences
- Files to fetch for the CMU route, smallest footprint: individual BVH files by raw URL from `una-dinosauria/cmu-mocap` (subject folders 005, 049, 055, 060, 061, 085, 090, 093, 094, 103; folder sizes 3–105 MB), or the matching ASF + AMC pairs from `mocap.cs.cmu.edu/subjects/`. Folder `093` is 3.2 MB for 8 files.
- For AIST++ experiments today, `keypoints3d.zip` is the only complete official motion source. It gives joint positions (17 COCO points), not rotations; the app would need its own position-to-rotation solve, or the 411-sequence `motions.zip`, or the EDGE bundle.
- The 411 official motions are the crossmodal val and test sets plus non-train leftovers, and exclude every sequence on the ignore list, so they are already filtered for the known-bad fits.

### Gaps
- I did not test the AIST application form or whether AIST's video and music URLs are reachable without it.
- I did not download MediaFire zips or the 3.5 GB EDGE bundle, so their contents are reported second-hand.
- No Hugging Face mirror of the full AIST++ SMPL motions was confirmed. A dataset search for "aist" lists community uploads (for example `QuangNguyen22/aistpp`, `ckinpdx/aist_chunks`) that I did not open.

## 3. File formats, skeleton definition, frame rate, units, axes (per source)

### Takeaway
AIST++ is SMPL axis-angle pickles (24 joints, 60 fps, Y-up, world units that are not metres) plus 17-point COCO keypoints. CMU is ASF/AMC and C3D at 120 fps for most subjects (60 fps for the salsa subjects), 31 bones, Y-up, in inches × 0.45. The Hahne BVH files keep the same 31-joint skeleton with MotionBuilder names, add a T-pose as frame 0, and stamp every file as 120 fps, which is wrong for the 60 fps trials.

### Cited Findings

**AIST++**
- Motion files are SMPL-format `.pkl` with documented fields `smpl_poses` "(N, 24, 3)", `smpl_scaling` "A scalar value for each sequence", `smpl_trans` "(N, 3)" — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)
- Measured on all 411 files in the official `motions.zip`: keys are `smpl_loss` (float), `smpl_poses` float32 shape (N, 72), `smpl_scaling` float32 shape (1,), `smpl_trans` float32 shape (N, 3). The stored pose shape is (N, 72), not (N, 24, 3) as the page says; `smpl_loss` is undocumented — [motions.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/motions.zip)
- SMPL joint order (24): "root, lhip, rhip, belly, lknee, rknee, spine, lankle, rankle, chest, ltoes, rtoes, neck, linshoulder, rinshoulder, head, lshoulder, rshoulder, lelbow, relbow, lwrist, rwrist, lhand, rhand" — [aistplusplus_api README](https://github.com/google/aistplusplus_api/blob/main/README.md)
- COCO keypoint order (17): "nose, left_eye, right_eye, left_ear, right_ear, left_shoulder, right_shoulder, left_elbow, right_elbow, left_wrist, right_wrist, left_hip, right_hip, left_knee, right_knee, left_ankle, right_ankle" — [aistplusplus_api README](https://github.com/google/aistplusplus_api/blob/main/README.md)
- Frame rate: "Our annotations are frame-by-frame under exact 60 FPS. Some videos in the AIST Dance Video DB have slightly different FPS. In order to align frames across multi-view videos, we hard-coded 60 FPS when converting videos into images." — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)
- Shape is not per-dancer: "We fix β to the average shape as the problem is under-constrained from 3D joint locations alone." The API demo builds every body as `SMPL(..., gender='MALE')` and passes `transl=smpl_trans, scaling=smpl_scaling` — [AI Choreographer paper](https://arxiv.org/abs/2101.08779); [run_vis.py](https://github.com/google/aistplusplus_api/blob/main/demos/run_vis.py)
- Measured value ranges over the 411 files: `smpl_scaling` 78.5 to 99.1 (mean 88.4); `smpl_trans` x from −274 to +269, y from 108 to 207, z from −283 to +188 — [motions.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/motions.zip)
- Using the SMPL pose data needs no SMPL model file for a skeleton-only retarget, but the SMPL body model itself is a separate download under its own licence from https://smpl.is.tue.mpg.de/ ("SMPL_MALE.pkl", "SMPL_FEMALE.pkl" are expected by the API) — [aistplusplus_api README](https://github.com/google/aistplusplus_api/blob/main/README.md)

**CMU original (ASF/AMC, C3D)**
- Capture: "12 infrared MX-40 cameras, each of which is capable of recording at 120 Hz ... The capture subject wears 41 markers" in a volume "of approximately 3m x 8m" — [CMU FAQ](http://mocap.cs.cmu.edu/faqs.php)
- Units: "The bone length and the root position data for asf/amc files ... should be multiplied by this scale to convert to meters: (1.0/0.45)*2.54/100.0 = 0.056444" — [CMU FAQ](http://mocap.cs.cmu.edu/faqs.php)
- Format: "The asf/amc format is ascii and is reasonable to parse. Angles are in euler angles." — [CMU Info](http://mocap.cs.cmu.edu/info.php)
- ASF header read from `subjects/05/05.asf`: `:units mass 1.0, length 0.45, angle deg`; root `order TX TY TZ RX RY RZ`, `axis XYZ`; first bones `lhipjoint`, `lfemur` (dof rx ry rz, with limits), `ltibia` — [05.asf](http://mocap.cs.cmu.edu/subjects/05/05.asf)
- "Each subject, however, has its own calibrated skeleton." So bone lengths differ per subject — [mocap.cs.cmu.edu](http://mocap.cs.cmu.edu/)
- Frame rate is listed per trial on the site and is not stored in the AMC. Subjects 60 and 61 (salsa) are listed at 60; the other dance subjects at 120 — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)

**Hahne BVH conversion**
- Joint mapping, CMU name to BVH name: hip→Hips; lhipjoint→LHipJoint; lfemur→LeftUpLeg; ltibia→LeftLeg; lfoot→LeftFoot; ltoes→LeftToeBase; lowerback→LowerBack; upperback→Spine; thorax→Spine1; lowerneck→Neck; upperneck→Neck1; head→Head; lclavicle→LeftShoulder; lhumerus→LeftArm; lradius→LeftForeArm; lwrist→LeftHand; lhand→LeftFingerBase; lfingers→LFingers; lthumb→LThumb; and the mirrored right side — [READMEFIRST.txt](https://github.com/una-dinosauria/cmu-mocap/blob/master/READMEFIRST.txt)
- Read from `data/093/93_03.bvh`: 31 joints (`Hips, LHipJoint, LeftUpLeg, LeftLeg, LeftFoot, LeftToeBase, RHipJoint, RightUpLeg, RightLeg, RightFoot, RightToeBase, LowerBack, Spine, Spine1, Neck, Neck1, Head, LeftShoulder, LeftArm, LeftForeArm, LeftHand, LeftFingerBase, LeftHandIndex1, LThumb, RightShoulder, RightArm, RightForeArm, RightHand, RightFingerBase, RightHandIndex1, RThumb`) and 7 end sites. Root channels `Xposition Yposition Zposition Zrotation Yrotation Xrotation`; every joint `Zrotation Yrotation Xrotation`. `Frames: 443`, `Frame Time: .0083333`. The file uses `LeftHandIndex1`, where the README template says `LFingers` — [93_03.bvh](https://raw.githubusercontent.com/una-dinosauria/cmu-mocap/master/data/093/93_03.bvh)
- "Every BVH file has a T-pose added as its new first frame. The T-poses face the positive Z axis"; "With the exception of the new frame 1 (the T-pose), there are no modifications to the motion data itself." — [READMEFIRST.txt](https://github.com/una-dinosauria/cmu-mocap/blob/master/READMEFIRST.txt)
- Zero-length and unkeyed joints: "lhipjoint and rhipjoint are in the same location as hip, and have no keyframes. lowerback is in the same location as hip, and has keyframes. ... thorax, lowerneck, lclavicle, and rclavicle are all in the same location. thorax and lowerneck are keyed. lclavicle and rclavicle are not." — [READMEFIRST.txt](https://github.com/una-dinosauria/cmu-mocap/blob/master/READMEFIRST.txt)
- Frame time: "This BVH conversion release fixes the problem by rewriting Frame Time to .0083333 in each BVH file, which equates to 120fps." — [READMEFIRST.txt](https://github.com/una-dinosauria/cmu-mocap/blob/master/READMEFIRST.txt)
- Checked conflict: `data/060/60_01.bvh` says `Frames: 2243`, `Frame Time: .0083333`; the source `60_01.amc` has 2,242 frames, and CMU lists that trial at 60 fps — [60_01.bvh](https://raw.githubusercontent.com/una-dinosauria/cmu-mocap/master/data/060/60_01.bvh); [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)

**Mixamo**
- The official FAQ I could read does not list export formats, frame rates or the skeleton — [Mixamo FAQ, Wayback 2026-11-24](http://web.archive.org/web/20261124211331/https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html)

**Rokoko**
- The free-assets page does not state formats, skeleton or frame rate — [Rokoko free mocap assets](https://www.rokoko.com/mocap/free-mocap-assets)

### Inferences
- AIST++ is Y-up: across 411 files `smpl_trans` y stays between 108 and 207 while x and z span roughly ±280, and the first file's y holds within 168.7–172.7 for a 10.7 s dance.
- AIST++ world units are not metres and are not documented on the pages I read. The API scales the unit SMPL body by `smpl_scaling` (about 88) and adds `smpl_trans`, so dividing `smpl_trans` by `smpl_scaling` puts the root in SMPL-metre space. If the average-shape SMPL body is taken as true size, one world unit is about 1.1 cm. Treat "centimetres" as approximate. The floor height in world units is not given; the root y of about 170 is not a pelvis height in cm.
- CMU BVH offsets are in the ASF's units. In `93_03.bvh` the left thigh and shin offsets have lengths 7.76 and 7.64; times 0.056444 gives 0.44 m and 0.43 m, which is a plausible leg, so the 0.056444 factor applies to the BVH files too.
- The salsa BVH files (subjects 60, 61) play at double speed if the BVH frame time is trusted. Use 1/60 s for those: 2,242 frames is 37 s at 60 fps. Frame 0 of every BVH is the synthetic T-pose and should be dropped (or used as the rest pose).
- CMU is Y-up: the BVH hierarchy runs down the legs in −Y, and the T-pose faces +Z.
- From general knowledge, not verified today: Mixamo exports FBX (and Collada) on a "mixamorig:"-prefixed humanoid skeleton with fingers, at a chosen 24/30/60 fps; Rokoko's packs are FBX (and BVH) on a Mixamo-like humanoid. Confirm before relying on these.

### Gaps
- No authoritative statement of AIST++ world units or floor plane. `cameras.zip` (27 KB) would settle it: camera heights are documented as 180 cm (40 cm for C09) on AIST's site, so the camera translations give the unit.
- I did not open a `keypoints3d` pickle; field names and shape (N, 17, 3) come from the download page. Whether those arrays contain NaNs for missed detections is unchecked.
- CMU C3D marker files were not inspected.

## 4. Dance styles covered, clip counts and minutes; AIST++ naming, sBM vs sFM, BPM table; CMU dance subject and trial numbers

### Takeaway
AIST++ covers ten street and jazz genres (break, pop, lock, waack, two hip-hops, house, krump, street jazz, ballet jazz) in 1,408 sequences totalling 5.2 hours, with known tempo per clip. CMU has only a few minutes of usable social dance: charleston and lindy hop (subjects 93, 103), salsa (60, 61), modern/ballet (5, 49), and scattered novelty items (moonwalk, robot, macarena, the Twist, breakdance fragments). Neither has shuffle, rave, vogue, disco or slow R&B sway as such.

### Cited Findings

**AIST++ scale**
- "1,408 sequences of 3D human dance motion ... equally distributed among 10 dance genres with hundreds of choreographies. Motion durations vary from 7.4 sec. to 48.0 sec. All the dance motions have corresponding music." Also "10.1M images, covering 30 different subjects in 9 views" — [AIST++ Description page](https://google.github.io/aistplusplus_dataset/factsfigures.html)
- "in total 5.2-hour (1.1M frame, 1408 sequences) of 3D dance motion accompanied with music" — [AI Choreographer paper](https://arxiv.org/abs/2101.08779)
- Genre grouping: "Old School (Break, Pop, Lock and Waack)" and "New School (Middle Hip-hop, LA-style Hip-hop, House, Krump, Street Jazz and Ballet Jazz)" — [AI Choreographer paper](https://arxiv.org/abs/2101.08779)
- Per genre: "120 (85%) of them are basic choreographies and 21 (15%) of them are advanced"; "Advanced choreographies are longer and more complicated dances improvised by the dancers." Durations "7.4 - 12.0 basic / 29.5 - 48.0 adv." — [AI Choreographer paper](https://arxiv.org/abs/2101.08779)
- Counts in `splits/all.txt` (measured): 120 `sBM` + 21 `sFM` for each of the ten genres, except gPO has 20 `sFM` and gWA has 119 `sBM`; total 1,408 — [splits.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/splits.zip)

**Genre codes**

| Code | Genre | Code | Genre |
|---|---|---|---|
| gBR | Break | gWA | Waack |
| gPO | Pop | gKR | Krump |
| gLO | Lock | gJS | Street Jazz |
| gMH | Middle Hip-hop | gJB | Ballet Jazz |
| gLH | LA-style Hip-hop | gHO | House |

— [AIST Database Structure](https://aistdancedb.ongaaccel.jp/database_structure/)

**Naming convention**
- "gBR_sBM_cAll_d04_mBR0_ch01 in our annotations corresponds with gBR_sBM_{c01, ..., c09}_d04_mBR0_ch01 in the AIST database." — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)
- Fields: `g` genre, `s` situation, `c` camera (c01–c09 fixed, c10 moving; `cAll` in AIST++), `d` dancer (d01–d35), `m` music (genre code + index 0–5), `ch` choreography. Situation codes: sBM Basic Dance, sFM Advanced Dance, sMM Moving Camera, sGR Group Dance, sSH Showcase, sCY Cypher, sBT Battle. AIST's page gives the codes by example and tables; the letter meanings are the fetch tool's reading of them — [AIST Data Formats](https://aistdancedb.ongaaccel.jp/data_formats/)
- AIST++ motions include only `sBM` and `sFM` — [splits.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/splits.zip)
- Dancers: "35 professional dancers (20 male, 15 female)", at least 3 per genre (fetch-tool summary) — [AIST Database Structure](https://aistdancedb.ongaaccel.jp/database_structure/)

**Music tempo table**
- mBR0–5, mPO0–5, mLO0–5, mMH0–5, mLH0–5, mWA0–5, mKR0–5, mJS0–5, mJB0–5: 80, 90, 100, 110, 120, 130 BPM for index 0 to 5. House mHO0–5: 110, 115, 120, 125, 130, 135 BPM. 60 pieces in total — [AIST Database Structure](https://aistdancedb.ongaaccel.jp/database_structure/)
- Paper: "from 80 BPM to 130 BPM (except for House genre which is 110 BPM to 135 BPM)" — [AI Choreographer paper](https://arxiv.org/abs/2101.08779)

**Measured durations in the official 411-file motions.zip**
- `sBM`: 383 clips, 7.1–12.0 s, mean 9.3 s, 59.3 min in total. `sFM`: 28 clips, 28.4–48.0 s, mean 36.8 s, 17.2 min. Whole zip: 76.5 min — [motions.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/motions.zip)
- Mean `sBM` length by music index, non-house genres: 12.0, 10.7, 9.6, 8.7, 8.0, 7.4 s for index 0–5. House: 8.7, 8.3, 8.0, 7.7, 7.4, 7.1 s — [motions.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/motions.zip)
- Per genre in that zip: gBR 37 clips (7.0 min), gPO 43 (8.7), gLO 43 (8.2), gMH 43 (7.8), gLH 43 (7.5), gHO 42 (6.0), gWA 36 (8.2), gKR 41 (8.0), gJS 42 (7.7), gJB 41 (7.3). Each genre has 1–4 `sFM` clips — [motions.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/motions.zip)

**CMU dance trials** (descriptions verbatim from the site listing; fps as listed)
- Site scale: "There are 2605 trials in 6 categories and 23 subcategories"; dance sits under "Physical Activities & Sports" — [mocap.cs.cmu.edu](http://mocap.cs.cmu.edu/)
- Subject 93 "Charleston Dance" (120 fps): 93_01 "Motorcycle Pose"; 93_02 "rangeOfMotion"; 93_03 "charleston_01"; 93_04 "charleston_side_by_side_female"; 93_05 "charleston_side_by_side_male"; 93_06 "lindyHop2"; 93_07 "Casual Walk"; 93_08 "xtra fancY charleston" — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Subject 103 "Charelston Dancing" [sic] (120 fps): 103_01 (blank); 103_02 "rangeOfMotion_01"; 103_03 "charleston_01"; 103_04 "charleston_side_by_side_female"; 103_05 "charleston_side_by_side_male"; 103_06 "lindyHop2"; 103_07 "Casual Walk"; 103_08 "xtra fancY charleston" — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Subjects 60 and 61 "salsa" (60 fps): 60_01 to 60_15 and 61_01 to 61_15, each described only as "salsa dance" — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Subject 94 "indian dance" (120 fps): 94_01 to 94_16, all with blank descriptions — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Subject 5 "modern dance" (120 fps): 05_01 "walk"; 05_02 "dance - expressive arms, pirouette"; 05_03 "dance - sideways arabesque, turn step, folding arms"; 05_04 "dance - sideways arabesque, folding arms, bending back"; 05_05 "dance - quasi-cou-de-pied, raised leg above hip-height, jete en tourant"; 05_06 "dance - cartwheel-like start, pirouettes, jete"; 05_07 "dance - small jetes, attitude/arabesque, shifted-axis pirouette, turn"; 05_08 "dance - rond de jambe in the air, jete, turn"; 05_09 and 05_10 "dance - glissade devant, glissade derriere, attitude/arabesque"; 05_11 "dance - sideways steps, pirouette"; 05_12 "dance - arms held high, pointe tendue a terre, upper body rotation"; 05_13 "dance - small jetes, pirouette"; 05_14 and 05_15 "dance - retire derriere, attitude/arabesque"; 05_16 "dance - coupe dessous, jete en tourant"; 05_17 "dance - coupe dessous, grand jete en tourant"; 05_18 to 05_20 "dance - attitude/arabesque, jete en tourant, bending back" — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Subject 49 "modern dance, gymnastics" (120 fps), dance trials: 49_09 "dance - arms held high, side arabesque"; 49_10, 49_11, 49_13, 49_16 "dance - fold in from side arabesque, curl inwards"; 49_12, 49_14, 49_17 "dance - lean forward, bring back leg forward, arching arms"; 49_15 "static dance pose - folded in, head lowered, leg bent"; 49_22 "dance - lean back on bent leg, balance, bend elbow by ear" — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Subject 55 "animal behaviors (pantomime - human subject)" (120 fps): 55_01 "dance, whirl"; 55_02 "lambada dance"; 55_12 "dancing bear (human subject)"; 55_25 "dancing animal (human subject)"; 55_27 "dancing ant (human subject)" — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Subject 90 "cartwheels; acrobatics; dances" (120 fps): 90_28 "breakdance"; 90_30 and 90_31 "russian dance"; 90_32 "moonwalk" — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Subject 85 "jumps; flips; breakdance" (120 fps): 85_10 "EndofBreakDance"; 85_01 and 85_02 "JumpTwist"; 85_15 "90TwistsFall" — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Subject 15 "various everyday behaviors, dance moves" (120 fps): 15_04 and 15_05 "wash windows, paint; hand signals; dance - Egyptian walk, the Dive, the Twist, the Cabbage Patch; boxing"; 15_12 "wash windows; basketball - dribble, lay-up shot, pass; throw ball; dance - Egyptian walk, the Dive, the Twist; strew" — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)
- Singles (120 fps): 120_05 to 120_07 "Mickey Dance"; 120_21 "Robot"; 143_34 "Chicken Dance"; 143_35 "Macarena Dance"; 141_12 "Dance, Twist"; 111_05 and 113_04 "Dance"; two-person "chicken dance" in 18_15/19_15 and 20_01/21_01 — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)

**Mixamo and Rokoko**
- The official Mixamo FAQ gives no clip list or counts — [Mixamo FAQ, Wayback 2026-11-24](http://web.archive.org/web/20261124211331/https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html)
- Rokoko's free pack is "263 high-quality character animation assets"; the page names no packs and no dance content — [Rokoko free mocap assets](https://www.rokoko.com/mocap/free-mocap-assets)

### Inferences
- AIST++ basic clips are exactly 16 beats of their track and advanced clips 64 beats: 16 × 60 / 80 = 12.0 s, 16 × 60 / 130 = 7.4 s, 16 × 60 / 110 = 8.7 s (house index 0), and 64 × 60 / 80 = 48.0 s, 64 × 60 / 135 = 28.4 s. These match the measured lengths to 0.1 s. A basic clip is therefore a loopable four-bar phrase at a known BPM, which suits beat-clock playback: time-stretch by (clock BPM ÷ clip BPM).
- Mapping the wanted styles onto what exists:

| Wanted | AIST++ | CMU |
|---|---|---|
| Hip hop | gMH, gLH, gKR | none |
| Swing / charleston / lindy hop | none | 93_03–93_06, 93_08 (and 103 duplicates) |
| House / club | gHO | none |
| Disco | none (gWA and gLO are the nearest, both 1970s club styles) | 15_04/05 "the Twist" fragments only |
| Robot / popping / locking | gPO, gLO | 120_21 "Robot" |
| Shuffle | none (gHO footwork is nearest) | none |
| Vogue / waacking | gWA (waack only) | none |
| Rave | none | none |
| Slow R&B hip sway | none (gJS at 80 BPM is nearest) | none; 55_02 "lambada dance" is the closest hip-led clip |

- Subjects 93 and 103 have identical trial names and identical BVH folder sizes (3,152 KB each), so they look like the two partners of one session (or one capture filed twice). Compare the files before using both.
- CMU's usable solo social-dance material is small. `93_03.bvh` is 443 frames at 120 fps, 3.7 s. Folder 093 totals 3.2 MB of BVH for eight trials including a range-of-motion take, so charleston plus lindy hop is likely under a minute.
- Salsa (60, 61) is partner dancing captured as two subjects; a single dancer will show partner-hold arm positions.

### Gaps
- Mixamo's and Rokoko's dance inventories (styles, clip counts, minutes) could not be read from any page I could fetch; both catalogues sit behind logins or forms. From general knowledge Mixamo has many dance clips (hip hop, house, breakdance, swing, salsa, robot, shuffling, twist and others), but I did not verify names or counts today.
- Per-trial durations for CMU dance clips were not tabulated (it needs the AMC frame counts for each file).
- Minutes per genre for the full 1,408-sequence AIST++ set were not measured; only the 5.2-hour total is published.

## 5. BPM and beat annotations

### Takeaway
AIST++ has tempo by construction: the music ID in each sequence name gives the BPM, and clips are whole numbers of beats long. No per-beat timestamp files ship in the annotation zips. CMU, Mixamo and Rokoko have no music, BPM or beat data.

### Cited Findings
- AIST music tempos are fixed per music ID: 80, 90, 100, 110, 120, 130 BPM for index 0–5; house 110, 115, 120, 125, 130, 135 — [AIST Database Structure](https://aistdancedb.ongaaccel.jp/database_structure/)
- AIST lists dance lengths in beats: Basic Dance is 16 beats, Advanced, Group and Moving Camera 64 beats, Showcase 96 beats (fetch-tool summary; it also relays second figures, "about 23 s" and "about 52 s", that do not match the 9.3 s and 36.8 s means measured in AIST++) — [AIST Database Structure](https://aistdancedb.ongaaccel.jp/database_structure/)
- The AIST++ annotation folders are `motions/`, `keypoints2d/`, `keypoints3d/`, `splits/`, `cameras/` and `ignore_list.txt`; none is a beat file — [aistplusplus_api README](https://github.com/google/aistplusplus_api/blob/main/README.md)
- AIST's data-formats page lists tempo values for music but no beat annotation files (fetch-tool summary) — [AIST Data Formats](https://aistdancedb.ongaaccel.jp/data_formats/)
- CMU trial metadata is a subject description, a trial description and a frame rate; nothing on music or tempo — [CMU all-motions listing](http://mocap.cs.cmu.edu/search.php?subjectnumber=%25&motion=%25)

### Inferences
- For AIST++, beat k of a basic clip falls at k × 60 / BPM seconds from clip start if the clip starts on a beat. The measured lengths (exactly 16 or 64 beats) support that, but I did not verify the phase against the audio. Check one clip against its video before trusting beat 0 = frame 0.
- CMU charleston, lindy and salsa were danced to music that is not provided, so their tempo must be estimated from the motion (for example foot-contact or vertical-root periodicity) and beat-marked by hand.

### Gaps
- Whether AIST publishes beat-time annotations for its 60 tracks elsewhere on its site was not confirmed.
- No tempo information exists for any CMU dance trial.

## 6. Data quality caveats

### Takeaway
AIST++ motion is a kinematic SMPL fit to triangulated 2D detections, not optical mocap: one average body shape, no fingers, no contact reasoning, and 45 sequences flagged bad. CMU is real Vicon optical mocap but early, with noisy hands and toes, fake finger joints, no captured T-pose and awkward zero-length joints.

### Cited Findings

**AIST++**
- Pipeline: "The construction pipeline starts with frame-by-frame 2D keypoint detection and manual camera estimation. Then triangulation and bundle adjustment are applied to optimize the camera parameters as well as the 3D keypoints. Finally we sequentially fit the SMPL model to 3D keypoints to get a motion sequence represented using joint angles and a root trajectory." — [aistplusplus_api README](https://github.com/google/aistplusplus_api/blob/main/README.md)
- "our approach is kinematic based and we do not reason about physical interactions between the dancer and the floor." (said of the paper's method) — [AI Choreographer paper](https://arxiv.org/abs/2101.08779)
- Accuracy is reported as 2D reprojection only: "The MPJPE-2D of our entire dataset is 6.2 pixels on the 1920×1080 image resolution"; "The PCKh@0.5 on the whole set is 98.7%" (the appendix says 98.4%) — [AI Choreographer paper](https://arxiv.org/abs/2101.08779)
- Filter list: "We manually checked our annotations and conducted numerical analysis. A filter list is provided that contains those sequences with poorly reconstructed 3D keypoints and human motion annotations (ignore_list.txt). We recommend excluding those annotations in your research or study." — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)
- `ignore_list.txt` has 45 names: 8 gBR, 14 gJB, 5 gJS, 2 gKR, 1 gHO, 15 gWA. None of the 45 is in the official `motions.zip` — [ignore_list.txt](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/ignore_list.txt)
- Each motion file stores a per-sequence fit residual `smpl_loss` (1.11 in `gJS_sBM_cAll_d01_mJS1_ch02`) — [motions.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/motions.zip)
- AIST's disclaimer on its labels: "Classification of videos and musical pieces, such as dance genres and situations, is provided for the purpose of helping people use this database." — [AIST Terms of Use](https://aistdancedb.ongaaccel.jp/terms_of_use/)

**CMU**
- "When browsing for motions, start with the higher numbered subjects first. The lower numbers contain some of our earliest motion capture sessions, and may not be as high quality." — [mocap.cs.cmu.edu](http://mocap.cs.cmu.edu/)
- "The "toe" and "hand" joints in our motions tend to be noisy, and may require some smoothing. The "finger" and "thumb" joints are added to the skeleton for editing convenience - we do not actually capture these joints' motions and any such data should be ignored." — [mocap.cs.cmu.edu](http://mocap.cs.cmu.edu/)
- "In this database, the same person may appear under more than one subject number." — [mocap.cs.cmu.edu](http://mocap.cs.cmu.edu/)
- No real rest pose: "The original CMU BVH files don't provide T poses, which means it's impossible to determine or recover the exact physical rotation of the human actor's joints ... The best that we can do is make a guess at a T pose." The 2010 T-pose sets upper arms to ±8° and upper legs to ±21° in Z, and tilts neck and head — [READMEFIRST.txt](https://github.com/una-dinosauria/cmu-mocap/blob/master/READMEFIRST.txt)
- "If the original CMU data is noisy, the conversion will be noisy. If the original CMU data has the actor's head moving at an impossible angle, the conversion will do the same." — [READMEFIRST.txt](https://github.com/una-dinosauria/cmu-mocap/blob/master/READMEFIRST.txt)
- Shoulders: "The CMU dataset's skeleton is somewhat annoying around the shoulders because it doesn't use a clavicle joint, only a shoulder joint. Also, the rotation points of the CMU skeleton shoulders are significantly wider than the hips." — [READMEFIRST.txt](https://github.com/una-dinosauria/cmu-mocap/blob/master/READMEFIRST.txt)
- CMU's own caveat on third-party conversions: "we have NOT downloaded or tested these files ourselves." — [CMU Resources](http://mocap.cs.cmu.edu/resources.php)

### Inferences
- Expect jitter, foot sliding and ground penetration in AIST++: joints are triangulated per frame from 2D detectors and the fit has no contact model. The SMPL body has no finger joints (`lhand`, `rhand` are single joints), and 17 COCO keypoints carry no hand, toe or spine detail, so wrist, toe and spine twist rotations in the fit are weakly constrained. For a low-poly figure this matters less than for a realistic one, but foot locking or smoothing will be needed.
- Break dance (gBR) and ballet jazz (gJB) and waack (gWA) account for 37 of the 45 ignored sequences, so floor work, extreme extensions and fast arm whirls are where the reconstruction fails most.
- For CMU via BVH, retarget from the motion frames using the hierarchy offsets as the rest pose, not from Hahne's frame-0 T-pose, whose angles were tuned by eye for MotionBuilder.

### Gaps
- No 3D accuracy figure against ground-truth mocap exists for AIST++ in the sources read.
- I did not view any AIST++ or CMU dance clip, so the jitter and foot-slide remarks are expectations from the method, not observations.
- Mixamo and Rokoko clip quality was not assessed.

## 7. AIST++ annotation download: exact contents

### Takeaway
The annotations are five folders of pickles and text plus `ignore_list.txt`. Motions are SMPL axis-angle (N × 72 float32) with a root trajectory (N × 3) and one scale; keypoints are 17 COCO points. Everything is at exactly 60 fps, Y-up. The complete folder set is only obtainable today by fetching the release assets one by one, and `motions/` is short by 997 sequences.

### Cited Findings
- Expected layout: `motions/`, `keypoints2d/`, `keypoints3d/`, `splits/`, `cameras/`, `ignore_list.txt` — [aistplusplus_api README](https://github.com/google/aistplusplus_api/blob/main/README.md)
- The release has no single full-set zip; "Complete Dataset -- All Above + Dataset Splits (2.3GB)" on the website now links to the release page — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html); [release v1.0](https://github.com/google/aistplusplus_dataset/releases/tag/v1.0)
- `motions/<seq>.pkl` (measured): pickle protocol 4, a dict with `smpl_loss` (Python float), `smpl_poses` (numpy float32, shape (N, 72): 24 joints × 3 axis-angle values, joint 0 is the root orientation), `smpl_scaling` (float32, shape (1,)), `smpl_trans` (float32, shape (N, 3)). Example `gJS_sBM_cAll_d01_mJS1_ch02.pkl`: N = 640 (10.7 s), scaling 88.47, first translation (0.36, 170.86, −10.97), file size 192,300 bytes. The pickles reference `numpy.core.multiarray._reconstruct` — [motions.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/motions.zip)
- Documented motion fields: "smpl_poses: Sequences of SMPL pose parameters. Array shape is (N, 24, 3). smpl_scaling: Human body scaling factor. A scalar value for each sequence. smpl_trans: Motion 3D trajectory. Array shape is (N, 3)." — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)
- `keypoints3d/<seq>.pkl`: "keypoints3d: Sequences of 3D keypoints reconstructed frame-by-frame. Array shape is (N, 17, 3). keypoints3d_optim: Sequences of 3D keypoints reconstructed with temporal smoothness and constrains." 1,408 files, 360–590 KB each for basic clips — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html); [keypoints3d.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/keypoints3d.zip)
- `keypoints2d/<seq>.pkl`: "keypoints2d: Multi-view frame-by-frame 2D keypoints detection results. Array shape is (9, N, 17, 3). The last dimension is (x, y, confidence)." 1,510 files — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)
- `cameras/`: "Individual environment settings, each with 9 cameras in the environment. (setting_<suffix>.json)" and "Mapping from environment settings to sequence names. (mapping.txt)". Per camera: `name`, `size` ("[1920, 1080]"), `matrix` (3×3 intrinsics), `rotation` (Rodrigues vector), `translation`, `distortions` — [AIST++ Download page](https://google.github.io/aistplusplus_dataset/download.html)
- `splits/` (measured): `all.txt` 1,408 names; `crossmodal_train.txt` 980; `crossmodal_val.txt` 20; `crossmodal_test.txt` 20; `pose_train.txt` 868; `pose_val.txt` 70; `pose_test.txt` 470. Names are in the `cAll` form — [splits.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/splits.zip)
- `ignore_list.txt`: 45 sequence names, one per line, with blank separator lines — [ignore_list.txt](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/ignore_list.txt)
- Zips carry macOS `__MACOSX/._*` resource-fork entries alongside each real file (motions.zip has 824 entries for 411 pickles) — [motions.zip](https://github.com/google/aistplusplus_dataset/releases/download/v1.0/motions.zip)
- Loader reference: `AISTDataset.load_motion` returns `smpl_poses, smpl_scaling, smpl_trans`; `load_keypoint3d(..., use_optim=False)` returns `keypoints3d_optim` when `use_optim` is set; frames load at `fps=60` — [loader.py](https://github.com/google/aistplusplus_api/blob/main/aist_plusplus/loader.py)

### Inferences
- Reading these files in Swift or a build script does not need Python's pickle machinery to be trusted: each array is a raw little-endian float32 buffer inside a simple protocol-4 pickle, and a restricted unpickler that allows only `numpy.core.multiarray._reconstruct`, `numpy.ndarray` and `numpy.dtype` read all 411 files. Do not `pickle.load` third-party copies (for example the EDGE bundle) without such a restriction.
- A converted runtime format would be small: 640 frames × 75 floats × 4 bytes = 192 KB per 10.7 s clip at 60 fps before any downsampling or quantising. Thirty clips at 30 fps would be under 3 MB.
- `keypoints3d_optim` is the smoother of the two keypoint arrays and is the one to use if positions rather than SMPL rotations drive the figure.

### Gaps
- Units and origin of `keypoints3d` and `smpl_trans` are not stated in the documentation read; see section 3.
- The `cameras/` JSON and a `keypoints3d` pickle were not opened.
- Whether Google will restore the full `motions.zip` is unknown; the issue has had no maintainer response since 1 Nov 2026.
