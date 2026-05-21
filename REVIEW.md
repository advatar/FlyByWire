# Code Review: fly-brain

Review date: 2026-05-11
Tracker: https://github.com/advatar/Tracker/issues/53
Scope: top-level app folder `fly-brain` and nested project manifests under this folder, excluding generated dependency/build directories such as `.git`, `node_modules`, `target`, `.build`, `dist`, and virtual environments.

## Executive Summary

- Overall risk from this sweep: **High**
- Findings by severity: High 1, Medium 1, Low 1
- Source footprint: 45 source files by extension scan (Swift 26, Python 18, Shell 1)
- Test footprint: 6 test-like files detected
- CI footprint: 1 GitHub Actions workflow files detected
- Git posture: 1 changed/untracked paths before review generation
- Pattern scan budget used: 68 text/source files scanned

## Architecture Snapshot

Detected project and build surfaces:
- `macos/FlyBrainWorldMac/FlyBrainWorldMac.xcodeproj`
- `vision-pro/FlyBrainVision/FlyBrainVision.xcodeproj`
- `vision-pro/FlyBrainWorldVision/FlyBrainWorldVision.xcodeproj`

Nested manifest owners sampled:
- `macos/FlyBrainWorldMac`
- `vision-pro/FlyBrainVision`
- `vision-pro/FlyBrainWorldVision`

Package scripts sampled:
- No JavaScript package scripts detected.

Local instruction/status files:
- `AGENTS.md`
- `STATUS.md`

## Findings

### 1. [High] Dynamic code or shell execution needs input-boundary review

These APIs are legitimate in tooling, but they become high-risk when command strings or evaluated input can be influenced by users, files, networks, or model output. Scanner count: 1.

Evidence:
- code/embodied_simulation.py:267 `value = eval(`
### 2. [Medium] Potential credential/config material needs a focused secret audit

Names commonly used for credentials or sensitive tokens appear in app-owned files. Some hits may be fixtures or placeholders, but every example should be verified, documented as fake, or moved to secret management. Values are redacted here. Scanner count: 5.

Evidence:
- code/embodied_simulation.py:672 `for token, canonical in leg_mappings.items():`
- code/embodied_simulation.py:673 `if token in normalized:`
- code/embodied_simulation.py:678 `for token, canonical in joint_mappings.items():`
- code/embodied_simulation.py:679 `if token in normalized:`
- tests/test_embodied_simulation.py:49 `def test_canonical_leg_joint_name_normalizes_common_tokens(self):`
### 3. [Low] Large source-tree files should be checked against release strategy

Large model/media/data files can be valid, but they need clear provenance and should stay out of normal code-review diffs when possible.

Evidence:
- data/2025_Connectivity_783.parquet (96.1 MB)
- data/archive/2023_Connectivity_630.parquet (82.6 MB)

## Testing and Build Posture

Detected tests:
- `macos/FlyBrainWorldMac/FlyBrainWorldMac/Tests/FlyWorldBrainDrivenMotionTests.swift`
- `macos/FlyBrainWorldMac/FlyBrainWorldMac/Tests/FlyWorldPosePacketTests.swift`
- `macos/FlyBrainWorldMac/FlyBrainWorldMac/Tests/MacFlyWorldCameraStateTests.swift`
- `tests/test_cli_smoke.py`
- `tests/test_embodied_simulation.py`
- `tests/test_runtime_validation.py`

Detected CI workflows:
- `.github/workflows/ci.yml`

Inferred verification commands to standardize:
- Xcode: run scheme-specific `xcodebuild test`/`build` once schemes and destinations are selected.

## Review Limitations

- This was a broad static review across many local apps, not a full manual product walkthrough.
- Generated directories and dependency trees were pruned so findings focus on app-owned source.
- Secret-like values were not reproduced; examples are redacted or limited to path/line evidence.
- Pattern scanning is capped per app to keep the cross-repository sweep tractable; high-risk folders need focused follow-up review.

## Recommended Next Steps

1. Resolve every High finding first, especially secret material, tracked generated output, and dynamic execution paths.
2. Add or tighten the app's canonical CI workflow so build and tests run on every push.
3. Convert inferred build/test commands into documented commands in the app README or STATUS file.
4. Add smoke tests around app launch, persistence, API boundaries, and security-sensitive adapters.
5. Re-run this review after cleanup and replace this file with a human-reviewed release checklist.
