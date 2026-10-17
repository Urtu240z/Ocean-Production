# Ocean + Jet Ski consolidation — 2026-10-17

The accepted production state is the tip of `wip/feel-soft-water` after E2,
including the autonomous Ocean clock, Inspector connection, frozen editor
preview, exact portable production preset, raised-wave transmission and scene
lighting. The latest coastal change records requirements; it does not enable an
experimental coastal implementation. No experimental P5 branch is merged.

## Preservation and classification

The initial worktree had exactly 2,150 untracked files and no tracked edits.
The final classification incorporates 36 of those files (35 at their original
paths and the E1 native oracle relocated into `validation/fixtures/`). It preserves
1,817 historical files, 296 generated files and one registered WSL disk externally.
Every original file has its path, size and SHA-256 in the initial manifest.

External evidence and resource locations are recorded under:

```text
Water Race Backups/20261017_master_consolidation/
  untracked_manifest.json          original, immutable inventory
  classification_final.json       final category and versioned-path mapping
  preservation_manifest.json       verified destination for each preserved file
  preserved/B/                    historical assets, experiments and evidence
  preserved/C/                    generated intermediates retained for recovery
  preserved/D/                    stopped WSL disk snapshot before validation
  historical_backup_reverified.json
  git_audit_before.json
  worktrees_before.json
  tests/
```

Identical existing backups are reused by exact SHA-256. The pre-phase-B ZIP was
rechecked against SHA-256
`b8462cabf06fd8bb07ff0037290c1e2d1ef59d6b6a278ab3b02dfdb665a20eb3`
and its complete ZIP CRC check passed. That archive preserves the original P5
work. `Splash_2`, unused root spray textures and their import settings remain
recoverable; the active addon uses its own versioned spray textures and frames.

Preservation tags record the original work tip and original master:
`preserve/consolidation-20261017-work-before` and
`preserve/consolidation-20261017-master-before`.
The WIP branch and all historical worktrees remain available.

## Validation

Godot 4.7.1, Windows Forward+ D3D12, Jolt Physics; Linux native replay in the
existing WSL distribution. Fresh installations contain only versioned addon
files, not development caches or untracked runtime assets.

| Check | Result |
| --- | --- |
| Clean Ocean import | Pass, no errors |
| Clean Ocean + Jet Ski import | Pass, no errors |
| Fresh full-project import | Pass, no errors |
| Windows DLL and Linux SO replay | Pass, 340,560 values, no out-of-tolerance results |
| Linux versus Windows maximum error | 3.74278386061633e-12, tolerance 1e-8 |
| Native repeat determinism | Exact on both platforms |
| Autonomous clock | Pass, 540 valid samples, one shared build per tick |
| Portable preset exact resource/node verification | Pass |
| Portable preset execution without development project | Pass |
| Inspector startup: 1, 2 and 12 vehicles | Pass, independent contexts, max one CPU construction per tick |
| Clean functional driving/flotation/recovery | Pass, two landings, zero field failures |
| Camera and original spray | Pass, nine camera controls and eight sequence frames |
| Underwater | Pass, AIR_SAFE / UNDERWATER_SAFE / AIR_SAFE |
| D2/D3 trajectory | Pass, 1,140 steps, zero position/velocity/angular/basis error |
| Camera settings against oracle | All 23 identical |
| Portable in-repository oracle rerun | Pass; no original absolute fixture dependency |
| Real editor preview | Pass, freeze/time/profile/SSPR/serialization/ON-OFF checks |
| Windows and Linux release exports | Pass; 382 packed files each, native hashes match |
| Export pack dependency and embedded-data audit | Pass on both platforms |
| Windows release launch | Pass, Forward+ and waterline READY, no errors |
| Linux release launch | Pass, actual Forward+ Vulkan renderer in WSL |

The portable D3 scene changes only its test-controller path. No production
addon, shader, profile, vehicle parameter, camera parameter or native binary is
changed by consolidation. The original 1,294 tracked files were hashed before
work; the only edited existing tracked file is `.gitignore`.

Direct source fallback covered 341 addon source/config/import files after graph
coverage reported shader/parser/binary exclusions. No absent literal addon
resource paths, duplicate global classes or duplicate script UIDs were found.
The spray directory is checked by the clean runtime and packed-frame audits.
No tracked file exceeds GitHub's 100 MiB limit; the largest existing blob is
80,144,680 bytes. There are no Git LFS pointer files. No VM, capture ETL, export
executable, development environment or generated translation is added to Git.

Historical bow-spray and early physics validators using the former
`gameplay/vehicles/` hierarchy are preserved externally with their evidence.
They are not used as acceptance tests for the current addon layout. Their source
paths and exact contents remain recoverable in the preservation manifest.

## Local environments and other worktrees

`.godot` caches, the pinned local `godot-cpp` checkout, native build intermediates
and local validation environments remain ignored. No whole `.godot` directory
is removed. The single exact ignore added for
`temp/phase_e1_20261016/wsl/ext4.vhdx` retains the registered Linux installation;
its external pre-validation snapshot is independently hash-verified. This rule
does not hide production assets. `temp/.gdignore` prevents generated test outputs
from being imported as project resources.

The P5 worktree has nine pre-existing changes. The P3 Clean and Visibility Clean
worktrees are clean. Their heads, indexes and files are left untouched. Final
verification and the complete commit list are retained in the external report.
