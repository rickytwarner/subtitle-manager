#!/usr/bin/env bash
# whisper_batch.sh
# Batch-generate SRT subtitle files for MKV/MP4 videos using stable-ts (Whisper).
# Supports multiple target languages, inotify watch mode, and smart subtitle reuse.
#
# Operating modes (MODE):
#   watch     (default) — initial batch pass, then watch for new files via inotify
#   batch               — single pass over all media, then exit
#
# Subtitle strategy (SUBTITLE_STRATEGY):
#   smart     (default) — use existing subtitle text + align timing if found;
#                         fall back to full transcription if none found
#   transcribe          — always run full transcription regardless of existing files
#
# Designed to run inside Docker with a media directory mounted at /media.
# All paths and behaviour are configurable via environment variables — see README.md.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration — override any of these with -e at docker run / compose time
# ---------------------------------------------------------------------------
MEDIA_ROOT="${MEDIA_ROOT:-/media}"
SCAN_DIRS="${SCAN_DIRS:-.}"
MODE="${MODE:-watch}"
SUBTITLE_STRATEGY="${SUBTITLE_STRATEGY:-smart}"
WHISPER_LANGS="${WHISPER_LANGS:-en}"
STABLE_TS_BIN="${STABLE_TS_BIN:-stable-ts}"
STABLE_MODEL="${STABLE_MODEL:-medium}"
MODEL_DIR="${MODEL_DIR:-/root/.cache/whisper}"
LOG_FILE="${LOG_FILE:-}"

# Internal — used by cleanup() to terminate the inotify coprocess gracefully
_inotify_pid=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "WARNING: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# ---------------------------------------------------------------------------
# Signal handling and cleanup
#
# tini (PID 1 in the container) forwards SIGTERM to this script.
# The EXIT trap fires on any exit path — normal, error, or signal — so
# cleanup() always runs exactly once.
# ---------------------------------------------------------------------------
cleanup() {
    log "Shutting down — cleaning up..."

    # Stop the inotifywait coprocess if it's running
    if [ -n "$_inotify_pid" ]; then
        kill "$_inotify_pid" 2>/dev/null || true
        _inotify_pid=""
    fi

    # Kill any other background child processes
    jobs -p | xargs -r kill 2>/dev/null || true

    # Remove temp files from interrupted transcription/extraction runs
    rm -f /tmp/whisper_audio.*.wav \
          /tmp/whisper_audio.*.srt \
          /tmp/whisper_sub.*.srt  2>/dev/null || true

    # Remove health sentinel
    rm -f /tmp/.whisper_healthy 2>/dev/null || true

    log "Cleanup complete."
}

trap 'cleanup; exit 0'   TERM
trap 'cleanup; exit 130' INT
trap 'cleanup'           EXIT

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
require ffmpeg
require ffprobe
command -v "$STABLE_TS_BIN" >/dev/null 2>&1 \
    || die "stable-ts not found (STABLE_TS_BIN=$STABLE_TS_BIN)"
[ "$MODE" = "watch" ] && require inotifywait

mkdir -p "$MODEL_DIR"

# Parse language list — comma or space separated
IFS=',' read -ra _lang_raw <<< "$WHISPER_LANGS"
target_langs=()
for l in "${_lang_raw[@]}"; do
    for ll in $l; do
        ll="${ll// /}"
        [ -n "$ll" ] && target_langs+=("$ll")
    done
done
[ "${#target_langs[@]}" -gt 0 ] \
    || die "WHISPER_LANGS is empty — set at least one language code (e.g. en)"

# Validate SUBTITLE_STRATEGY
case "$SUBTITLE_STRATEGY" in
    smart|transcribe) ;;
    *) die "Unknown SUBTITLE_STRATEGY=$SUBTITLE_STRATEGY — must be 'smart' or 'transcribe'" ;;
esac

