#!/usr/bin/env bash
# TV bloat re-encode: QSV HEVC for high-bitrate 1080p h264 episodes.
# Resumable (done list persists on the media volume), deadline-aware, and
# only replaces a file when the re-encode is meaningfully smaller and matches
# its duration.
set -uo pipefail

LIST=/config/files.txt
WORK=/media/tv/.transcode
DONE="$WORK/done.txt"
LOG="$WORK/run-$(date +%Y%m%d-%H%M).log"
FF=/usr/lib/jellyfin-ffmpeg/ffmpeg
FP=/usr/lib/jellyfin-ffmpeg/ffprobe
QUALITY="${QUALITY:-20}"
DEADLINE="${DEADLINE:-0545}"
MARGIN="${MARGIN:-10}"   # require at least this % smaller

mkdir -p "$WORK"; touch "$DONE"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

log "=== run start quality=$QUALITY deadline=$DEADLINE pid=$$ ==="
ok=0; skip=0; fail=0
while IFS= read -r SRC; do
  [ -z "$SRC" ] && continue
  if [ ! -f "$SRC" ]; then log "MISSING  $SRC"; continue; fi
  if grep -qxF "$SRC" "$DONE"; then continue; fi

  now=$(date +%H%M)
  if [ "$now" -ge "$DEADLINE" ]; then log "DEADLINE $now reached — stopping (processed $ok this run)"; break; fi

  codec=$("$FP" -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$SRC" 2>/dev/null)
  if [ "$codec" != "h264" ]; then
    echo "$SRC" >> "$DONE"; skip=$((skip+1)); log "SKIP codec=$codec $(basename "$SRC")"; continue
  fi

  sinc=$(stat -c %s "$SRC")
  sdur=$("$FP" -v error -show_entries format=duration -of default=nw=1:nk=1 "$SRC" 2>/dev/null)
  base="${SRC%.*}"
  TMP="$WORK/.enc-$$.mkv"
  t0=$(date +%s)
  log "ENC  $(basename "$SRC")"
  if "$FF" -y -nostdin -hide_banner -loglevel error \
        -init_hw_device qsv=hw:/dev/dri/renderD128 \
        -hwaccel qsv -hwaccel_output_format qsv -i "$SRC" \
        -map 0:v:0 -map "0:a:0?" -map "0:s?" \
        -c:v hevc_qsv -preset veryfast -global_quality:v "$QUALITY" \
        -c:a aac -b:a 256k -c:s copy \
        -f matroska "$TMP" 2>>"$WORK/ffmpeg.err"; then
    oinc=$(stat -c %s "$TMP")
    odur=$("$FP" -v error -show_entries format=duration -of default=nw=1:nk=1 "$TMP" 2>/dev/null)
    dclose=$(awk -v a="$sdur" -v b="$odur" 'BEGIN{d=a-b; if(d<0)d=-d; print (d<=2)?"yes":"no"}')
    small_enough=no
    [ "$oinc" -lt $((sinc*(100-MARGIN)/100)) ] && small_enough=yes
    secs=$(( $(date +%s) - t0 ))
    if [ "$dclose" = yes ] && [ "$small_enough" = yes ]; then
      dir=$(dirname "$SRC"); bn=$(basename "$SRC")
      # rename to reflect the new codec: x264/h264/XviD/DivX -> x265,
      # append [x265] if no codec token is present, and normalise to .mkv
      newbn=$(printf '%s' "$bn" | sed -E 's/\[(x264|h264|h\.264|xvid|divx)\]/[x265]/gI')
      [ "$newbn" = "$bn" ] && newbn="${bn%.*} [x265].${bn##*.}"
      DEST="$dir/${newbn%.*}.mkv"
      mv -f "$TMP" "$DEST"
      [ "$DEST" != "$SRC" ] && rm -f "$SRC"
      save=$(( (sinc-oinc)/1048576 ))
      ok=$((ok+1))
      echo "$SRC" >> "$DONE"
      log "OK   saved ${save}MiB  ${secs}s  $(basename "$DEST")"
    else
      rm -f "$TMP"
      echo "$SRC" >> "$DONE"
      skip=$((skip+1))
      log "KEEP (dur=$dclose smaller=$small_enough) ${secs}s $(basename "$SRC")"
    fi
  else
    rm -f "$TMP"
    fail=$((fail+1))
    log "FAIL $(basename "$SRC")"
  fi
done < "$LIST"
log "=== run end ok=$ok kept=$skip failed=$fail ==="