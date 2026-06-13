#!/usr/bin/env bash
# render_assets.sh — Render Assets SVGs to PNG/PDF using Inkscape, rsvg-convert, or ImageMagick
# Usage: ./scripts/render_assets.sh [--manifest PATH] [--dry-run]
# Default manifest: Assets/assets_render.json

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DEFAULT="$REPO_ROOT/Assets/assets_render.json"

DRY_RUN=0
MANIFEST_PATH="$MANIFEST_DEFAULT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: render_assets.sh [--manifest PATH] [--dry-run]

Renders SVG assets described in a machine-friendly manifest (JSON).
If no manifest is provided, the script attempts reasonable defaults for SVGs in Assets/.

Output files are written next to the source SVG paths (Assets/...).

Requirements: inkscape (preferred) OR rsvg-convert OR ImageMagick (magick) installed.
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Find available renderer
RENDERER=""
if command -v inkscape >/dev/null 2>&1; then
  RENDERER="inkscape"
elif command -v rsvg-convert >/dev/null 2>&1; then
  RENDERER="rsvg-convert"
elif command -v magick >/dev/null 2>&1; then
  RENDERER="magick"
else
  echo "Error: no renderer found. Install inkscape, librsvg (rsvg-convert), or ImageMagick (magick)." >&2
  exit 2
fi

echo "Renderer: $RENDERER"

# Helper: run a render action
render_file() {
  local input="$1"
  local out="$2"
  local w="$3"
  local h="$4"
  local type="$5"

  echo "Render: $input -> $out (${w}x${h}, type=$type)"
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$out")"

  case "$RENDERER" in
    inkscape)
      # Inkscape >=1.0 CLI
      if [[ "$type" == "pdf" ]]; then
        inkscape "$input" --export-type=pdf --export-filename="$out" >/dev/null 2>&1
      else
        inkscape "$input" --export-type=png --export-filename="$out" --export-width="$w" --export-height="$h" >/dev/null 2>&1
      fi
      ;;
    rsvg-convert)
      # rsvg-convert (librsvg)
      if [[ "$type" == "pdf" ]]; then
        echo "PDF export not supported by rsvg-convert. Skipping $out" >&2
        return 1
      else
        rsvg-convert -w "$w" -h "$h" -o "$out" "$input"
      fi
      ;;
    magick)
      # ImageMagick convert (magick)
      if [[ "$type" == "pdf" ]]; then
        magick "$input" -resize "${w}x${h}" "$out"
      else
        magick -density 300 "$input" -resize "${w}x${h}" "$out"
      fi
      ;;
    *)
      echo "Unsupported renderer: $RENDERER" >&2
      return 2
      ;;
  esac
}

# Load manifest if present
if [[ -f "$MANIFEST_PATH" ]]; then
  echo "Using manifest: $MANIFEST_PATH"
  MANIFEST_JSON="$(cat "$MANIFEST_PATH")"
else
  echo "Manifest not found at $MANIFEST_PATH — generating defaults from Assets/*.svg"
  # Build a simple manifest JSON on the fly
  SVG_FILES=( $(find "$REPO_ROOT/Assets" -maxdepth 1 -type f -name "*.svg" -print) )
  MANIFEST_JSON="{ \"renders\": ["
  first=1
  for svg in "${SVG_FILES[@]}"; do
    name="$(basename "$svg")"
    # default behavior based on filename
    if [[ "$name" == *briefing* ]]; then
      outputs='[{"out":"Assets/google_briefing_print.png","w":3508,"h":2480,"type":"png"},{"out":"Assets/google_briefing_vtt.png","w":2048,"h":1536,"type":"png"},{"out":"Assets/google_briefing_print.pdf","w":3508,"h":2480,"type":"pdf"}]'
    elif [[ "$name" == *binding* ]]; then
      outputs='[{"out":"Assets/binding_mark_print.png","w":3000,"h":3000,"type":"png"},{"out":"Assets/binding_mark_vtt.png","w":2048,"h":2048,"type":"png"},{"out":"Assets/binding_mark_thumb.png","w":512,"h":512,"type":"png"}]'
    else
      # generic: print + vtt
      base="${name%.svg}"
      outputs="[{\"out\":\"Assets/${base}_print.png\",\"w\":3508,\"h\":2480,\"type\":\"png\"},{\"out\":\"Assets/${base}_vtt.png\",\"w\":2048,\"h\":1536,\"type\":\"png\"}]"
    fi

    if [[ $first -eq 1 ]]; then first=0; else MANIFEST_JSON+=", " ; fi
    MANIFEST_JSON+="{ \"in\": \"$svg\", \"outputs\": $outputs }"
  done
  MANIFEST_JSON+="] }"
fi

# Parse manifest using jq if available, otherwise use python for minimal parsing
if command -v jq >/dev/null 2>&1; then
  echo "Parsing manifest with jq"
  renders_count=$(echo "$MANIFEST_JSON" | jq '.renders | length')
  for i in $(seq 0 $((renders_count - 1))); do
    in_path=$(echo "$MANIFEST_JSON" | jq -r ".renders[$i].in")
    outputs_count=$(echo "$MANIFEST_JSON" | jq ".renders[$i].outputs | length")
    for j in $(seq 0 $((outputs_count - 1))); do
      out_path=$(echo "$MANIFEST_JSON" | jq -r ".renders[$i].outputs[$j].out")
      w=$(echo "$MANIFEST_JSON" | jq -r ".renders[$i].outputs[$j].w")
      h=$(echo "$MANIFEST_JSON" | jq -r ".renders[$i].outputs[$j].h")
      type=$(echo "$MANIFEST_JSON" | jq -r ".renders[$i].outputs[$j].type")

      if [[ "$in_path" == "null" || "$out_path" == "null" ]]; then
        echo "Skipping malformed manifest entry: index $i/$j" >&2
        continue
      fi
      render_file "$in_path" "$REPO_ROOT/$out_path" "$w" "$h" "$type"
    done
  done
else
  # Fallback to python for parsing
  echo "jq not found — using Python to parse manifest"
  python3 - <<PY
import json, sys, os
m = json.loads('''$MANIFEST_JSON''')
for entry in m.get('renders', []):
    inp = entry.get('in')
    for out in entry.get('outputs', []):
        outp = out.get('out')
        w = out.get('w')
        h = out.get('h')
        t = out.get('type')
        # call back to shell render via environment
        cmd = [os.environ.get('SHELL','/bin/bash'), '-lc', f"render_file '{inp}' '{os.path.join('$REPO_ROOT', outp)}' {w} {h} {t}"]
        print('DRY' if os.environ.get('DRY_RUN','0')=='1' else 'RUN', cmd)
        if os.environ.get('DRY_RUN','0')!='1':
            os.system(' '.join(cmd))
PY
fi

echo "Done. Rendered assets placed under Assets/."