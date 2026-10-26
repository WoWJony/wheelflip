#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$repo_root/output/promo"
mkdir -p "$output_dir"
command -v ffmpeg >/dev/null || { echo 'ffmpeg is required to encode the demo.' >&2; exit 1; }

swiftc -O "$repo_root/scripts/promo/main.swift" \
    "$repo_root/app/WheelFlip/FlipPolicy.swift" \
    "$repo_root/app/WheelFlip/ScrollFlip.swift" \
    -o "$output_dir/render-promo"
"$output_dir/render-promo" "$repo_root" "$output_dir"

for language in en zh; do
    ffmpeg -hide_banner -loglevel error -y -framerate 20 \
        -i "$output_dir/frames-$language/%04d.png" -map_metadata -1 \
        -c:v libx264 -crf 20 -pix_fmt yuv420p -movflags +faststart \
        "$output_dir/wheelflip-demo-$language.mp4"
    ffmpeg -hide_banner -loglevel error -y -i "$output_dir/wheelflip-demo-$language.mp4" \
        -filter_complex 'fps=10,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3' \
        -loop 0 -map_metadata -1 "$output_dir/demo-$language.gif"
done
echo "Rendered media: $output_dir"
