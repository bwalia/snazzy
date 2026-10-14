#!/bin/zsh
# Makes a tour film ready for site/tours: cuts still stretches (waiting for a
# model) down to 2 seconds, crops the macOS menu bar off whole-screen films,
# scales, compresses, and writes a poster frame.
#
#   Scripts/tour-publish.sh <film.mp4> <name> [--crop-menu-bar] [--width 1440] [--poster-at 60]
#
# Writes site/tours/<name>.mp4 and site/tours/<name>.jpg.
set -euo pipefail

in=$1; name=$2; shift 2
crop=0; width=1440; poster=60
while (( $# )); do
  case $1 in
    --crop-menu-bar) crop=1 ;;
    --width) width=$2; shift ;;
    --poster-at) poster=$2; shift ;;
  esac
  shift
done
out=site/tours/$name.mp4

# Still stretches of 6 s or more (the picture doesn't change).
freezes=$(ffmpeg -hide_banner -i "$in" -vf "freezedetect=n=0.002:d=6" -map 0:v -f null - 2>&1 \
  | grep -oE "freeze_(start|end): [0-9.]+" | awk '{print $2}' | paste -sd' ' -)
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")

# Keep everything except the middle of each still stretch (2 s of it stays).
segments=$(python3 - "$duration" $freezes <<'EOF'
import sys
duration = float(sys.argv[1]); marks = [float(x) for x in sys.argv[2:]]
if len(marks) % 2: marks.append(duration)
keep, t = [], 0.0
for start, end in zip(marks[::2], marks[1::2]):
    keep.append((t, start + 2.0)); t = end
keep.append((t, duration))
print(" ".join(f"{a:.3f}:{b:.3f}" for a, b in keep if b - a > 0.2))
EOF
)
has_audio=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$in" | head -1)
height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$in")

pre="null"
if (( crop )); then
  # The menu bar is 37 points (74 px at 2x) on the films' screen.
  pre="crop=iw:ih-76:0:76"
fi

filter=""; concat=""; i=0
for seg in ${=segments}; do
  a=${seg%%:*}; b=${seg##*:}
  filter+="[0:v]trim=$a:$b,setpts=PTS-STARTPTS[v$i];"
  concat+="[v$i]"
  if [[ -n $has_audio ]]; then
    filter+="[0:a]atrim=$a:$b,asetpts=PTS-STARTPTS[a$i];"
    concat+="[a$i]"
  fi
  (( i += 1 ))
done
if [[ -n $has_audio ]]; then
  filter+="${concat}concat=n=$i:v=1:a=1[vc][ac];[vc]$pre,scale=$width:-2[vo]"
  ffmpeg -v error -y -i "$in" -filter_complex "$filter" -map "[vo]" -map "[ac]" \
    -c:v libx264 -preset slow -crf 30 -pix_fmt yuv420p -c:a aac -b:a 80k -movflags +faststart "$out"
else
  filter+="${concat}concat=n=$i:v=1:a=0[vc];[vc]$pre,scale=$width:-2[vo]"
  ffmpeg -v error -y -i "$in" -filter_complex "$filter" -map "[vo]" \
    -c:v libx264 -preset slow -crf 30 -pix_fmt yuv420p -an -movflags +faststart "$out"
fi
ffmpeg -v error -y -ss "$poster" -i "$out" -frames:v 1 -q:v 4 "site/tours/$name.jpg"
printf "%s: %.0fs -> %.0fs, %s\n" "$name" "$duration" \
  "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")" "$(du -h "$out" | cut -f1)"
