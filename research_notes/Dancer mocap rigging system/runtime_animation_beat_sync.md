# Runtime animation techniques for beat-synced mocap dance playback

Reading guide: "Cited Findings" are things I read in the source (or, where marked "search summary", saw only in a search-result summary and did not open). "Inferences" are my own engineering derivations and rules of thumb; they are not published results. "Gaps" lists what I could not source, including things I believe from memory but did not verify.

## 1. Beat extraction from motion (kinematic beats), clip BPM and first-beat offset, AIST++ facts

### Takeaway
For AIST++ you do not need to estimate tempo: the BPM is encoded in the music id in every file name (80–130 BPM in steps of 10; House 110–135 in steps of 5), and the motion is 60 fps. Only the beat phase (first-beat offset) has to be estimated, and the standard literature definition for that is "local minima of smoothed mean joint speed".

### Cited Findings
- AI Choreographer defines kinematic beats as "the local minima of the kinetic velocity" and music beats as librosa's beat output. — [Li et al. 2021, arXiv 2101.08779](https://arxiv.org/abs/2101.08779)
- Beat Alignment Score: `BeatAlign = (1/m) * sum_i exp( - min_j |t_i^x - t_j^y|^2 / (2 sigma^2) )`, where `t^x` are kinematic beats, `t^y` are music beats, times in frames, and "We set sigma = 3 in all our experiments as the FPS of all our experiments sequences is 60" (so sigma = 50 ms). The metric is deliberately one-directional: "dance motion does not necessarily have to match with every music beat", but every kinematic beat should have a music beat. — [Li et al. 2021](https://arxiv.org/abs/2101.08779)
- Bailando's implementation (which EDGE says it follows): speed is the mean over joints of per-frame joint displacement, `kinetic_vel = np.mean(np.sqrt(np.sum((keypoints[1:] - keypoints[:-1]) ** 2, axis=2)), axis=1)`; smoothed with a Gaussian of sigma 5 frames, `kinetic_vel = G(kinetic_vel, 5)`; beats are `argrelextrema(kinetic_vel, np.less)`. The score is flipped relative to Li et al.: summed per music beat against the nearest motion beat, `ba += np.exp(-np.min((motion_beats[0] - bb)**2) / 2 / 9)`, divided by the number of music beats (variance 9, i.e. sigma 3 frames). — [Bailando beat_align_score.py](https://github.com/lisiyao21/Bailando/blob/main/utils/beat_align_score.py)
- EDGE gives no formula of its own; it follows Bailando "for the precise implementation of this metric", and notes Li et al. compute the distance per kinematic beat while Bailando computes it per music beat. EDGE works at 30 fps (downsampled AIST++, 5-second training clips). — [Tseng et al. 2023, arXiv 2211.10658](https://arxiv.org/html/2211.10658v2)
- AIST++ sequences are 60 fps: the paper states the FPS of all its experiment sequences is 60 and that it generates "at 60 FPS". — [Li et al. 2021](https://arxiv.org/abs/2101.08779)
- AIST++ size: 5.2 hours, about 1.1M frames, 1,408 sequences, 10 genres, 60 pieces of music (6 per genre), music 29–54 s long; motion durations 7.4–48.0 s. — [Li et al. 2021](https://arxiv.org/abs/2101.08779); [AIST++ facts page](https://google.github.io/aistplusplus_dataset/factsfigures.html)
- Tempos per music id (`m` + genre code + digit 0–5): Break, Pop, Lock, Middle Hip-hop, LA Hip-hop, Waack, Krump, Street Jazz, Ballet Jazz are 80, 90, 100, 110, 120, 130 BPM for digits 0–5; House (`mHO0`–`mHO5`) is 110, 115, 120, 125, 130, 135 BPM. File names look like `gBR_sBA_c01_d03_mBR3_ch04` (genre, situation, camera, dancer, music, choreography). — [AIST Dance DB data formats](https://aistdancedb.ongaaccel.jp/data_formats/)
- 85% of each genre is "basic" choreography and 15% "advanced" (longer, improvised). For basic choreography, "dancers are asked to perform the same choreography on all the 6 pieces of music with different speed to follow different music BPMs". — [Li et al. 2021](https://arxiv.org/abs/2101.08779)
- Motion format: 24 SMPL joint rotations plus global translation and scale; SMPL was fitted per frame to triangulated 3D keypoints with shape fixed to the average, because the problem is under-constrained from joints alone. — [Li et al. 2021](https://arxiv.org/abs/2101.08779)
- Bailando reads music-beat flags per frame and truncates them to the dance length starting at index 0 (`[:length]`), i.e. its pipeline treats motion frame 0 and music frame 0 as the same instant. — [Bailando beat_align_score.py](https://github.com/lisiyao21/Bailando/blob/main/utils/beat_align_score.py)

### Inferences
- Beat period in 60 fps frames is `3600 / BPM`: 80 → 45, 90 → 40, 100 → 36, 110 → 32.7, 120 → 30, 130 → 27.7, 135 → 26.7 frames. Take BPM from the file name and treat it as exact (the AIST music is produced at fixed tempo).
- Practical phase estimate with known period `P` (frames): compute Bailando's smoothed speed envelope `s[n]`, then pick the offset `phi in [0, P)` that minimises the comb sum `sum_k s[round(phi + k P)]` (interpolate `s` since `P` is fractional). This is a one-dimensional search and is far more robust than picking individual minima. A circular-mean alternative: `phi = P/(2 pi) * arg( sum_n -s[n] * exp(2 pi i n / P) )`. Repeat with period `2P` to decide which beats are downbeat-like (weaker evidence; expect to hand-correct).
- The Gaussian sigma of 5 frames at 60 fps (83 ms) is tuned for 60 fps; halve it for 30 fps data.
- If BPM were unknown: autocorrelate the mean-removed speed envelope (or vertical pelvis position) over lags corresponding to 60–180 BPM and take the peak; resolve the octave by preferring the candidate nearest ~100–120 BPM. Tempo-octave errors (half/double) are the dominant failure mode, exactly as in audio beat tracking, because many moves accent every second beat.
- Speed minima mark "hits/stops", which sit on the beat for popping/locking styles; for bouncy styles (house, hip-hop grooves) the pelvis vertical minimum is often the on-beat event. Estimating phase from both envelopes and checking they agree is a cheap confidence test.
- Because the same basic choreography exists at six tempos, the library can pick the recording nearest the live tempo and only needs a few percent of time-scaling (see section 2).

### Gaps
- I did not find an explicit statement in the AIST++ paper or site that motion frame 0 coincides with audio sample 0. The Bailando code assumes it, and the motion is derived from the videos that carry the audio, but confirm by checking one clip's kinematic beats against librosa beats of its music.
- Where the first music beat falls within each AIST track (intro length) is not documented in what I read; run a beat tracker once on each of the 60 tracks to get the offset.
- "Dancing to Music" (Lee et al. 2019) and Shiratori et al. 2006 were not retrieved. From memory, unverified: Lee et al. detect kinematic beats from abrupt changes in motion direction/magnitude, and Shiratori et al. use stop-motion keyposes (local minima of hand/foot/centre-of-mass speed).
- librosa's beat_track documentation page returned 404. From memory, unverified: it follows Ellis 2007 (onset envelope → tempo from autocorrelation with a prior centred on `start_bpm=120` → dynamic programming with `tightness=100`).
- No published accuracy figures for motion-only tempo estimation were found.

## 2. Playing a clip at a different tempo; half/double time; a live clock that jumps

### Takeaway
Drive clip time from beat phase, not from wall time: clip position (in beats) follows the live beat counter, so tempo changes become playback-rate changes automatically. No source I found publishes a numeric "safe" speed range; the engine and game evidence only confirms that rate-scaling to match a leader is the standard mechanism.

### Cited Findings
- Fortnite's "Beat Synced" emote tag (added November 2024) makes the emote animation match the tempo of the Jam Track being played: faster for fast songs, slower for slow ones. The coverage does not describe the mechanism. — [Dexerto](https://dexerto.com/fortnite/what-does-beat-synced-mean-in-fortnite-feature-explained-2972177) (search summary; no Epic developer source found)
- Unreal sync groups: followers scale their play rate so their cycle matches the leader's length; with sync markers, playback is matched marker to marker, and only markers present in every animation of the group are used. Stated caveats: large length differences make animations play noticeably faster, and can cause visible play-rate pops when the leader changes. — [Unreal Engine: Animation Sync Groups](https://dev.epicgames.com/documentation/en-us/unreal-engine/animation-sync-groups-in-unreal-engine)
- AIST dancers themselves performed the same basic choreography at 80–130 BPM (House 110–135), so real dance covers that tempo span with the same movement vocabulary, but as re-performances rather than time-stretches. — [Li et al. 2021](https://arxiv.org/abs/2101.08779)

### Inferences
- Beat-locked playback. Store per clip `bpmClip` and `t0` (time of beat 0). With a live clock giving continuous beat position `B(t)`, play clip time `tau = t0 + (B - B_start + k) * 60 / bpmClip`. The instantaneous rate is `liveBPM / bpmClip`. This is uniform scaling per beat interval; it is equivalent to a piecewise-linear beat-grid warp when clip beats are evenly spaced, which they are for AIST (fixed-tempo music).
- Beat-grid warp for clips whose beats are uneven (hand-labelled or detected beats `c_k`): map live beat `k + f` to `tau = c_k + f * (c_{k+1} - c_k)`. Piecewise-linear has a rate step at each beat; use a monotone cubic (Fritsch–Carlson/PCHIP) through `(k, c_k)` if the steps are visible. For fixed-tempo AIST clips this is unnecessary.
- Octave folding. Let `r = liveBPM / bpmClip`. Choose `m in {1/2, 1, 2}` minimising `|log2(r * m)|` and play at rate `r * m`, treating the clip as half- or double-time. With folding alone the worst-case rate is within `[0.71, 1.41]`.
- With six recordings per choreography at 10 BPM spacing, picking the nearest tempo keeps the rate within about ±6% for live tempos 80–130 BPM (±5 BPM at 80). Live tempos 131–180 map to clips at 65–90 via half-time, though only 80–90 exist, so 140–160 BPM needs up to about +15% (130 BPM clip at 150) or −12% (half-time 80 BPM clip at 140).
- Rule of thumb (mine, not published): time-scaling is hard to notice within roughly ±10%, usually acceptable to ±20–25%, and reads as slow motion or fast-forward beyond that, mainly because airborne and falling phases have a gravity-determined duration. Slowing down is less forgiving than speeding up for jumps.
- Clock jumps. Keep a separate playback beat position `Bp` that chases the clock's `B`: each frame `err = wrap(B - Bp)` to `[-0.5, 0.5)` beats (or `[-2, 2)` if bar phase matters), then `Bp += liveRate * dt + correction`, where the correction is a critically damped spring on `err` (half-life 0.1–0.25 s) and the total rate is clamped to, say, `[0.5, 1.5] x` nominal and never negative. Small phase corrections become brief speed changes rather than pose pops. For an error larger than about a quarter beat, prefer re-anchoring `k` to the nearest beat (a discrete beat slip) plus an inertialized transition (section 4) over a long slew.
- Sample the clock on the render thread once per frame and extrapolate `B` by `bpm * dt / 60`; do not pose from a clock value that is updated at audio-block rate without extrapolation, or the motion will stutter at 120 fps.

### Gaps
- No developer write-up was found for Just Dance, Dance Central, Fortnite, VRChat/MMD or Beat Saber avatar tempo handling. From general knowledge, unverified: Just Dance and Dance Central author choreography to a fixed song, so they play back against the song timeline and have no tempo-change problem; MMD dance motions are likewise authored per song.
- No published perceptual threshold for acceptable dance time-scaling was found; the ±10/±25% figures above are practitioner judgement.

## 3. Looping and sequencing; motion graphs; is motion matching overkill

### Takeaway
For beat-synced dance, restrict cuts to bar or phrase boundaries and choose among a small precomputed table of compatible (clip, bar) pairs; full motion matching solves a different problem (responsive locomotion) and is unnecessary here.

### Cited Findings
- Holden's looping method: measure the position and velocity difference between the last and first frame per joint (rotations as scaled-angle-axis differences, angular velocities by differentiating quaternions), split it between the two ends with a ratio, and add an offset at each end that decays to zero; a spring decay never reaches exactly zero so he replaces it with a cubic that reaches zero value and zero slope at a fixed blend time. Spreading a linear correction over the whole clip removes the gap but "can cause drift and foot sliding" on long clips. Root motion should be looped in character space, inertializing only the velocity difference. No default half-lives or blend times are given. — [Holden, Creating Looping Animations from Motion Capture](https://theorangeduck.com/page/creating-looping-animations-motion-capture)
- Unreal's guidance for synced animations: they should have the same general body movement from start to end, such as the same feet planted on the first and last frames. — [Unreal Engine: Animation Sync Groups](https://dev.epicgames.com/documentation/en-us/unreal-engine/animation-sync-groups-in-unreal-engine)
- AIST "basic" clips are short repeated basic movements; "advanced" clips are longer improvised dances. — [Li et al. 2021](https://arxiv.org/abs/2101.08779)

### Inferences
- Bake-time transition table. For every clip, list its bar starts `b_i` (every 4 beats from `t0`). For each ordered pair of bar starts (within a clip for loops, across clips for sequencing) compute a pose distance in the character's root frame (root yaw and horizontal position removed): `D = sum_j w_j |p_j^A - p_j^B|^2 + lambda * sum_j w_j |v_j^A - v_j^B|^2`, with joint positions `p`, velocities `v` in beat-normalised units (per beat, not per second, so clips at different BPM compare fairly), larger weights on pelvis, feet and hands. Keep the best few targets per source bar. This is the motion-graph idea restricted to bar boundaries, which shrinks the search from frames² to bars².
- Also require matching support foot (contact flags from section 6 equal at the cut) and reject pairs where the root height differs a lot (floor work to standing).
- Loop choice: the best `(b_i, b_j)` with `j - i` a multiple of 2 or 4 bars so phrases stay intact; basic AIST choreographies repeat the same move, so good loops of 2–4 bars are likely.
- Sequencing at runtime: at each bar (or on a trigger), pick the next (clip, bar) from the table with randomisation and a no-recent-repeat rule; then transition with inertialization (section 4) at the boundary. Root yaw and position must be re-based so the new clip continues from the current root transform.
- Motion matching searches a feature database every few frames for the best continuation of a desired trajectory. Dance has no trajectory goal and the timing is fixed by the beat, so the per-frame search buys nothing; the bar-level table gives the same benefit at negligible cost.

### Gaps
- Kovar, Gleicher & Pighin 2002 (Motion Graphs), Clavet GDC 2016 and Holden's Learned Motion Matching were not retrieved; no formulas above are quoted from them. From memory, unverified: Motion Graphs compares point clouds over a window of frames after an optimal 2D rigid alignment and takes local minima of the distance matrix below a threshold as transition points.

## 4. Transitions: crossfade vs inertialization vs dead blending

### Takeaway
Use offset-based inertialization: at the cut, record the difference (and its velocity) between what was shown and the new clip, and decay that offset to zero on top of the new clip. Only one clip is evaluated after the cut. Holden cites about 0.2 s as a normal blend time.

### Cited Findings
- Bollo's GDC 2018 talk presents inertialization as a post-process replacing blended transitions in Gears of War 4, covering vector and quaternion values; the slides are on GDC Vault and were not readable here. — [GDC Vault](https://www.gdcvault.com/play/1025331/Inertialization-High-Performance-Animation-Transitions)
- Quintic form as described by a secondary write-up: `offset(t) = a t^5 + b t^4 + c t^3 + (a0/2) t^2 + v0 t + x0`, ending with zero value, velocity and acceleration; `a0` is "the smallest starting acceleration that never crosses zero"; if the offset is moving away from zero the velocity is dropped, and if it is approaching too fast the blend is shortened. For rotations, `x0` is an angle about a fixed axis. — [AnimForge Systems](https://animforgesystems.com/blog/inertialization-and-dead-blending.html) (secondary source of unknown authority)
- Holden's spring inertializer. Transition: `off_x = (src_x + off_x) - dst_x; off_v = (src_v + off_v) - dst_v`. Update each frame: decay the offset, then `out_x = in_x + off_x; out_v = in_v + off_v`. — [Holden, Spring-It-On](https://theorangeduck.com/page/spring-roll-call)
- The decay is an exact critically damped spring to zero: `y = halflife_to_damping(halflife) / 2; j1 = v + x*y; eydt = fast_negexp(y*dt); x = eydt*(x + j1*dt); v = eydt*(v - j1*y*dt)`, with `halflife_to_damping(h) = (4 * 0.69314718056) / (h + eps)` and `fast_negexp(x) = 1 / (1 + x + 0.48 x^2 + 0.235 x^3)`. — [Holden, Spring-It-On](https://theorangeduck.com/page/spring-roll-call)
- The exact (closed-form) spring is stable for any `dt` or stiffness, unlike `lerp(x, target, damping*dt)` (unstable when `damping*dt > 1`) or semi-implicit Euler springs. A spring has no fixed blend time and can overshoot, but decays to a negligible value quickly. — [Holden, Spring-It-On](https://theorangeduck.com/page/spring-roll-call)
- Dead blending: on transition store the current pose and velocity (`ext_x = src_x; ext_v = src_v; ext_t = 0`); each frame decay the velocity (`ext_v = damper_decay_exact(ext_v, decay_halflife, dt)`), integrate (`ext_x += ext_v * dt`), and crossfade from the extrapolated pose to the new clip with `alpha = smoothstep(ext_t / blendtime)`. Rotations extrapolate by `quat_mul(quat_from_scaled_angle_axis(dt * angular_velocity), rotation)`. It needs only the current pose and velocity (finite differences are fine), and the result always lies between the extrapolated source and the destination, which should reduce overshoot artefacts such as knee pops; downsides are damped destination detail and possible foot sliding. — [Holden, Dead Blending](https://theorangeduck.com/page/dead-blending)
- "About 0.2 seconds" is described as a normal blend time; 1 s as unrealistically long. No decay half-life value is given. — [Holden, Dead Blending](https://theorangeduck.com/page/dead-blending)
- For a decay that must hit exactly zero, Holden uses a cubic over a fixed blend time whose constant term is `x`, linear term `v * blendtime`, with the remaining terms set so value and slope are zero at the end. — [Holden, Creating Looping Animations](https://theorangeduck.com/page/creating-looping-animations-motion-capture)

### Inferences
- Quintic coefficients (not read from Bollo's slides; I derived them from the boundary conditions `x(t1) = x'(t1) = x''(t1) = 0` and verified them numerically):
  - `x(t) = A t^5 + B t^4 + C t^3 + (a0/2) t^2 + v0 t + x0`, for `0 <= t <= t1`, zero afterwards
  - `A = -(a0 t1^2 + 6 v0 t1 + 12 x0) / (2 t1^5)`
  - `B =  (3 a0 t1^2 + 16 v0 t1 + 30 x0) / (2 t1^4)`
  - `C = -(3 a0 t1^2 + 12 v0 t1 + 20 x0) / (2 t1^3)`
  - with `x0 >= 0` (magnitude), `v0 = min(v0, 0)`, `a0 = max(0, (-8 v0 t1 - 20 x0) / t1^2)` (the unclamped value makes the jerk zero at `t1`, checked numerically), and overshoot guard `t1 = min(t1, -5 x0 / v0)` when `v0 < 0`. A search result mentions the same `-5*x0/v0` clamp in another implementation, which is consistent, but I did not read that source.
- Cubic alternative (zero value and slope at `T`): `x(t) = x0 + v0 t + c2 t^2 + c3 t^3` with `c2 = -(3 x0 + 2 v0 T) / T^2`, `c3 = (2 x0 + v0 T) / T^3`.
- Applying to a rig. Positions (root, and any translated joints): per-component offsets, or Bollo-style magnitude along the fixed direction of `x0`. Rotations: `q_off = q_src * inverse(q_dst)` (make `w >= 0`), convert to scaled-angle-axis vector `r = axis * angle`; decay `r` with the spring per component (Holden) or decay `|r|` with the quintic along the fixed axis; output `q_out = quat_from_scaled_angle_axis(r) * q_dst`. Offset angular velocity is `omega_src - omega_dst`, with `omega` from finite differences of the last two shown poses, `omega = to_scaled_angle_axis(q_now * inverse(q_prev)) / dt`.
- Under time warping, source and destination velocities must be in real seconds: multiply clip-space velocities by the current playback rate.
- Durations for dance (rule of thumb): 0.2–0.3 s, or better, a fixed fraction of a beat (half a beat: 0.25 s at 120 BPM) started on the bar line so the blend finishes before the next beat. For the spring form, a half-life of 0.05–0.1 s gives a visually complete blend in roughly 0.25–0.5 s. Longer blends smear the hit on beat 1.
- Crossfade needs two clips evaluated during the blend and averages poses (damped accents, sliding feet). For one CPU-posed character the cost is irrelevant, so the reason to prefer inertialization is quality and simplicity: the new clip plays at full strength from the cut, and repeated or interrupted transitions compose by adding to the stored offset.
- Foot locks (section 6) should be released or re-evaluated at a cut; inertialize first, then apply IK.

### Gaps
- Bollo's exact slide formulas and his recommended durations were not retrieved (GDC Vault content could not be read). The coefficients above are a derivation consistent with the published description, not a quotation.
- No published guidance specific to dance blend durations was found.

## 5. Smoothing noisy video-derived mocap; resampling for playback

### Takeaway
Filter once at bake time with a zero-phase low-pass on joint positions/rotations, but set the cutoff higher than the gait-analysis default: 6 Hz is the biomechanics convention for walking, and dance accents are sharper.

### Cited Findings
- AIST++ SMPL parameters are fitted per frame to triangulated multi-view 2D keypoints, with no temporal term described in the fitting objective and shape fixed to the average. — [Li et al. 2021](https://arxiv.org/abs/2101.08779)
- EDGE reports that AIST++ ground truth is not free of foot motion during contact (ground-truth PFC 1.332, where 0 would be perfectly static support), and notes foot sliding is "not only common but integral to many choreographies". — [Tseng et al. 2023](https://arxiv.org/html/2211.10658v2)
- Biomechanics convention: a zero-lag Butterworth low-pass at 6 Hz on marker trajectories; Winter's original was second-order, later work commonly cites fourth-order as "standard"; Winter reported 99% of heel/toe marker signal power below 7 Hz in gait; the 6 Hz rule is criticised as outdated for modern capture, and higher-order filters at 10–12 Hz have been proposed for some uses. — [technical note on marker filtering](https://www.bohrium.com/paper-details/marker-displacement-data-filtering-in-gait-analysis-a-technical-note/812004737929969664-4008); [MDPI Applied Sciences 15(4):2177](https://mdpi.com/2076-3417/15/4/2177) (both via search summary; not read in full)
- One Euro filter tuning procedure: set beta to 0 and min-cutoff to about 1 Hz; with slow movement lower min-cutoff until jitter is gone; with fast movement raise beta (start around 0.001–0.0001, change by factors of 10) until lag is acceptable. Lower min-cutoff reduces jitter and increases lag. — [Casiez, 1€ Filter](https://gery.casiez.net/1euro/)

### Inferences
- The One Euro filter is a causal, speed-adaptive filter for live input; for offline baking a zero-phase filter (forward-backward Butterworth, or Savitzky–Golay) is strictly better because it introduces no lag, which matters when beats must stay aligned.
- Starting parameters to tune by eye at 60 fps (mine): fourth-order zero-phase Butterworth (second-order run forward and backward) at 8–10 Hz for limbs and 4–6 Hz for root translation; or Savitzky–Golay with window 9–11 frames, polynomial order 3. Check that speed minima (kinematic beats) do not shift and that hits are not softened.
- Filter rotations either as joint positions before re-fitting, or in a continuous rotation representation: fix quaternion sign continuity (`dot(q_n, q_{n-1}) >= 0`), filter the four components, renormalise; or filter scaled-angle-axis deltas relative to a running mean. Never filter Euler or raw axis-angle channels across wraparound.
- Estimate phase (section 1) on the smoothed data, and detect foot contacts (section 6) after smoothing.
- Resampling at arbitrary clip time: for 30–60 fps data, normalised lerp (nlerp) between neighbouring quaternions with sign fix is visually indistinguishable from slerp because adjacent keys are a few degrees apart; use Catmull-Rom/Hermite on root position if you need continuous velocity (useful for inertialization velocities and spring bones). Squad is not worth it at these sample rates.
- When the playback rate is below 1 and the display is 120 fps, linear interpolation of 30 fps keys gives piecewise-constant velocity; if this shows as slight stepping in secondary motion, store 60 fps or use cubic interpolation for positions.

### Gaps
- I found no measurement of AIST++ jitter magnitude or a recommended filter for it specifically.
- The Butterworth sources were seen only as search summaries; the One Euro formulas (`alpha = 1 / (1 + tau/Te)`, `tau = 1/(2 pi fc)`, `fc = mincutoff + beta * |dx|`) are from memory because the page shows the algorithm as an image.

## 6. Foot contact detection, locking, IK, and what time warping does to contacts

### Takeaway
Detect contacts offline, store them as per-frame flags per foot, and at runtime lock the foot to its contact position with two-bone IK, blending the lock in and out by inertialization. For dance, be conservative: intentional slides and pivots are part of the choreography, and Holden's own advice is that a little sliding looks better than a broken pose.

### Cited Findings
- Kovar, Schreiner & Gleicher 2002: a footplant constraint requires the heel or the ball (or both) to stay planted over a set of frames; toes are handled separately and only kept from penetrating. The pipeline is: choose a constraint position per plant; compute ankle positions and orientations that satisfy it; move the root (position only) by the smallest amount that makes the ankle targets reachable, balanced against root smoothness; adjust each leg analytically; cover any residual by stretching the leg (changing thigh and shin length smoothly); then blend the adjustments off into unconstrained frames so nothing pops when a constraint switches on or off. It works over a neighbourhood of frames, so online use needs a delay of about ½–1 second. Projecting the root differently for one-foot and two-foot cases can make it pop, which is why root changes are smoothed. — [Kovar et al., Footskate Cleanup for Motion Capture Editing](https://research.cs.wisc.edu/graphics/Gallery/kovar.vol/Cleanup/cleanup.pdf)
- Holden's runtime foot lock (`contact_update`): on contact start, lock at the toe's current position projected to the ground at `foot_height` and inertialize toward it with zero velocity; while locked, feed the inertializer the fixed point; unlock when contact ends or when the locked point is farther than `unlock_radius` from the animation's toe position, inertializing back to the animation. Then compute the heel target, solve two-joint IK, stop ground penetration, and bend the toe on contact. He gives no numeric thresholds, calls the method over-simplified for a full game, says foot locking is hard to make look good, and that a little sliding often looks less wrong than a badly broken pose. — [Holden, Code vs Data Driven Displacement](https://theorangeduck.com/page/code-vs-data-driven-displacement)
- EDGE trains with a contact consistency loss that penalises foot velocity on frames the model itself labels as contact, `L_contact = 1/(N-1) * sum_i || (FK(x^{i+1}) - FK(x^i)) * b^i ||^2`, and its plausibility metric multiplies centre-of-mass acceleration by both feet's speeds, precisely so that deliberate sliding is not penalised when the body is not accelerating. — [Tseng et al. 2023](https://arxiv.org/html/2211.10658v2)

### Inferences
- Detection thresholds to start from (mine, widely used in research code but not sourced here): a foot joint (heel/ankle and toe separately) is in contact when its speed is below 0.15–0.3 m/s and its height is within 3–5 cm of its own resting height above the floor; add hysteresis (enter below the low threshold, leave above the high one), drop contacts shorter than about 4 frames at 60 fps, and merge gaps shorter than 2–3 frames. Compute speed in the original clip's real-time units, before any warping.
- Floor height per clip: a low percentile (around the 2nd) of toe/heel heights, since SMPL fits float or sink by a few centimetres.
- Time warping scales velocities but not positions, so contact intervals stay valid when stored as flags on clip frames; only velocity thresholds are affected, which is why detection belongs at bake time.
- Retargeting to different proportions changes where feet land; lock positions must therefore be taken from the retargeted character's own foot position at lock time (as Holden does), not from stored world positions in the source clip.
- Runtime lock with one character: per foot keep `locked`, `lockPos`, and an inertialized offset. Lock at the posed toe/heel position when the baked flag turns on; unlock on flag off or when the animation drifts more than about 10–20 cm (also unlock on every clip transition); solve two-bone IK for hip-knee-ankle with the knee pole taken from the animated pose; clamp reach to about 0.99 of leg length instead of stretching, or lower the pelvis slightly when the target is out of reach.
- Heel and toe: lock whichever is flagged (heel strike pivots about the heel, toe-off about the ball), and when both are flagged lock the whole foot orientation as well.
- A cheaper first step that removes most visible skate: fix it at bake time in clip space (Kovar-style offline cleanup against the detected contacts), then run no runtime lock at all unless transitions or retargeting reintroduce sliding.
- Pivots and slides in dance will be flagged as non-contact by the velocity test, which is the desired behaviour.

### Gaps
- No published numeric thresholds were retrieved for contact detection; the values above are conventions from memory.
- Kovar's specific neighbourhood sizes and blend function were not extracted in detail beyond the structure above.

## 7. Secondary motion (spring/jiggle bones) under variable dt

### Takeaway
Use closed-form (exact) damped springs parameterised by half-life and frequency; they are unconditionally stable for any `dt`, unlike Euler-integrated springs.

### Cited Findings
- `lerp(x, target, damping*dt)` is frame-rate dependent and unstable when `damping*dt > 1`; a semi-implicit Euler spring becomes unstable for large `dt` or stiff settings; the exact exponential damper `x = lerp(x, target, 1 - exp(-ln2 * dt / halflife))` and the closed-form spring are stable for any `dt` and handle over-, critically- and under-damped cases with separate branches. — [Holden, Spring-It-On](https://theorangeduck.com/page/spring-roll-call)
- Critically damped exact spring toward goal `g` with goal velocity `q`: `d = halflife_to_damping(h); c = g + (d*q)/((d*d)/4); y = d/2; j0 = x - c; j1 = v + j0*y; eydt = fast_negexp(y*dt); x = eydt*(j0 + j1*dt) + c; v = eydt*(v - j1*y*dt)`. — [Holden, Spring-It-On](https://theorangeduck.com/page/spring-roll-call)

### Inferences
- Jiggle bone recipe: each secondary bone tip is a point mass tracking its animated target position with an under-damped exact spring (frequency 2–6 Hz, damping ratio 0.2–0.6 for bouncy parts such as ears and belly, higher for hair), then the bone is rotated to aim at the simulated tip and its length restored. Because the target moves, feed the target velocity as `q`.
- Clamp `dt` (for example to 1/30 s) and reset the spring state to the target on teleports, clip jumps without inertialization, and scene switches; history starts uninitialised otherwise.
- Springs see real time, not clip time: when the clip is played faster, targets move faster and the jiggle increases naturally. That is physically correct and needs no compensation.
- Run springs after inertialization and foot IK so they react to the final pose.
- Limit excursion (cone angle or maximum displacement) so a beat-clock jump cannot fling a bone.

### Gaps
- No source was retrieved on production jiggle-bone systems (Unreal AnimDynamics, VRM spring bones, Unity Dynamic Bone); parameters above are starting points to tune by eye.

## 8. Compact clip storage

### Takeaway
At this scale (about 20 joints, up to 60 s) compression libraries are unnecessary: uniform 30 fps keys with 48-bit quaternions come to roughly 0.25 MB per minute, and even raw 60 fps floats are about 1.2 MB per minute.

### Cited Findings
- ACL stores quaternions with W dropped and reconstructed from the unit norm, uses uniform sampling with fixed per-sample cost and no entropy coding (constant-time random access), range reduction per clip and per segment, and variable bit rates per track drawn from 0, 3–16 and 23 bits per component; constant rotation tracks use 16 bits per component. Dropping W loses accuracy when W is small; dropping the largest component with a 2-bit index ("smallest three") is more accurate. — [Frechette, Advanced Quantization](https://nfrechette.github.io/2017/03/12/anim_compression_advanced_quantization) and related posts on [nfrechette.github.io](https://nfrechette.github.io/2020/08/11/clip_metadata_packing) (via search summary)
- ozz-animation uses 48 bits per quaternion: 15 bits for each of three stored components, 2 bits for the index of the dropped component and 1 sign bit. — cited in [arXiv 2610.22052](https://arxiv.org/pdf/2610.22052) (via search summary)
- Raw representation: a rotation is 4 floats as a quaternion (3 with W dropped), translation 3 floats. — [Frechette, Animation Data](https://nfrechette.github.io/2016/10/27/anim_compression_data/)
- EDGE and its baselines evaluate dance at 30 fps, downsampled from AIST++'s 60 fps. — [Tseng et al. 2023](https://arxiv.org/html/2211.10658v2)

### Inferences
- Sizes for 20 joints, 60 s (arithmetic): at 30 fps there are 1,800 frames and 36,000 rotation samples. Smallest-three at 48 bits: 216 KB. Raw float32 quaternions: 576 KB. Root translation as 3 float32: 21.6 KB (or 10.8 KB as 3 x 16-bit with a per-clip range). Contact flags: 1 byte per frame, 1.8 KB. At 60 fps double everything: about 0.43 MB packed, 1.2 MB raw.
- Smallest-three precision: components lie in `[-1/sqrt2, 1/sqrt2]`; 15 bits gives a step of about 4.3e-5, an angular error on the order of 0.005 degrees, far below the noise in video-derived mocap. Even 10 bits per component (32-bit quaternion) is likely sufficient.
- Suggested simple format: header (joint count, frame count, sample rate, `bpm`, `t0` of beat 0, beats per bar, floor height); per-clip root translation range; then frame-major arrays: root position 3 x u16, 20 quaternions x 48 bits, 1 contact byte (bit per heel/toe). Frame-major layout keeps one frame contiguous for sampling; decode two neighbouring frames and nlerp.
- 30 fps vs 60 fps: 30 fps halves size and is the convention in the dance-generation literature, but sharp hits (popping, locking) lose some snap and velocities become piecewise constant. Since the data is tiny either way, keeping 60 fps is the lower-risk choice; smooth first (section 5), then decimate if desired.
- Bone lengths are constant, so only the root needs translation; store the skeleton's rest offsets once per rig, not per clip.

### Gaps
- ACL's typical achieved bit rates and compression ratios were not retrieved; the Frechette and ozz details were seen only in search summaries.
- No source was found recommending a specific storage sample rate for dance.
