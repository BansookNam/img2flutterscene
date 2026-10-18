#!/bin/zsh
# Screenshot a model in the sculpt lab at one or more turntable angles and
# copy the PNGs out of the macOS sandbox.
#
#   lab_shot.sh <model> <name> [angles=0] [out_dir=.] [backdrop=dark] [layout=model] [elevation=12]
#
#   angles     comma list of model yaw in degrees: 0 front, 90 the model's
#              right side, 180 rear, 270 its left side — the azimuths
#              forge/stage4_review/turntable_gate.py expects
#   backdrop   dark | mid | light — pick one the model's edges contrast with
#              before silhouette scoring
#   layout     model (alone, for the gates) | side (beside the reference)
#
# One launch shoots every angle. The app writes into its own temp dir and
# prints `SHOT <path>` per frame; this copies each to <out_dir>/<name>_<angle>.png
# and prints the copies' paths.
set -e
cd "${0:A:h}/../lab"
model=$1 name=$2 angles=${3:-0} out=${4:-.} backdrop=${5:-dark} layout=${6:-model} elevation=${7:-12}
[[ -z $model || -z $name ]] && { print -u2 "usage: lab_shot.sh <model> <name> [angles] [out_dir] [backdrop] [layout] [elevation]"; exit 64; }
[[ $out != /* ]] && out=$OLDPWD/$out
log=$(timeout 300 flutter run -d macos \
  --dart-define=MODEL=$model --dart-define=SHOT=$name --dart-define=ANGLES=$angles \
  --dart-define=BACKDROP=$backdrop --dart-define=LAYOUT=$layout --dart-define=ELEVATION=$elevation 2>&1) || true
print -r -- "$log" | grep -i "error\|exception" | head -10
srcs=(${(f)"$(print -r -- "$log" | grep -o "SHOT /.*png" | cut -c6-)"})
[[ -z ${srcs[1]} ]] && { print -u2 "No screenshot taken (build failed?)"; exit 1; }
mkdir -p $out
for src in $srcs; do
  cp "$src" "$out/${src:t}"
  print "$out/${src:t}"
done
