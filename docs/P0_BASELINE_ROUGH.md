# P0 baseline visual — ROUGH

La referencia oficial de P0 es `lab/lab_main.tscn` de Ocean Lab,
con el preset `ROUGH` y sus overrides efectivos. Este documento registra sólo
los valores que afectan al océano abierto de P0; Coastal y los sistemas que no
forman P0 no se trasladan.

## Simulación

- Seed: el valor activo de `SimulationClock` en la comparación manual. La
  escena P0 usa `1` como seed determinista inicial.
- Spectrum: JONSWAP + Hasselmann.
- Wind global: 18.0 m/s.
- LONG: 256, dominio 512 m, Hs 2.50 m, choppiness 2.00, dirección `(1, 0.10)`,
  spread 5.0, fetch 25 000 m, swell 0.80, lambda 16–128 m.
- MID: 256, dominio 137 m, Hs 0.60 m, choppiness 1.25, dirección `(1, 0.38)`,
  spread 3.5, fetch 3 000 m, swell 0.45, lambda 4–20 m.
- SHORT: 256, dominio 37 m, Hs 0.12 m, choppiness 0.40, dirección `(1, 0.62)`,
  spread 3.0, fetch 300 m, swell 0.15, lambda 0.5–5 m.

La altura significativa combinada aproximada es 2.574 m. P0 genera el H0 de
LONG directamente con esos valores y la misma derivación de seed por banda que
Lab; no conserva LONG_COASTAL ni LONG_REMAINDER.

## Presentación P0

- Clipmap: 192 celdas, espaciado base 0.25 m, 10 niveles, mar a Y=0.
- Fades: SHORT 0–55 m; MID 96–280 m; LONG 768–2 500 m.
- Colores de referencia deep/horizon: `(0.019474, 0.090904, 0.088472)` y
  `(0.007519, 0.077502, 0.045543)`.

No forman parte de P0: Coastal, foam de cualquier clase, óptica/refraction,
SSPR, underwater, caustics, sunrays, sediment, OceanQuery y diagnósticos de
Lab. Por tanto este documento no declara equivalencia visual completa ni
`VISUAL PASS`; sirve como contrato de simulación de mar abierto para la revisión
manual de Eric.