# Build validated scan directory list
scan_dirs=()
for d in $SCAN_DIRS; do
    full="$MEDIA_ROOT/$d"
    # Normalise: MEDIA_ROOT/. == MEDIA_ROOT
    [ "$d" = "." ] && full="$MEDIA_ROOT"
    if [ -d "$full" ]; then
        scan_dirs+=("$full")
    else
        warn "scan directory not found, skipping: $full"
    fi
done
[ "${#scan_dirs[@]}" -gt 0 ] \
    || die "No valid scan directories found under MEDIA_ROOT=$MEDIA_ROOT (SCAN_DIRS=$SCAN_DIRS)"

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Wait until a file's size stabilises (handles slow network copies or
# large files still being written by a download manager).
wait_for_stable() {
    local file="$1" prev_size=-1 curr_size
    log "Waiting for file to finish writing: $file"
    while true; do
        curr_size=$(stat -c%s "$file" 2>/dev/null || echo "-1")
        [ "$curr_size" = "$prev_size" ] && [ "$curr_size" != "-1" ] && break
        prev_size="$curr_size"
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Stream selection — audio
# ---------------------------------------------------------------------------
choose_audio_map() {
    local video="$1" target_lang="$2"
    local best_idx="" best_score="-999999"

    while IFS=',' read -r idx codec ch lang title; do
        lang="$(lc "${lang:-}")" ; title="$(lc "${title:-}")"
        local score=0
        local target_639_2
        case "$target_lang" in
            ja) target_639_2="jpn" ;;  en) target_639_2="eng" ;;
            zh) target_639_2="chi|zho|cmn" ;; ko) target_639_2="kor" ;;
            fr) target_639_2="fra|fre" ;;    de) target_639_2="ger|deu" ;;
            es) target_639_2="spa" ;;        pt) target_639_2="por" ;;
            *)  target_639_2="$target_lang" ;;
        esac
        echo "$lang" | grep -Eqi "^($target_639_2|$target_lang)$" && score=$((score+1000)) || true
        case "$target_lang" in
            ja) echo "$title" | grep -Eqi '(japanese|日本語|にほんご|(^|[^a-z])jp([^a-z]|$)|jpn)' \
                    && score=$((score+200)) || true ;;
            en) echo "$title" | grep -Eqi '(english|(^|[^a-z])en([^a-z]|$)|eng)' \
                    && score=$((score+200)) || true ;;
        esac
        echo "$title" | grep -Eqi '(commentary|コメンタリー|解説|director)' \
            && score=$((score-2000)) || true
        if echo "$ch" | grep -Eq '^[0-9]+$'; then
            [ "$ch" -ge 6 ] && score=$((score+20)) \
                || { [ "$ch" -ge 2 ] && score=$((score+10)); } || true
        fi
        echo "$idx" | grep -Eq '^[0-9]+$' && score=$((score-idx)) || true
        if [ "$score" -gt "$best_score" ]; then best_score="$score"; best_idx="$idx"; fi
    done < <(
        ffprobe -v error -select_streams a \
            -show_entries stream=index,codec_name,channels:stream_tags=language,title \
            -of csv=p=0 "$video" 2>/dev/null || true
    )
    [ -n "$best_idx" ] && printf "0:%s" "$best_idx" && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Stream selection — subtitles (text-based only)
