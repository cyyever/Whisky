#!/bin/bash
set -e

# Track KosmicKrisp's progress on the Metal-hardware geometry gaps that block
# real D3D11/D3D12 games: geometry shaders, transform feedback, tessellation.
# All are emulated via the shared compute-based "poly" software pipeline
# (src/poly + src/kosmickrisp/libkk/*.cl). Queries the public Mesa GitLab; no
# auth or local checkout needed. Re-run periodically; compare to the baseline
# in memory note [[kosmickrisp-geometry-emulation]].

API="https://gitlab.freedesktop.org/api/v4/projects/mesa%2Fmesa"
RAW="https://gitlab.freedesktop.org/mesa/mesa/-/raw/main"
PY=/opt/homebrew/bin/python3

echo "=== KosmicKrisp geometry-stage progress (Mesa main) ==="
echo

# 1. geometryShader feature bit on main (the definitive "is it exposed" signal).
echo "-- geometryShader feature --"
if curl -s "$RAW/src/kosmickrisp/vulkan/kk_features.c" 2>/dev/null | grep -q 'geometryShader.*true'; then
    echo "  geometryShader = TRUE  <-- exposed! rebuild vendor/mesa and re-run tests/d3d12"
else
    kk=$(curl -s "$RAW/src/kosmickrisp/vulkan/kk_physical_device.c" | grep -c 'geometryShader.*true' || true)
    [ "$kk" -gt 0 ] && echo "  geometryShader = TRUE (in kk_physical_device.c)" \
                     || echo "  geometryShader = not yet true"
fi

# 2. Size of the GS emulation kernel (grows as it's implemented; ~44 lines = stub).
echo "-- kk_geometry.cl (GS compute kernel) --"
lines=$(curl -s "$RAW/src/kosmickrisp/libkk/kk_geometry.cl" | grep -c '' || echo "?")
echo "  $lines lines (was 44 = stub on 2026-07-18)"

# 3. Recent commits touching the GS / poly-geometry code.
echo "-- recent commits: kk_geometry.cl --"
curl -s "$API/repository/commits?path=src/kosmickrisp/libkk/kk_geometry.cl&per_page=5" \
    | $PY -c 'import json,sys; [print("  ",c["committed_date"][:10],c["title"][:66]) for c in json.load(sys.stdin)]' 2>/dev/null || echo "  (none)"

# 4. Open MRs mentioning geometry in KosmicKrisp.
echo "-- open MRs (geometry, kk) --"
curl -s "$API/merge_requests?state=opened&search=geometry&per_page=40" \
    | $PY -c 'import json,sys
d=json.load(sys.stdin)
hits=[m for m in d if "kosmic" in (m["title"]+"".join(m.get("labels",[]))).lower() or "kk:" in m["title"].lower() or "poly" in m["title"].lower()]
print("\n".join("  !%d %s"%(m["iid"],m["title"][:66]) for m in hits) or "  (none open)")' 2>/dev/null

# 5. The MoltenVK-parity tracking issue.
echo "-- parity issue #14209 --"
curl -s "$API/issues/14209" | $PY -c 'import json,sys; d=json.load(sys.stdin); print("  state:",d["state"],"| updated",d["updated_at"][:10])' 2>/dev/null

echo
echo "When geometryShader flips true: git submodule update --remote vendor/mesa;"
echo "scripts/build-kosmickrisp-x86.sh; make wine; tests/d3d12/run.sh"
