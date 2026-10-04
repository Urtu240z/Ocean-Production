// Read-only verification and aggregation of the complete exported evidence.
// Usage: node validation/physics/phys_gpu13_verify.cjs [repository root]
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');
const root = path.resolve(process.argv[2] || path.join(__dirname, '../..'));
const base = path.join(root, 'validation/physics');
const manifest = JSON.parse(fs.readFileSync(path.join(base, 'PHYS-GPU-1.3-EVIDENCE-MANIFEST.json')));
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const distance = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
const errors = [...manifest.errors];
const result = { files: 0, bytes: 0, largest_file: 0, main: {}, supplemental: {} };
const newTotals = () => ({ cases: 0, ambiguous: 0, wrong: 0, misses: 0, roots: 0, max_roots: 0,
  valid_unmatched: 0, above_reference_2mm: 0, below_reference_near_max_q: 0,
  ordinary_single_root_handoffs: 0, envelope_matching_handoffs: 0,
  by_case: {}, by_scenario: {}, by_ownership: {}, by_status: {}, by_ambiguity: {}, cold_fold: {}, reentry: {} });
result.main = newTotals(); result.supplemental = newTotals();
function bin(t, key, e) {
  const b = t[key] ||= { cases: 0, wrong: 0, misses: 0, acquired: 0, envelope_matches: 0 };
  b.cases++; b.wrong += +e.envelope_check.wrong_lower_sheet;
  b.misses += +e.envelope_check.bounded_candidate_miss; b.acquired += +e.row.valid;
  b.envelope_matches += +(e.row.valid && e.envelope_check.selected_matches_discovered_root && !e.envelope_check.wrong_lower_sheet);
}
function observe(t, e) {
  const c = e.envelope_check, r = e.row, ref = e.reference;
  if (r.generation !== e.generation || r.config !== e.config || r.solves > 5 || r.iterations > 80)
    errors.push('incoherent packet identity/production budget');
  t.cases++; t.ambiguous += +r.ambiguous; t.wrong += +c.wrong_lower_sheet;
  t.misses += +c.bounded_candidate_miss; t.roots += ref.roots.length;
  t.max_roots = Math.max(t.max_roots, ref.roots.length);
  t.valid_unmatched += +(r.valid && !c.selected_matches_discovered_root);
  t.above_reference_2mm += +(r.valid && c.height_gap < -0.002);
  t.below_reference_near_max_q += +(c.wrong_lower_sheet && distance(r.q, ref.envelope.q) < 0.02);
  t.ordinary_single_root_handoffs += +(r.status === 5 && e.context.scenario !== 'fold' && ref.roots.length === 1);
  t.envelope_matching_handoffs += +(r.status === 5 && c.selected_matches_discovered_root && !c.wrong_lower_sheet);
  bin(t.by_case, `${e.case.vehicles}x${e.case.contacts}/${e.case.long ? 'long' : 'short'}`, e);
  bin(t.by_scenario, e.context.scenario, e);
  bin(t.by_ownership, r.owned ? 'warm' : 'cold', e);
  bin(t.by_status, r.status, e);
  bin(t.by_ambiguity, r.ambiguous ? 'ambiguous' : 'not_ambiguous', e);
  if (!r.owned && e.context.scenario === 'fold') bin(t.cold_fold, 'attempts', e);
  if (e.context.reentry || (e.context.scenario === 'stationary_reentry' && !r.owned)) bin(t.reentry, e.context.duration, e);
  for (const q of ref.roots) {
    // The solver applies 1 micrometre before FP32 ABI serialization.
    if (!q.valid || !Number.isFinite(q.residual) || q.residual > 0.000001000001)
      errors.push('invalid serialized fine reference root');
    if (!Array.isArray(q.q) || q.q.length !== 2 || !q.q.every(Number.isFinite) ||
        !Array.isArray(q.world) || q.world.length !== 3 || !q.world.every(Number.isFinite) ||
        !Array.isArray(q.normal) || q.normal.length !== 3 || !q.normal.every(Number.isFinite) ||
        !Number.isFinite(q.det) || !Number.isFinite(q.distance_from_previous))
      errors.push('incomplete reference root record');
  }
}
for (const f of manifest.files) {
  const p = path.resolve(root, f.path);
  if (!p.startsWith(root + path.sep)) throw Error('Manifest path outside repository');
  const bytes = fs.readFileSync(p), plain = p.endsWith('.gz') ? zlib.gunzipSync(bytes) : bytes;
  result.files++; result.bytes += bytes.length; result.largest_file = Math.max(result.largest_file, bytes.length);
  if (bytes.length !== f.bytes || plain.length !== f.plain_bytes || hash(bytes) !== f.sha256 || hash(plain) !== f.plain_sha256)
    errors.push(`checksum/size mismatch: ${f.path}`);
  if (p.endsWith('.jsonl.gz')) {
    let rows = 0;
    for (const line of plain.toString('utf8').split('\n')) if (line) {
      rows++; observe(path.basename(p).startsWith('reentry10-') ? result.supplemental : result.main, JSON.parse(line));
    }
    if (rows !== f.rows) errors.push(`row count mismatch: ${f.path}`);
  }
}
for (const [label, relative] of Object.entries({ shader: 'addons/ocean/physics/gpu/ocean_surface_query.glsl', wrapper: 'addons/ocean/physics/gpu/ocean_surface_query.gd' }))
  if (hash(fs.readFileSync(path.join(root, relative))) !== manifest.source_hashes[label]) errors.push(`production source mismatch: ${label}`);
for (const [name, expected] of Object.entries({ 'phys_gpu13_export.gd': manifest.export_source_hash, 'phys_gpu13_verify.cjs': manifest.verifier_source_hash }))
  if (hash(fs.readFileSync(path.join(base, name))) !== expected) errors.push(`evidence-tool source mismatch: ${name}`);
if (result.main.cases !== manifest.envelope_case_rows || result.supplemental.cases !== manifest.reentry10_envelope_case_rows)
  errors.push('archive case count mismatch');
const ledger = JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(base, 'PHYS-GPU-1.3-CONTACT-LEDGER.json.gz'))));
const audit = { cases: ledger.length, owned: 0, missing_predecessor: 0, previous_q_mismatch: 0,
  previous_y_mismatch: 0, handoffs: 0, case_scoped_reversals: 0, repeated_toggle_windows: 0 };
const history = {};
for (const e of ledger) {
  const r = e.row, p = e.predecessor;
  if (r.owned) {
    audit.owned++; if (!p.valid) audit.missing_predecessor++;
    else { audit.previous_q_mismatch += +(distance(r.previous_q, p.q) > 0.0001);
      audit.previous_y_mismatch += +(Math.abs(r.previous_y - p.surface_y) > 0.00001); }
  }
  if (r.status === 5) {
    audit.handoffs++; const key = JSON.stringify(e.case) + '/' + e.context.slot, old = history[key];
    const reverse = !!old && e.time - old.time < 0.1 && distance(r.q, old.previous) < 0.02;
    audit.case_scoped_reversals += +reverse;
    audit.repeated_toggle_windows += +(reverse && old.reverse);
    history[key] = { time: e.time, previous: r.previous_q, reverse };
  }
}
if (audit.missing_predecessor || audit.previous_q_mismatch || audit.previous_y_mismatch) errors.push('executed predecessor mismatch');
result.history_audit = audit; result.errors = errors;
console.log(JSON.stringify(result));
if (errors.length) process.exitCode = 1;