# ---------------------------------------------------------------------------
choose_subtitle_map() {
    local video="$1" target_lang="$2"
    local best_idx="" best_score="-999999"

    while IFS=',' read -r idx codec lang title; do
        # Exclude image-based formats — they cannot be extracted to text
        case "$(lc "${codec:-}")" in
            pgssub|hdmv_pgs_subtitle|dvdsub|dvd_subtitle|dvbsub|vobsub|xsub)
                continue ;;
        esac

        lang="$(lc "${lang:-}")" ; title="$(lc "${title:-}")"
        local score=0
        local target_639_2
        case "$target_lang" in
            ja) target_639_2="jpn" ;;  en) target_639_2="eng" ;;
            zh) target_639_2="chi|zho|cmn" ;; ko) target_639_2="kor" ;;
            fr) target_639_2="fra|fre" ;;    de) target_639_2="ger|deu" ;;
            es) target_639_2="spa" ;;        pt) target_639_2="por" ;;
            *)  target_639_2="$target_lang" ;;
        esac
        echo "$lang" | grep -Eqi "^($target_639_2|$target_lang)$" && score=$((score+1000)) || true
        # Penalise signs-only / forced / karaoke tracks (incomplete dialogue coverage)
        echo "$title" | grep -Eqi '(sign|song|forced|caption|karaoke)' \
            && score=$((score-500)) || true
        echo "$idx" | grep -Eq '^[0-9]+$' && score=$((score-idx)) || true
        if [ "$score" -gt "$best_score" ]; then best_score="$score"; best_idx="$idx"; fi
    done < <(
        ffprobe -v error -select_streams s \
            -show_entries stream=index,codec_name:stream_tags=language,title \
            -of csv=p=0 "$video" 2>/dev/null || true
    )
    [ -n "$best_idx" ] && printf "0:%s" "$best_idx" && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Subtitle discovery — external files
# ---------------------------------------------------------------------------
find_external_sub() {
    local base="$1" lang="$2"
    local candidates=(
        "${base}.${lang}.srt"  "${base}.${lang}.ass"  "${base}.${lang}.ssa"
        "${base}.srt"          "${base}.ass"           "${base}.ssa"
    )
    for f in "${candidates[@]}"; do
        [ -s "$f" ] && printf '%s' "$f" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Subtitle text extraction (strips timing/tags for use with --align)
# ---------------------------------------------------------------------------
extract_sub_text() {
    local subfile="$1"
    local text=""
    case "$(lc "${subfile##*.}")" in
        srt)
            text=$(grep -v '^[0-9][0-9]*$' "$subfile" \
                     | grep -v '^[0-9][0-9]:[0-9][0-9]:[0-9][0-9],[0-9]' \
                     | grep -v '^$' \
                     | sed 's/<[^>]*>//g' \
                     | tr '\n' ' ' \
                     | sed 's/  */ /g; s/^ //; s/ $//')
            ;;
        ass|ssa)
            text=$(grep '^Dialogue:' "$subfile" \
                     | sed 's/^Dialogue:[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,//' \
                     | sed 's/{[^}]*}//g' \
                     | sed 's/\\N/ /g' \
                     | tr '\n' ' ' \
                     | sed 's/  */ /g; s/^ //; s/ $//')
            ;;
        *) return 1 ;;
    esac
    [ -n "$text" ] && printf 'text=%s' "$text" && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Audio extraction — shared between align and transcribe paths
# ---------------------------------------------------------------------------
extract_audio() {
    local video="$1" lang="$2" out_wav="$3"
    local amap=""
    amap="$(choose_audio_map "$video" "$lang")" || true
    [ -z "$amap" ] && { warn "[$lang] No matching audio track; using first stream"; amap="0:a:0"; }
    ffmpeg -nostdin -loglevel error -err_detect ignore_err -y \
        -i "$video" -map "$amap" \
        -vn -ac 1 -ar 16000 -c:a pcm_s16le \
        "$out_wav" </dev/null
}

