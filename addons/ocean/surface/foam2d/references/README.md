# Preserved visual references

`original/` preserves the consolidated pre-F1/F2 surface shader, interaction-history script and compute shader. `f1f2/` preserves the experimental F1/F2 versions used before projected hull foam.

These files were copied byte-for-byte from the locally preserved baseline and F1/F2 snapshots. `manifest.json` records their SHA-256 hashes. They remain available through the explicit original/f1f2 comparison modes; the normal combined/contact/wake modes use projected foam.

Source text uses `.source` so it remains readable in exports. Legacy compute shaders are imported normally. The comparison loader remaps the compute path in memory to the matching packaged reference and adds identical timing instrumentation. No temporary development folder is required.

These are fixed-condition historical comparison modes, not production Inspector choices. They retain their historical limitation when rebuilding the spectrum during a run. Wind-change persistence is supported and validated for the current combined/contact/wake effects.
