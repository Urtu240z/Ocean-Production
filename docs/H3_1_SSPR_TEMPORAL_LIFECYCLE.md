# H3.1 — SSPR temporal reprojection lifecycle

## Ownership audit

`Ocean` owns the feature request and rebuild boundary. `OpenOceanFFT` owns the
`OceanSSPR` node. `OceanSSPR` owns the main-thread `Texture2DRD` wrapper and
publishes only the output RID supplied by its render-thread effect. The
`OceanSSPREffect` owns all `RenderingDevice` RIDs: project candidate buffer,
resolve/depth targets, final mip chain, temporal color/depth history, sampler,
pipelines, and retired output textures. Surface owns only the published
`Texture2D` binding; it does not free the effect's RIDs.

The wrapper may rebind the same stable RID to Surface, but publication is only
allowed after a completed render callback has marked the output fresh. A
recreated final texture is retired and released by a render-thread callback
after the wrapper has stopped publishing the old RID.

## Temporal contract

For frame `N`, the effect packs `inverse(VP[N])` followed by `VP[N-1]`. The
previous VP is stored only after Project, Resolve, Temporal, and mip dispatches
have been recorded successfully. On the first frame, after resize, reactivation,
or a camera cut, the history flag is false and the shader cannot read or blend
the placeholder previous VP.

History is invalidated by SSPR activation changes, temporal configuration
changes, source/target recreation, and resource recreation. Camera cuts use the
documented conservative rule of more than 32 m translation or more than 35°
forward-vector change; normal motion remains eligible for reprojection.

## Temporal OFF

When Temporal is enabled:

```text
Project → Resolve(_raw) → Temporal(_raw + history → mip0) → mip generation
```

When Temporal is disabled:

```text
Project → Resolve(mip0) → mip generation
```

The resolve-to-mip0 barrier remains before the first downsample. Temporal
history textures and the temporal pipeline may remain resident, but OFF never
binds or dispatches the temporal pass, writes or swaps history, or marks history
valid. The candidate arbitration algorithm remains unchanged and is deferred to
H3.2.