# ---------------------------------------------------------------------------
# Fast path — align existing subtitle text to audio via Whisper forced alignment
#
# stable-ts --align takes plain text prefixed with "text=" and aligns it to
# the audio without running full speech recognition — typically 5–10× faster.
# Language is mandatory for this path.
# ---------------------------------------------------------------------------
align_existing() {
    local video="$1" sub_text="$2" lang="$3" output="$4"

    local tmpwav tmpsrt
    tmpwav="$(mktemp /tmp/whisper_audio.XXXXXX.wav)"
    tmpsrt="${tmpwav%.wav}.srt"

    if ! extract_audio "$video" "$lang" "$tmpwav"; then
        warn "[$lang] ffmpeg extraction failed during alignment"
        rm -f "$tmpwav" "$tmpsrt" 2>/dev/null || true
        return 1
    fi

    if ! "$STABLE_TS_BIN" "$tmpwav" \
            --align "$sub_text" \
            --language "$lang" \
            --model "$STABLE_MODEL" \
            --download_root "$MODEL_DIR" \
            -o "$tmpsrt" </dev/null; then
        rm -f "$tmpwav" "$tmpsrt" 2>/dev/null || true
        return 1
    fi

    if [ -s "$tmpsrt" ]; then
        mv "$tmpsrt" "$output"
        rm -f "$tmpwav" 2>/dev/null || true
        return 0
    fi

    rm -f "$tmpwav" "$tmpsrt" 2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------------------
# Slow path — full Whisper transcription
# ---------------------------------------------------------------------------
transcribe() {
    local video="$1" lang="$2" output="$3"

    local tmpwav tmpsrt
    tmpwav="$(mktemp /tmp/whisper_audio.XXXXXX.wav)"
    tmpsrt="${tmpwav%.wav}.srt"

    if ! extract_audio "$video" "$lang" "$tmpwav"; then
        warn "[$lang] ffmpeg extraction failed"
        rm -f "$tmpwav" "$tmpsrt" 2>/dev/null || true
        return 1
    fi

    if ! "$STABLE_TS_BIN" "$tmpwav" \
            --language "$lang" \
            --model    "$STABLE_MODEL" \
            --download_root "$MODEL_DIR" \
            --refine \
            -o "$tmpsrt" </dev/null; then
        warn "[$lang] stable-ts transcription failed"
        rm -f "$tmpwav" "$tmpsrt" 2>/dev/null || true
        return 1
    fi

    if [ -s "$tmpsrt" ]; then
        mv "$tmpsrt" "$output"
        rm -f "$tmpwav" 2>/dev/null || true
        return 0
    fi

    warn "[$lang] stable-ts produced an empty SRT"
    rm -f "$tmpwav" "$tmpsrt" 2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------------------
# Per-file, per-language processing
#
# Decision tree:
#   1. Output already exists          → skip (idempotent)
#   2. SUBTITLE_STRATEGY=smart
#      a. External sub found          → align (fast path)
#      b. Embedded text sub found     → extract + align (fast path)
#   3. Full transcription             → slow path
# ---------------------------------------------------------------------------
process_lang() {
    local video="$1" lang="$2"
    local base="${video%.*}"
    local output="${base}.${lang}.whisper.srt"

    if [ -s "$output" ]; then
        return 0
    fi

    if [ "$SUBTITLE_STRATEGY" = "smart" ]; then
        local sub_text="" tmp_extracted=""

        # Check for external subtitle file
        local ext_sub=""
        ext_sub="$(find_external_sub "$base" "$lang")" || true
        if [ -n "$ext_sub" ]; then
            sub_text="$(extract_sub_text "$ext_sub")" || true
            [ -n "$sub_text" ] && log "[$lang] Found external subtitle: $ext_sub"
        fi

        # Fall back to embedded subtitle stream
        if [ -z "$sub_text" ]; then
            local smap=""
            smap="$(choose_subtitle_map "$video" "$lang")" || true
            if [ -n "$smap" ]; then
                tmp_extracted="$(mktemp /tmp/whisper_sub.XXXXXX.srt)"
                if ffmpeg -nostdin -loglevel error -y \
                        -i "$video" -map "$smap" -c:s srt \
                        "$tmp_extracted" </dev/null \
                        && [ -s "$tmp_extracted" ]; then
                    sub_text="$(extract_sub_text "$tmp_extracted")" || true
                    [ -n "$sub_text" ] && log "[$lang] Found embedded subtitle stream: $smap"
                fi
                rm -f "$tmp_extracted" 2>/dev/null || true
            fi
        fi

        # Attempt alignment if we have usable text
        if [ -n "$sub_text" ]; then
            log "[$lang] Aligning existing subtitle to audio (fast path): $video"
            if align_existing "$video" "$sub_text" "$lang" "$output"; then
                log "[$lang] Created (aligned): $output"
                return 0
            fi
            warn "[$lang] Alignment failed — falling back to full transcription"
        fi
    fi

    log "[$lang] Transcribing: $video"
    if transcribe "$video" "$lang" "$output"; then
        log "[$lang] Created (transcribed): $output"
        return 0
    fi

    return 1
}

process_one() {
    local video="$1"
    for lang in "${target_langs[@]}"; do
        process_lang "$video" "$lang" || true
    done
}

# ---------------------------------------------------------------------------
# Batch mode — single pass, then exit
# ---------------------------------------------------------------------------
batch_mode() {
    log "===== whisper-docker batch started ====="
    log "Strategy: $SUBTITLE_STRATEGY | Model: $STABLE_MODEL | Languages: ${target_langs[*]}"
    log "Scanning: ${scan_dirs[*]}"

    local count=0
    while IFS= read -r -d '' file; do
        process_one "$file"
        count=$((count + 1))
    done < <(
        find "${scan_dirs[@]}" \
            -type f \( -iname "*.mkv" -o -iname "*.mp4" \) \
            -printf '%T@ %p\0' \
          | sort -z -rn \
          | sed -z 's/^[0-9.]* //'
    )

    log "===== Batch finished — $count file(s) evaluated ====="
}

# ---------------------------------------------------------------------------
# Watch mode — initial batch pass, then react to new files via inotify
#
# inotifywait runs as a coprocess so we hold its PID for clean shutdown.
# If it exits unexpectedly (filesystem error, unmount, etc.) the supervisor
# loop restarts it after a short delay rather than silently dying.
#
# NOTE: inotify is Linux-only and requires a locally-mounted filesystem.
#       It does NOT work over NFS or SMB/CIFS. Use MODE=batch for those.
# ---------------------------------------------------------------------------
watch_mode() {
    log "===== whisper-docker watcher started ====="
    log "Strategy: $SUBTITLE_STRATEGY | Model: $STABLE_MODEL | Languages: ${target_langs[*]}"
    log "Watching: ${scan_dirs[*]}"

    log "Running initial batch pass..."
    batch_mode

    log "Entering watch mode — listening for new files..."

    while true; do
        log "Starting inotifywait..."

        # Run inotifywait as a named coprocess so we can capture its PID
        # and terminate it cleanly on SIGTERM.
        coproc INOTIFY (
            exec inotifywait \
                --monitor \
                --recursive \
                --event close_write,moved_to \
                --format '%w%f' \
                "${scan_dirs[@]}" 2>/dev/null
        )
        _inotify_pid=$INOTIFY_PID

        # Read events from the coprocess until it exits
        while IFS= read -r -u "${INOTIFY[0]}" file; do
            case "$(lc "${file##*.}")" in mkv|mp4) ;; *) continue ;; esac
            wait_for_stable "$file"
            log "New file detected: $file"
            process_one "$file" || true
        done

        _inotify_pid=""
        warn "inotifywait exited unexpectedly — restarting in 10s"
        sleep 10
    done
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
run() {
    # Write health sentinel — used by Docker HEALTHCHECK
    touch /tmp/.whisper_healthy

    case "$MODE" in
        watch) watch_mode ;;
        batch) batch_mode ;;
        *) die "Unknown MODE=$MODE — must be 'watch' or 'batch'" ;;
    esac
}

if [ -n "${LOG_FILE:-}" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    run 2>&1 | tee -a "$LOG_FILE"
else
    run
fi
