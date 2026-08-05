#!/usr/bin/env bash
#
# mov2gif.sh — Batch convert .mov to GIF, simple and high quality.
#
# 1. ffmpeg -i input.mov output.gif      (direct conversion, full color)
# 2. gifsicle -O2 output.gif -o out.gif   (optimize file size, keep quality)
#
# Optional: prepend/append text title frames (e.g. "START", "END").
#
# Usage:
#   ./mov2gif.sh [options] <file.mov ...>
#   ./mov2gif.sh [options] -r <dir>        # all .mov in directory
#
# Options:
#   -w WIDTH   Scale to width px (height auto). Default: original size
#   -f FPS     Frame rate. Lower = smaller file. Default: original
#   -o DIR     Output directory. Default: same as input
#   -O         Optimize with gifsicle (smaller file, same quality)
#   -s TEXT    Start frame text. Default: "DEMO START". Use "" to disable.
#   -e TEXT    End frame text. Default: "DEMO END". Use "" to disable.
#   -d DUR     Duration of start/end frames in seconds. Default: 2
#   -x        Dry run — print commands only
#
# Examples:
#   ./mov2gif.sh recording.mov
#   ./mov2gif.sh -O -w 1200 *.mov
#   ./mov2gif.sh -r ~/Movies -o ~/Downloads/gifs
#   ./mov2gif.sh -s "DEMO START" -e "DEMO END" -O recording.mov
#
set -euo pipefail

FFMPEG="/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
FONT="/System/Library/Fonts/Supplemental/Arial.ttf"

WIDTH=""
FPS=""
OUTDIR=""
OPTIMIZE=false
START_TEXT="DEMO START"
END_TEXT="DEMO END"
FRAME_DUR=2
DRY_RUN=false
DIR_MODE=""
INPUTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w) WIDTH="$2"; shift 2 ;;
        -f) FPS="$2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -O) OPTIMIZE=true; shift ;;
        -s) START_TEXT="$2"; shift 2 ;;
        -e) END_TEXT="$2"; shift 2 ;;
        -d) FRAME_DUR="$2"; shift 2 ;;
        -x) DRY_RUN=true; shift ;;
        -r) DIR_MODE="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^$/s/^# \?//p' "$0"; exit 0 ;;
        -*) echo "Unknown: $1" >&2; exit 1 ;;
        *)  INPUTS+=("$1"); shift ;;
    esac
done

if [[ -n "$DIR_MODE" ]]; then
    shopt -s nullglob
    for f in "$DIR_MODE"/*.mov "$DIR_MODE"/*.MOV; do
        INPUTS+=("$f")
    done
    shopt -u nullglob
fi

[[ ${#INPUTS[@]} -eq 0 ]] && { echo "No input files." >&2; exit 1; }

if ! command -v "$FFMPEG" &>/dev/null; then
    echo "ffmpeg-full not found. Install: brew install ffmpeg-full" >&2
    exit 1
fi
command -v gifsicle &>/dev/null || { echo "gifsicle not found. Install: brew install gifsicle" >&2; exit 1; }

# Build vf filter string
VF=""
[[ -n "$FPS" ]] && VF="fps=$FPS"
[[ -n "$WIDTH" ]] && VF="${VF:+$VF,}scale=${WIDTH}:-1:flags=lanczos"

total=${#INPUTS[@]}
i=0
for f in "${INPUTS[@]}"; do
    i=$((i + 1))
    [[ ! -f "$f" ]] && { echo "[$i/$total] $(basename "$f") — not found, skipping" >&2; continue; }

    dir="$(cd "$(dirname "$f")" && pwd)"
    name="$(basename "${f%.*}")"
    out_dir="${OUTDIR:-$dir}"
    [[ -d "$out_dir" ]] || mkdir -p "$out_dir"
    out="${out_dir}/${name}.gif"
    tmp="$(mktemp -d)/mov2gif"

    # Get video dimensions and fps for matching title frames
    info="$($FFMPEG -hide_banner -i "$f" 2>&1 || true)"
    vid_dim="$(echo "$info" | grep -oE ', [0-9]+x[0-9]+,' | head -1 | tr -d ', ')"
    vid_w="${vid_dim%x*}"
    vid_h="${vid_dim#*x}"
    [[ -z "$vid_w" || -z "$vid_h" ]] && { vid_w=1920; vid_h=1080; }
    # Apply user width scaling
    [[ -n "$WIDTH" ]] && { vid_h=$((vid_h * WIDTH / vid_w)); vid_w="$WIDTH"; }

    parts=()

    # --- start title frame ---
    if [[ -n "$START_TEXT" ]]; then
        start_gif="${tmp}_start.gif"
        dt="drawtext=text='${START_TEXT}':fontfile=${FONT}:fontsize=$((vid_h/8)):fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2"
        cmd_start="$FFMPEG -y -hide_banner -loglevel error -f lavfi -i color=black:s=${vid_w}x${vid_h}:d=${FRAME_DUR} -vf \"$dt,fps=${FPS:-15}\" \"$start_gif\""
        echo "  + start frame: \"${START_TEXT}\""
        $DRY_RUN && echo "  $cmd_start" || eval "$cmd_start"
        parts+=("$start_gif")
    fi

    # --- main video ---
    cmd_main="$FFMPEG -y -hide_banner -loglevel error -i \"$f\""
    [[ -n "$VF" ]] && cmd_main+=" -vf \"$VF\""
    cmd_main+=" \"${tmp}_main.gif\""
    echo "[$i/$total] $(basename "$f") → $(basename "$out")"
    $DRY_RUN && echo "  $cmd_main" || eval "$cmd_main"
    parts+=("${tmp}_main.gif")

    # --- end title frame ---
    if [[ -n "$END_TEXT" ]]; then
        end_gif="${tmp}_end.gif"
        dt="drawtext=text='${END_TEXT}':fontfile=${FONT}:fontsize=$((vid_h/8)):fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2"
        cmd_end="$FFMPEG -y -hide_banner -loglevel error -f lavfi -i color=black:s=${vid_w}x${vid_h}:d=${FRAME_DUR} -vf \"$dt,fps=${FPS:-15}\" \"$end_gif\""
        echo "  + end frame: \"${END_TEXT}\""
        $DRY_RUN && echo "  $cmd_end" || eval "$cmd_end"
        parts+=("$end_gif")
    fi

    # --- concat parts ---
    if [[ ${#parts[@]} -gt 1 ]]; then
        concat_list="${tmp}_concat.txt"
        for p in "${parts[@]}"; do
            echo "file '$p'" >> "$concat_list"
        done
        cmd_concat="$FFMPEG -y -hide_banner -loglevel error -f concat -safe 0 -i \"$concat_list\" -copyts \"$out\""
        $DRY_RUN && echo "  $cmd_concat" || eval "$cmd_concat"
        rm -f "${parts[@]}" "$concat_list"
    else
        $DRY_RUN && echo "  mv \"${tmp}_main.gif\" \"$out\"" || mv "${tmp}_main.gif" "$out"
    fi

    # --- optimize ---
    if $OPTIMIZE; then
        echo "  optimizing…"
        $DRY_RUN && echo "  gifsicle -O2 \"$out\" -o \"$out\"" || { gifsicle -O2 "$out" -o "${out}.tmp" && mv "${out}.tmp" "$out"; }
    fi

    rmdir "$(dirname "$tmp")" 2>/dev/null || true
done

echo "done."