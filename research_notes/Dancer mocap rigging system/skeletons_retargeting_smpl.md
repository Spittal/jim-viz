# Humanoid skeleton conventions, motion retargeting, and SMPL joints without the SMPL body model

Reading note: every item under "Cited Findings" was read from the linked page during this research. Anything recalled from memory and not re-verified is under "Gaps" and marked UNVERIFIED. Derived numbers and design advice are under "Inferences".

## 1. Bone sets and hierarchies of the common conventions

### Takeaway
SMPL (24 joints), VRM (15 required bones) and COCO-17 were confirmed from primary sources and are listed in full below. The Mixamo and CMU/cgspeed lists could not be confirmed from a primary source in this pass; they are given under Gaps as unverified recall.

### Cited Findings

**SMPL, 24 joints (index: official name / AIST++ and EDGE name / parent index)**

Official names are `SMPL_JOINT_NAMES` in the smplx repo — [smplx joint_names.py](https://raw.githubusercontent.com/vchoutas/smplx/main/smplx/joint_names.py). The alternative names and the parent array are `smpl_joints` and `smpl_parents` in EDGE — [EDGE vis.py](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/vis.py). The AIST++ README uses the same alternative names ("root, lhip, rhip, belly, lknee, rknee, spine, lankle, rankle, chest, ltoes, rtoes, neck, linshoulder, rinshoulder, ...") — [AIST++ API README](https://raw.githubusercontent.com/google/aistplusplus_api/main/README.md).

| idx | official (smplx) | AIST++/EDGE | parent |
|---|---|---|---|
| 0 | pelvis | root | -1 |
| 1 | left_hip | lhip | 0 |
| 2 | right_hip | rhip | 0 |
| 3 | spine1 | belly | 0 |
| 4 | left_knee | lknee | 1 |
| 5 | right_knee | rknee | 2 |
| 6 | spine2 | spine | 3 |
| 7 | left_ankle | lankle | 4 |
| 8 | right_ankle | rankle | 5 |
| 9 | spine3 | chest | 6 |
| 10 | left_foot (ball of foot) | ltoes | 7 |
| 11 | right_foot | rtoes | 8 |
| 12 | neck | neck | 9 |
| 13 | left_collar | linshoulder | 9 |
| 14 | right_collar | rinshoulder | 9 |
| 15 | head | head | 12 |
| 16 | left_shoulder | lshoulder | 13 |
| 17 | right_shoulder | rshoulder | 14 |
| 18 | left_elbow | lelbow | 16 |
| 19 | right_elbow | relbow | 17 |
| 20 | left_wrist | lwrist | 18 |
| 21 | right_wrist | rwrist | 19 |
| 22 | left_hand | lhand | 20 |
| 23 | right_hand | rhand | 21 |

Parent array, flat: `[-1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 12, 13, 14, 16, 17, 18, 19, 20, 21]` — [EDGE vis.py](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/vis.py)

- Spine is three joints above the pelvis (spine1=3, spine2=6, spine3=9); neck (12) and both collars (13, 14) all hang off spine3; the "hand" joints 22/23 are single children of the wrists — [smplx joint_names.py](https://raw.githubusercontent.com/vchoutas/smplx/main/smplx/joint_names.py), [EDGE vis.py](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/vis.py)
- The HumanML3D 22-joint skeleton is the same tree without the two hand joints. Its chains are `[0,2,5,8,11]` (right leg), `[0,1,4,7,10]` (left leg), `[0,3,6,9,12,15]` (spine to head), `[9,14,17,19,21]` (right arm), `[9,13,16,18,20]` (left arm) — [HumanML3D paramUtil.py](https://raw.githubusercontent.com/EricGuo5513/HumanML3D/main/paramUtil.py)

**SMPL-H and SMPL-X differences**

- SMPL-H keeps body joints 0–21 identical, drops `left_hand`/`right_hand`, and adds 30 finger joints (per hand: index1-3, middle1-3, pinky1-3, ring1-3, thumb1-3; left hand at 22–36, right at 37–51), giving 52 — [smplx joint_names.py](https://raw.githubusercontent.com/vchoutas/smplx/main/smplx/joint_names.py)
- SMPL-X keeps body joints 0–21, then inserts `jaw`, `left_eye_smplhf`, `right_eye_smplhf` at 22–24, then the same 30 finger joints at 25–54, giving 55. Both lists then append landmark joints (nose, eyes, ears, big toe, small toe, heel, fingertips) — [smplx joint_names.py](https://raw.githubusercontent.com/vchoutas/smplx/main/smplx/joint_names.py)
- HumanML3D's finger chains for the 52-joint layout: left `[20,22,23,24] [20,34,35,36] [20,25,26,27] [20,31,32,33] [20,28,29,30]`, right `[21,43,44,45] [21,46,47,48] [21,40,41,42] [21,37,38,39] [21,49,50,51]` — [HumanML3D paramUtil.py](https://raw.githubusercontent.com/EricGuo5513/HumanML3D/main/paramUtil.py)

**VRM 1.0 humanoid**

- Required (15): hips; spine (parent hips); head; left/right UpperLeg (parent hips), LowerLeg, Foot; left/right UpperArm, LowerArm, Hand — [VRMC_vrm-1.0 humanoid.md](https://raw.githubusercontent.com/vrm-c/vrm-specification/master/specification/VRMC_vrm-1.0/humanoid.md)
- Optional: chest (parent spine), upperChest (parent chest), neck (parent upperChest), left/right Shoulder (parent upperChest), left/right Eye, jaw, left/right Toes (parent foot), and 30 finger bones — [VRMC_vrm-1.0 humanoid.md](https://raw.githubusercontent.com/vrm-c/vrm-specification/master/specification/VRMC_vrm-1.0/humanoid.md)
- When an optional bone is absent, the child attaches to the next bone up (head to upperChest if no neck; upper arm to upperChest if no shoulder). Non-humanoid nodes may sit between humanoid bones — [VRMC_vrm-1.0 humanoid.md](https://raw.githubusercontent.com/vrm-c/vrm-specification/master/specification/VRMC_vrm-1.0/humanoid.md)

**Unity Humanoid**

- The Avatar mapping marks bones required (solid circles) or optional (dotted); Unity interpolates the motion of unmapped optional bones — [Unity manual, Avatar Mapping](https://docs.unity.com/en-us/engine/current/manual/animation-section/animation-mecanim/avatar-creationand-setup/class-avatar)
- "The more optional bones you map, the higher the quality of the retargeting" — [Unity Learn, Configuring Humanoid Rigs](https://learn.unity.com/tutorial/2-9-configuring-humanoid-rigs.md?language=en)
- `HumanTrait.RequiredBoneCount`, `RequiredBone` and `MuscleFromBone` expose the required set and the bone-to-muscle mapping — [Unity HumanTrait](https://docs.unity3d.com/ScriptReference/HumanTrait.html)

**COCO-17 keypoint order (as used by AIST++)**

`0 nose, 1 left_eye, 2 right_eye, 3 left_ear, 4 right_ear, 5 left_shoulder, 6 right_shoulder, 7 left_elbow, 8 right_elbow, 9 left_wrist, 10 right_wrist, 11 left_hip, 12 right_hip, 13 left_knee, 14 right_knee, 15 left_ankle, 16 right_ankle` — [AIST++ API README](https://raw.githubusercontent.com/google/aistplusplus_api/main/README.md)

**Mixamo-style naming (partial)**

- A Ready Player Me template shows Hips under an Armature, then Spine, Spine1, Spine2, Neck, with the arm chain LeftShoulder, LeftArm, LeftForeArm, LeftHand; Mixamo's own names carry the `mixamorig:` prefix — [Ready Player Me templates](https://docs.readyplayer.me/asset-creation-guide/asset-creation/templates), [Adobe community thread](https://community.adobe.com/t5/mixamo-discussions/problem-with-uploading-already-rigged-characters/td-p/12915518) (both reached through search summaries only, not read in full)

### Inferences
- All the conventions agree on the same core: pelvis, 2–3 spine bones, neck, head, clavicle, upper arm, forearm, hand, thigh, shin, foot, toe. They differ in spine count (VRM/Unity 1–3, SMPL 3, Mixamo 3) and in whether clavicle, neck and toes are mandatory.
- For SMPL-sourced data, the natural rig joints for this project are the 22 body joints. Joints 22/23 carry almost no information in AIST++-style body-only fits and can drive a fixed hand tip.
- SMPL's "left_foot" is the ball of the foot, which matches Mixamo "LeftToeBase" and Unity/VRM "LeftToes". SMPL's "left_collar" corresponds to Mixamo "LeftShoulder" (clavicle), and SMPL "left_shoulder" to Mixamo "LeftArm".

### Gaps
- **Mixamo full list (UNVERIFIED, from memory).** No primary source for the 65-joint list was found. Recalled hierarchy: Hips → Spine → Spine1 → Spine2 → Neck → Head → HeadTop_End; Spine2 → Left/RightShoulder → Arm → ForeArm → Hand → Hand{Thumb,Index,Middle,Ring,Pinky}1-4; Hips → Left/RightUpLeg → Leg → Foot → ToeBase → Toe_End. That counts to 65 (6 spine/head + 1 head end + 2×4 arm + 2×20 fingers + 2×5 leg). Confirm by opening a Mixamo FBX.
- **CMU / cgspeed BVH list (UNVERIFIED, from memory).** Searches returned nothing usable. Recalled 31-joint hierarchy: Hips → {LHipJoint → LeftUpLeg → LeftLeg → LeftFoot → LeftToeBase; RHipJoint → ...; LowerBack → Spine → Spine1 → {Neck → Neck1 → Head; LeftShoulder → LeftArm → LeftForeArm → LeftHand → {LeftFingerBase → LeftHandIndex1; LThumb}; RightShoulder → ...}}. Confirm from a cgspeed BVH header.
- **Unity required bones and muscle space (UNVERIFIED).** The manual page fetched did not list them. Recalled: 15 required bones, the same set as VRM (VRM's set was modelled on Unity's), and muscle values normalised to −1..1 across each joint's configured range. Check `HumanTrait.RequiredBoneCount` and the "Muscle & Settings" manual page.
- Parent indices for SMPL-H/SMPL-X finger joints were not fetched as an array; the HumanML3D chains above give them implicitly for SMPL-H.

## 2. Minimum bone set that preserves the look of real dance

### Takeaway
No perceptual study or expert statement on the minimum bone set for dance was found. The evidence is indirect: every standard treats 15 bones as the floor, tools say extra bones improve retargeting, and foot-contact practice depends on a separate toe joint.

### Cited Findings
- VRM's required set is 15 bones with a single spine bone; chest, upperChest, neck, shoulders (clavicles) and toes are all optional — [VRMC_vrm-1.0 humanoid.md](https://raw.githubusercontent.com/vrm-c/vrm-specification/master/specification/VRMC_vrm-1.0/humanoid.md)
- Unity states mapping more optional bones raises retargeting quality, and it interpolates unmapped optional bones — [Unity Learn](https://learn.unity.com/tutorial/2-9-configuring-humanoid-rigs.md?language=en), [Unity manual](https://docs.unity.com/en-us/engine/current/manual/animation-section/animation-mecanim/avatar-creationand-setup/class-avatar)
- Holden: lock the toe joint, not the heel, because toe-only contact with pivoting about the toe is very common while heel-only contact is rare; his leg solve orients the heel toward the toe target and the toe toward a toe-end target to keep the pose's heel/toe relationship — [theorangeduck, Inverse Kinematics and Foot Locking](https://theorangeduck.com/page/inverse-kinematics-foot-locking)
- EDGE (a dance-generation model trained on AIST++) uses SMPL joints 7, 8, 10, 11 (both ankles and both toe joints) as its foot-contact joints — [EDGE vis.py](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/vis.py)
- Unreal's floor constraint has separate "Use Foot" and "Use Toes" settings with heel and toe offsets defining a foot plane — [UE 5.8 Retargeting Operation Stack](https://dev.epicgames.com/documentation/en-us/unreal-engine/retargeting-operation-stack-in-unreal-engine-5-8)
- Unreal's FK chain "Interpolated" mode matches rotations by normalised position along a chain and is described as usually best when bone counts differ, which is the stock answer for mapping a 3-joint source spine onto fewer or more target spine bones — [UE 5.8 Retargeting Operation Stack](https://dev.epicgames.com/documentation/en-us/unreal-engine/retargeting-operation-stack-in-unreal-engine-5-8)
- In SMPL rest offsets the spine3→neck segment is about 0.21 m and collar→shoulder about 0.13 m, so the neck and clavicle are long segments, not small corrections (lengths computed from the offsets in section 4) — [EDGE vis.py](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/vis.py)

### Inferences
- With rigid, unskinned segments, every joint the source has and the rig lacks becomes either a lost rotation or a visible kink. The current rig (pelvis, chest, head, upper arm, forearm+hand, thigh, shin, foot) folds three spine rotations into one pelvis/chest break, drops the collar, and has no ball-of-foot joint.
- Suggested priority for additions, by how much dance motion each carries in SMPL data:
  1. **Toe (ball of foot).** Needed for relevés, pivots and heel lifts, and it is the joint contacts are detected and locked on. Without it a rigid foot either sinks its toe or floats its heel.
  2. **Spine split into at least two segments (abdomen + chest), ideally three matching spine1/2/3.** Body rolls, isolations and counter-rotation of hips against shoulders are spread over these joints. With rigid segments, more spine pieces also hide the gap that opens at a single pelvis/chest hinge.
  3. **Clavicles.** Shoulder shrugs and raised arms move the shoulder joint by a large fraction of the ~0.13 m collar length; without it, overhead arms look pinned.
  4. **Neck separate from head.** SMPL's neck segment is long; head isolations use both joints.
  5. **Separate hand.** Wrist rotation is in SMPL data (joints 20/21) but AIST++ fits are body-only, so the wrist data is likely noisy; a separate hand segment with damped rotation is low risk. Fingers are not available from SMPL-24.
- A 22-segment rig that mirrors SMPL's body joints one to one removes retarget mapping for rotation entirely, which is the cheapest route to fidelity.

### Gaps
- No perceptual studies on bone-count versus perceived naturalness of dance were searched for successfully or found; the ranking above is engineering judgement, not evidence.
- No GDC talk or animator guidance on clavicle/spine importance was retrieved.

## 3. Retargeting methods for differing proportions

### Takeaway
Production practice (Unreal's IK Retargeter) is a layered stack: copy rotations per chain, scale pelvis translation by the proportion ratio, then correct end effectors with IK goals, pole alignment, floor constraints, stride warping and speed-based foot planting. Holden's guidance is that foot sliding is a velocity mismatch, that the toe should be locked, and that a little sliding is better than breaking the pose.

### Cited Findings

**Unreal Engine 5.8 retarget op stack** — all from [Retargeting Operation Stack](https://dev.epicgames.com/documentation/en-us/unreal-engine/retargeting-operation-stack-in-unreal-engine-5-8)
- **Pelvis Motion:** "Scale Horizontal" and "Scale Vertical" scale pelvis translation (vertical is the correction for height and proportion differences). "Blend to Source Translation" blends between the retargeted pelvis location (0) and the exact source location (1), with per-axis weights. "Affect IK Horizontal/Vertical" sets whether IK goals follow the modified pelvis. A pelvis "Floor Constraint Weight" with "Source/Target Crotch Offset" and "Ground Falloff Height Percent" adjusts vertical motion near the floor.
- **FK Chains:** rotation modes Interpolated, One to One, One to One Reversed, None. Translation modes None ("usually the best choice"), Globally Scaled, Absolute, Stretch Bone Length Uniformly / Non-Uniformly, Orient and Scale.
- **IK chains:** "Chain Position Alpha" moves the goal based on source chain length and direction; "Chain Rotation Alpha" matches the source end-bone rotation; "Final Position/Rotation Alpha" blend back to the FK result.
- **Stride Warping:** "Warp Forwards" (below 1 shortens strides, above 1 lengthens), "Sideways Offset" (negative pulls feet together, positive pushes apart), "Warp Splay". Requires IK goals.
- **Speed Planting:** a goal stays planted while a named source speed curve is below "Speed Threshold"; blend method is a critically damped Spring or "Move Towards".
- **Pole Vector Alignment:** "Align Alpha" twists the chain toward the source pole direction; "Static Angular Offset" in degrees; "Maintain Offset" keeps the retarget-pose pole angle difference.
- **Floor Constraint (per goal):** keeps a goal above Z = 0, with "Maintain Height Offset" and foot-plane settings (Use Foot, Use Toes, Medial/Lateral/Heel/Toe/Vertical Offset).
- **Root Motion:** "Copy From Source Root" scales source root motion by relative height; "Generate From Target Pelvis" rebuilds it from the retargeted pelvis.
- **Self-penetration:** "Body Intersect Goals" (experimental, Spatially Aware Retarget Ops plugin) moves IK goals such as hands so they do not clip chosen bodies of the target's physics asset.
- The older root settings (`FTargetRootSettings`) are deprecated in favour of the Pelvis Motion op — [UE API, FTargetRootSettings](https://dev.epicgames.com/documentation/unreal-engine/API/Plugins/IKRig/FTargetRootSettings)

**Unreal foot-sliding workflow** — [Fix Foot Sliding with IK Retargeter](https://dev.epicgames.com/documentation/en-us/unreal-engine/fix-foot-sliding-with-ik-retargeter-in-unreal-engine)
- Cause given: when leg lengths and stances differ a lot, retargeted feet do not land where the source feet were and drift when they should be still.
- Method: bake a translation-speed curve (XYZ) for each source foot bone, add foot IK goals with a full-body IK solver rooted at the pelvis, and plant each goal while its curve is below a threshold set slightly above the curve's flat level (example value 30, in Unreal units per second).
- Example knee hint: preferred angles of −45° on thighs and +45° on calves to stop stiff or wrong-way bends.

**Daniel Holden, "Inverse Kinematics and Foot Locking"** — all from [theorangeduck](https://theorangeduck.com/page/inverse-kinematics-foot-locking)
- Contact detection: toe global speed with a threshold in the range 0.1–0.5 m/s for good data; toe height below about 0.1 m as a secondary check so a still foot held in the air is not a contact; height alone is unreliable. Clean with a median (majority-vote) filter of about 5 frames at 60 Hz. At 30 Hz contacts can be 1–2 frames, so use 60 Hz; upsample with cubic, not linear, interpolation.
- Lock the toe, not the heel. Heel target = toe target + bind-pose heel-to-toe offset.
- Runtime lock: lock when the input flags contact and output is within `lockDistance` of input; unlock when contact ends or output drifts past `unlockDistance`; blend transitions with cubic inertialization over `blendTime` (no values given).
- Two-bone IK by law of cosines. No pole vector: the bend plane comes from the knee's own side axis, (1,0,0) rotated by the knee's global rotation, so the source knee direction is preserved.
- Unreachable targets: soft-clamp reach to the maximum extension with an exponential falloff (softening distance example 0.005 m) instead of lowering the hips; lowering hips gives a bent-knee "T-rex" look. Limit extension to what the input animation already uses.
- Ground: clamp toe, heel and toe-end targets to their bind-pose minimum heights, then re-aim the toe.
- Offline foot-slide removal: treat pelvis and both toe positions per frame as position-based-dynamics particles; soft constraints (factor 0.05) keep frame-to-frame displacements and hip-to-toe length; hard contact constraints (factor 0.9) pull a toe in contact on consecutive frames to a common point at ground height; example uses 25,000 iterations; then run the leg IK. Tested by scaling root motion by 1.25 and 0.75.
- Principles: foot sliding is a velocity error; scaling root motion and changing joint rotations both cause it; "a little bit of sliding is a lot better than breaking the source animation".
- Holden elsewhere calls foot locking hard to make look good and advises trying other approaches first — [theorangeduck, Code vs Data Driven Displacement](https://theorangeduck.com/page/code-vs-data-driven-displacement)

**Kovar, Schreiner, Gleicher 2002, "Footskate Cleanup for Motion Capture Editing"**
- The method satisfies footplant constraints exactly with only smooth changes and no nonlinear optimisation, and avoids artifacts by allowing small changes to leg length — [UW Graphics, Footskate Cleanup](https://research.cs.wisc.edu/graphics/Gallery/kovar.vol/Cleanup)
- It blends corrections on constrained frames into neighbouring frames and stretches the leg to cover residual distance; the released solver assumes a two-link limb plus an end-effector link — [UW Footskate Solver docs](https://research.cs.wisc.edu/graphics/Gallery/FootskateSolver/footskate.html) (via search summary)

### Inferences

Recommended pipeline for the three bodies (lean male, slighter female, stocky short-legged long-torso ogre), assembled from the above:

1. **Rotation copy for the trunk, head and arms.** With a rig that mirrors SMPL's joints, copy world or local joint rotations directly (Unreal's FK pass with translation mode None). This keeps style and needs no solver.
2. **Scale pelvis translation by leg length.** `scale = targetLegLength / sourceLegLength`, where leg length is thigh + shin + ankle height. Apply it to pelvis height above the floor and to horizontal travel (Unreal's Scale Vertical and Scale Horizontal). For the ogre this shortens steps and lowers the hips so knees keep the source bend.
3. **Place foot targets from the source, normalised.** Take each source toe position relative to the source pelvis's ground projection, scale horizontal components by the leg ratio (optionally widen stance with a sideways offset so a wide ogre pelvis does not cross feet), and keep source heights scaled by the leg ratio.
4. **Contacts from the source, not the target.** Detect on source toe speed (0.1–0.5 m/s hysteresis) and height (< ~0.1 m), median-filter, then pin target toes during contact. Because step 2 scales all travel uniformly, pinned feet stay consistent with pelvis travel; residual error comes only from non-uniform changes (stance widening, torso length).
5. **Two-bone leg IK with the source knee direction.** Use the FK-copied knee side axis as the bend plane (Holden) or align the pole to the source (Unreal Pole Vector Alignment). Soft-clamp reach; do not drop the hips to reach.
6. **Hands: rotation copy by default, optional IK.** For hand-near-body poses (hands on hips, across chest) on the ogre, either express hand targets relative to the nearest torso segment and scale by that segment's size, or simply push hand targets out of per-segment proxy volumes (spheres/capsules for belly, chest, thighs), which is what Unreal's Body Intersect Goals does. A cheaper fix used widely is an A-pose style static offset: add a few degrees of shoulder abduction on wide characters.
7. **Ground clamp last.** Clamp toe/heel to the floor and re-aim the foot.

- Hip-height scaling by leg ratio and effector normalisation by limb length are both expressed in Unreal's settings (Scale Vertical, Chain Position Alpha "based on source chain length"), so they are standard practice, not novel.
- The ogre's long torso needs no translation fix: spine rotations are copied and the longer segments simply reach further. The visible consequences are hands ending higher relative to the hips and more self-penetration, handled in step 6.

### Gaps
- **Gleicher 1998, "Retargetting Motion to New Characters" (UNVERIFIED, not fetched).** Recalled: spacetime-constraints optimisation over the whole motion that preserves chosen constraints (footplants, hand contacts) while keeping the change to the original motion small and low-frequency.
- **Choi & Ko 2000, "Online Motion Retargetting" (UNVERIFIED, not fetched).** Recalled: per-frame inverse-rate-control (Jacobian) IK that tracks end-effector trajectories and uses the redundant degrees of freedom to stay near the source joint angles.
- Kovar's paper itself was not read; details of its ankle/root handling are from the project page and a search summary only. Paper: http://www.cs.wisc.edu/graphics/Papers/Gleicher/Mocap/cleanup.pdf
- Unity's muscle-space retargeting, and the Rokoko and Blender retargeting add-ons, were not researched.
- No authoritative source was found on fixes for hands penetrating a fat character's belly beyond Unreal's experimental Body Intersect Goals; the other fixes in step 6 are common practice stated without a source.
- Holden gives no values for `lockDistance`, `unlockDistance` or `blendTime`. Unreal gives no default Speed Threshold.

## 4. SMPL without the body model

### Takeaway
The 24-joint parent array and a full set of rest-pose joint offsets in metres are hard-coded in an MIT-licensed repository (Stanford EDGE), so FK from axis-angle poses needs no SMPL download. A CC BY 4.0 "SMPL-Body" licence does exist and explicitly covers a skeleton rig, but the standard SMPL model licence is non-commercial research only and whether the offset numbers count as derived SMPL data is not settled by anything found.

### Cited Findings

**Open-source arrays**
- EDGE's `vis.py` defines `smpl_parents`, `smpl_offsets` (24×3) and an `SMPLSkeleton.forward(rotations, root_positions)` that converts axis-angle to quaternions and walks parent-first to produce world joint positions — [EDGE vis.py](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/vis.py)
- The EDGE repository licence is MIT, copyright Jonathan Tseng 2023 — [EDGE LICENSE](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/LICENSE)
- `smpl_offsets`, child relative to parent, metres, x = character's left, y = up, z = forward — [EDGE vis.py](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/vis.py):

```
 0 root         [ 0.0,         0.0,         0.0       ]
 1 lhip         [ 0.05858135, -0.08228004, -0.01766408]
 2 rhip         [-0.06030973, -0.09051332, -0.01354254]
 3 belly        [ 0.00443945,  0.12440352, -0.03838522]
 4 lknee        [ 0.04345142, -0.38646945,  0.008037  ]
 5 rknee        [-0.04325663, -0.38368791, -0.00484304]
 6 spine        [ 0.00448844,  0.1379564,   0.02682033]
 7 lankle       [-0.01479032, -0.42687458, -0.037428  ]
 8 rankle       [ 0.01905555, -0.4200455,  -0.03456167]
 9 chest        [-0.00226458,  0.05603239,  0.00285505]
10 ltoes        [ 0.04105436, -0.06028581,  0.12204243]
11 rtoes        [-0.03483987, -0.06210566,  0.13032329]
12 neck         [-0.0133902,   0.21163553, -0.03346758]
13 linshoulder  [ 0.07170245,  0.11399969, -0.01889817]
14 rinshoulder  [-0.08295366,  0.11247234, -0.02370739]
15 head         [ 0.01011321,  0.08893734,  0.05040987]
16 lshoulder    [ 0.12292141,  0.04520509, -0.019046  ]
17 rshoulder    [-0.11322832,  0.04685326, -0.00847207]
18 lelbow       [ 0.2553319,  -0.01564902, -0.02294649]
19 relbow       [-0.26012748, -0.01436928, -0.03126873]
20 lwrist       [ 0.26570925,  0.01269811, -0.00737473]
21 rwrist       [-0.26910836,  0.00679372, -0.00602676]
22 lhand        [ 0.08669055, -0.01063603, -0.01559429]
23 rhand        [-0.0887537,  -0.00865157, -0.01010708]
```

- HumanML3D's `t2m_raw_offsets` are unit axis directions only (for example (1,0,0) for the left hip, (0,−1,0) for knees, (0,0,1) for toes), not lengths; real bone lengths come from an example skeleton in the dataset, id `'000021'` — [HumanML3D paramUtil.py](https://raw.githubusercontent.com/EricGuo5513/HumanML3D/main/paramUtil.py)
- The AIST++ API is Apache 2.0 (file header, "Copyright 2020 The Google AI Perception Team Authors"). `load_motion` returns `smpl_poses (N, 24, 3)`, `smpl_scaling (1,)`, `smpl_trans (N, 3)`; it applies no scaling itself — [AIST++ loader.py](https://raw.githubusercontent.com/google/aistplusplus_api/main/aist_plusplus/loader.py)
- The AIST++ API does not embed joint offsets: its SMPL visualisation requires `SMPL_MALE.pkl` and `SMPL_FEMALE.pkl` from the SMPL site — [AIST++ API README](https://raw.githubusercontent.com/google/aistplusplus_api/main/README.md)
- The smplx file that lists the joint names carries a proprietary Max Planck header ("Any use of the computer program without a valid license is prohibited") — [smplx joint_names.py](https://raw.githubusercontent.com/vchoutas/smplx/main/smplx/joint_names.py)

**Licences**
- SMPL model licence: for non-commercial scientific research, education and artistic projects; "Any other use, in particular any use for commercial purposes, is prohibited"; no redistribution to third parties without written permission; reverse engineering prohibited; commercial licences via Meshcapade — [SMPL model licence](https://smpl.is.tue.mpg.de/modellicense.html)
- A CC BY 4.0 licence exists: "SMPL-Body is licensed under the Creative Commons Attribution 4.0 International License." SMPL-Body is a subset of the model that includes a 3D mesh, a skeleton rig, pose blendshapes and dynamic blendshapes, and excludes the shape blendshapes and the tools that create bodies from them. Media projects are asked to credit the Max Planck Institute for Intelligent Systems — [SMPL-Body licence](https://smpl.is.tue.mpg.de/bodylicense.html)
- The same page says the full SMPL-Model is covered by Max Planck patents — [SMPL-Body licence](https://smpl.is.tue.mpg.de/bodylicense.html)
- Meshcapade holds the exclusive right to sub-license SMPL commercially; listed prices were €1,500/year (Micro) and €25,000/year (SME) — [Meshcapade body models](https://meshcapade.com/assets/body-models) (via search summary)

### Inferences
- **Practical position.** FK with a parent array and 23 fixed offset vectors uses none of what makes SMPL "the model" (learned shape blendshapes, pose correctives, skinning weights, joint regressor). The parent array is a fact about a tree. Many permissively licensed research repos ship these arrays, and the SMPL-Body CC BY licence explicitly allows sharing a single body's skeleton rig. On that basis, using a fixed skeleton with attribution is low risk.
- **Licence uncertainty, stated plainly.** (a) EDGE's MIT licence covers EDGE's code; it cannot by itself relicense numbers that were computed from the SMPL model, and the repo does not say how `smpl_offsets` was produced (which gender, whether betas = 0). (b) Whether those numbers fall under the model licence or under the CC BY SMPL-Body grant was not answered by any source read. (c) No statement from MPI or Meshcapade on "FK with approximate offsets" was found. If this app is ever sold, the safe options are: credit SMPL-Body under CC BY 4.0, or avoid the question entirely as below.
- **The offsets are not needed for this project.** A stylised figure defines its own bone lengths. Only the parent array and the per-joint rotations are needed: run FK with each body's own rest offsets (male, female, ogre) and SMPL's rotations. That sidesteps the offsets licence question and is also the retargeting step. The one requirement is that the rig's rest pose matches SMPL's rest pose convention (T-pose, arms along ±x, legs along −y, toes forward +z), which the offsets above confirm.
- Bone lengths computed from the EDGE offsets (my arithmetic, metres), useful as proportions for the lean male: hip offset 0.103; thigh 0.389; shin 0.429; ankle→ball 0.142; pelvis→spine1 0.130; spine1→spine2 0.141; spine2→spine3 0.056; spine3→neck 0.215; neck→head 0.103; spine3→collar 0.136; collar→shoulder 0.132; upper arm 0.257; forearm 0.266; wrist→hand 0.089. Pelvis height above the ball-of-foot joint in rest pose is about 0.96 (0.082 + 0.386 + 0.427 + 0.060 on the left side).
- The left and right offsets are slightly asymmetric (the source body is not mirrored). For a stylised rig, mirror one side.
- AIST++ pose data is root translation plus 24 axis-angle rotations per frame; joint 0's rotation is the global orientation.

### Gaps
- **AIST++ units and scaling (UNVERIFIED, from memory).** The loader does not state units. Recalled: `smpl_trans` must be divided by `smpl_scaling` to get metres-scale translation consistent with the SMPL body, and `keypoints3d` are in centimetres at 60 fps. Check against the dataset page before relying on it.
- The Meshcapade wiki's licence and skeleton pages could not be read (redirect then HTTP 403).
- Not confirmed whether the EDGE offsets equal SMPL neutral or male J at betas = 0.
- The "SMPL for Unity/Blender" and SMPLify CC BY releases named in the brief were not located individually; only the SMPL-Body licence page was read.
- PyTorch3D and other repos were not checked for embedded offsets.
- The AIST++ annotation licence was not found in the API README (recalled as CC BY 4.0, UNVERIFIED).

## 5. Alternative: AIST++ COCO-17 3D keypoints directly

### Takeaway
The 17 keypoints give positions for shoulders, elbows, wrists, hips, knees, ankles and five face points, which is enough for limb directions and rough torso and head frames, but they carry no spine joints, no foot or hand orientation and no limb twist. For a rig with toes, a multi-segment spine and clavicles, the SMPL poses are the better source.

### Cited Findings
- AIST++ provides `keypoints3d` and `keypoints3d_optim`, each `(N, 17, 3)` in COCO format — [AIST++ loader.py](https://raw.githubusercontent.com/google/aistplusplus_api/main/aist_plusplus/loader.py)
- Keypoint order is nose, eyes, ears, shoulders, elbows, wrists, hips, knees, ankles (left before right) — [AIST++ API README](https://raw.githubusercontent.com/google/aistplusplus_api/main/README.md)
- The AIST++ SMPL motions were themselves produced by fitting SMPL to these 3D keypoints (`run_estimate_smpl.py`) — [AIST++ API README](https://raw.githubusercontent.com/google/aistplusplus_api/main/README.md)

### Inferences
- **What is lost with keypoints only:** spine curvature and twist distribution (only hip line versus shoulder line is known); clavicle motion as a separate joint (though shoulder positions do include shrug); foot direction, heel/toe contact state and toe bend (ankle point only); hand orientation; upper-arm and thigh axial twist when the limb is straight; neck versus head split.
- **Because the SMPL fit came from these same keypoints,** SMPL's feet, wrists and spine split in AIST++ are partly the fitter's prior, not measurement. Foot and wrist rotations should be treated as soft and may need smoothing.
- **Torso frame:** hip centre H = (lhip + rhip)/2, shoulder centre S = (lsho + rsho)/2. Up = normalise(S − H). Pelvis side = normalise(lhip − rhip) orthogonalised against up; chest side = normalise(lsho − rsho) orthogonalised against up. Forward = side × up (check sign against the handedness in use). Spine twist = signed angle between pelvis side and chest side about up; distribute it evenly across the spine segments, and bend the spine along a curve from H to S.
- **Head frame:** ear midpoint E = (lear + rear)/2 as head centre; side = normalise(lear − rear); forward = normalise(nose − E) orthogonalised against side; up = forward × side (sign per handedness). Eyes can refine up: the eye midpoint sits above the nose. This recovers yaw, pitch and roll; the neck base can be placed at S plus a fixed offset.
- **Limb twist:** elbow and knee bend planes give the side vector whenever the joint is bent: side = normalise((mid − root) × (end − mid)). When nearly straight (cross product small), hold the previous frame's side vector.
- **Foot direction:** not observable. Options: point the foot along the shin's bend-plane forward projected on the ground; blend toward the ankle's horizontal velocity direction when moving; flatten to the floor when ankle height is near its rest height.
- Keypoints suit position-based retargeting (limb directions re-applied with target bone lengths), which gives natural proportion handling but needs all the reconstructions above.

### Gaps
- No source was found evaluating the accuracy of AIST++ SMPL foot or wrist rotations.
- Units and frame rate of `keypoints3d` are not stated in the code read (see section 4 gaps).

## 6. Axis-angle to rotation matrix to FK, and per-segment direction + side vectors

### Takeaway
FK is a parent-first walk: world rotation = parent world rotation × local rotation, and joint position = parent position + parent world rotation × rest offset. Each rigid segment's start, direction and side vector fall straight out of the joint's world rotation applied to rest-pose axes.

### Cited Findings
- EDGE's reference implementation converts axis-angle to quaternions, walks joints parent-first, applies each parent's world rotation to the child's offset to place it, and composes rotations by multiplication, returning world joint positions — [EDGE vis.py](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/vis.py)
- SMPL pose data in AIST++ is `(N, 24, 3)`: one axis-angle 3-vector per joint, plus `(N, 3)` root translation — [AIST++ loader.py](https://raw.githubusercontent.com/google/aistplusplus_api/main/aist_plusplus/loader.py)
- Parents always precede children in the SMPL index order (every parent index is smaller than its child's), so a single pass over 0..23 is a valid traversal — [EDGE vis.py](https://raw.githubusercontent.com/Stanford-TML/EDGE/main/vis.py)

### Inferences

Standard mathematics, stated for implementation:

**Axis-angle to matrix (Rodrigues).** For r ∈ R³: θ = |r|; if θ < 1e-8 use R = I (or I + [r]×). Otherwise k = r/θ, K = [k]× (skew matrix), and
`R = I + sin θ · K + (1 − cos θ) · K²`.
Quaternion form: q = (cos(θ/2), k · sin(θ/2)).

**FK.** With parents p[i], rest offsets o[i] (child relative to parent, in the rest pose), local rotations L[i], root translation t:
```
G[0] = L[0]                 P[0] = t (+ rest pelvis position if the data expects it)
for i in 1..<24:
    G[i] = G[p[i]] * L[i]
    P[i] = P[p[i]] + G[p[i]] * o[i]
```
G[i] is joint i's world rotation; it rotates everything distal to joint i. The offset to joint i is rotated by its parent's G, not its own.

**Per-segment start, direction, side.** A rigid segment runs from joint a to its child b and is rotated by G[a].
- start = P[a]
- direction = normalise(P[b] − P[a]) = G[a] · normalise(o[b])
- side = G[a] · s₀, where s₀ is the segment's rest-pose side axis chosen perpendicular to o[b]. For the SMPL T-pose: s₀ = (1,0,0) for spine, neck, head, thighs, shins and feet (character's left); for arms, which lie along ±x, use s₀ = (0,0,1) (forward) or (0,1,0) (up). Re-orthogonalise: side = normalise(side − direction · dot(side, direction)).
- The third axis is direction × side. Twist about the bone is fully captured because side comes from the full rotation G[a], not from positions.
- Leaf segments (head, hand, toe) have no child joint: use a fixed rest direction d₀ (head up, hand along ±x, toe forward) and direction = G[a] · d₀.

**Retargeting falls out of the same loop.** Substitute each body's own offsets o'[i] for o[i] and keep L[i]. Rotations and twist are preserved, proportions change, and foot contacts then need the pelvis scaling and leg IK from section 3.

**Rest-offset direction mismatch.** If a target body's rest offsets are not parallel to the source's (for example an ogre with a wider stance or A-pose arms), rotation copy shifts the pose by that difference. Either author all three bodies in the same T-pose directions as SMPL, or pre-multiply a fixed per-joint correction that rotates the SMPL rest direction onto the target's.

**Position-only variant (for COCO-17).** direction = normalise(P_child − P_parent); side from the bend-plane cross product in section 5; no twist information beyond that.

### Gaps
- Whether AIST++ root translation is the pelvis joint position or the SMPL model origin (which differ by the rest pelvis offset, non-zero in real SMPL) was not verified; EDGE's offsets put the root at the origin, which hides this. Check by comparing FK ankle heights against the floor in a standing frame.
- No external source is cited for the Rodrigues formula; it is standard and was not fetched.
