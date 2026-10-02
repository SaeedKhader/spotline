#!/bin/zsh
# Measures the app's speed on a project: opens a copy of it in the built app, which then
# plays, selects, types, reviews and scrolls by itself (PerformanceRun.swift) and writes what
# each cost. The project itself is never changed, and nothing is sent to an AI provider.
# Build the app first (xcodebuild ... -derivedDataPath build/DerivedData).
# Usage: scripts/perf.sh <project.spotline> [label] [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

project=${1:?Usage: scripts/perf.sh <project.spotline> [label] [Debug|Release]}
label=${2:-run}
configuration=${3:-Debug}
app="$PWD/build/DerivedData/Build/Products/$configuration/Spotline.app"
[[ -d "$app" ]] || { echo "Build the app first: $app is missing." >&2; exit 1 }

out="$PWD/build/perf/$label"
rm -rf "$out"
mkdir -p "$out"
# The same name as the original: the video is found by its path in the project.
copy="$out/$(basename "$project")"
cp -R "$project" "$copy"
report="$out/report.json"

# In the background (-g), so it takes no keys or clicks; the run brings its window forward to be drawn.
open -g -n "$app" --args -ApplePersistenceIgnoreState YES -OpenProject "$copy" -PerfReport "$report" -PerfQuit
for _ in {1..300}; do
  [[ -s "$report" ]] && break
  sleep 1
done
[[ -s "$report" ]] || { echo "No report after 5 minutes." >&2; exit 1 }

python3 - "$report" <<'PYTHON'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit(open(sys.argv[1]).read())
p = r["project"]
print(f'{p["cues"]} cues, {p["reviewCards"]} review cards, translating: {p["isTranslating"]}, '
      f'{p["glossaryTerms"]} glossary terms, window visible: {r["windowWasVisible"]}')
print(f'\nOpen: {r["openSeconds"]:.2f} s from launch to cues and video ({r["open"]["busyMs"]:.0f} ms of main-thread work, '
      f'longest stall {r["open"]["longestMs"]:.0f} ms)')
def load(name, key):
    l = r.get(key)
    if not l: return
    l = l.get("load", l)
    extra = f', {r[key]["stepsPerSecond"]:.0f} of 60 steps/s' if "stepsPerSecond" in r[key] else ""
    print(f'{name:<22} main thread busy {l["busyMs"] / (l["seconds"] * 10):5.1f}%   longest stall {l["longestMs"]:6.0f} ms   '
          f'stalls >16 ms: {l["over16"]:3d}  >50 ms: {l["over50"]:3d}  >100 ms: {l["over100"]:3d}{extra}')
print()
load("Idle (3 s)", "idle")
load("Playback (8 s)", "playback")
load("Scroll cue list (4 s)", "scrollCueList")
load("Scroll review (4 s)", "scrollReview")
print(f'\n{"Each action, in ms":<22} {"median":>8} {"p90":>8} {"worst":>8} {"longest stall":>14} {"its own code":>13}')
for name, key in [("Select next cue", "selectNextCue"), ("Jump to a far cue", "jumpToFarCue"), ("Type a character", "typeCharacter"),
                  ("Undo / redo", "undo"), ("Next review card", "nextReviewCard"), ("Switch review filter", "switchReviewFilter")]:
    a = r.get(key)
    if a:
        print(f'{name:<22} {a["medianMs"]:8.0f} {a["p90Ms"]:8.0f} {a["worstMs"]:8.0f} {a["longestStallMs"]:14.0f} {a["modelMedianMs"]:13.1f}')
if r.get("timelineFrameMs") is not None:
    print(f'\nTimeline, drawn for one frame of playback: {r["timelineFrameMs"]:.2f} ms')
print("\nSingle calls, in ms")
for name, ms in sorted(r["calls"].items()):
    print(f'  {name:<32} {ms:8.3f}')
PYTHON
echo "\nReport: $report"
