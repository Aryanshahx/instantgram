#!/usr/bin/env bash
# Puts a song under a video on your computer, with exactly the command the app mirrors:
#   bash tools/merge_audio.sh video.mp4 song.m4a out.mp4
# (needs ffmpeg:  sudo apt install ffmpeg)
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: bash tools/merge_audio.sh video.mp4 song.m4a out.mp4"; exit 1; }
ffmpeg -y -i "$1" -i "$2" -map 0:v:0 -map 1:a:0 -c:v copy -c:a copy -t 30 -shortest -movflags +faststart "$3"
echo "Written: $3"
