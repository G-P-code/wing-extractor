#!/bin/bash
#
# WING multichannel tracks extractor  —  version 2.1
# macOS bash 3.2 compatible
#
# Optimisations vs v1:
#   - Single ffmpeg pass writes final named files directly (no temp channel files)
#   - Multi-chunk recordings piped concat→extract (no all.wav temp file)
#   - Duration reused from chunk sum — no extra ffprobe after concat
#   - Stereo pairs built inline via join filter in the same single pass
#   - Added optional channel selection for extraction
#   - Allow comments # in names file
#
# tracks.txt must be placed in the same directory as this script.
#

cd "$(dirname "$0")" || exit 1

# ------------------------------------------------------------
# Version info
# ------------------------------------------------------------

VERSION="2.1"
SCRIPT_NAME="WING multichannel tracks extractor"

# ------------------------------------------------------------
# Helper functions (defined early)
# ------------------------------------------------------------

usage() {
    echo
    echo "Usage:"
    echo "  ./$(basename "$0") -i input_dir -o output_dir -c card_nr [-n tracks.txt] [-f ffmpeg_path] [-s channels] [--dry-run]"
    echo
    echo "  -i  Input directory (default: SD card X_LIVE folder)"
    echo "  -o  Output directory for extracted WAV tracks"
    echo "  -c  Card number: 1 or 2  (track offset: 1=ch01-32, 2=ch33-64)"
    echo "  -n  Track names file (default: tracks.txt next to this script)"
    echo "  -f  Optional path to directory containing ffmpeg/ffprobe"
    echo "  -s  Optional channel selection (comma-separated, e.g. 1,3,5-8)"
    echo "  --dry-run  Show what would be done without actually extracting"
    echo "  -v, --version  Show version information"
    echo
}

show_version() {
    echo "$SCRIPT_NAME v$VERSION"
    echo "macOS bash 3.2 compatible"
    echo "Optimised for Behringer WING SD card recordings"
    echo
    exit 0
}

sanitize_name() {
    local n="$1"
    n="${n//\//-}"; n="${n//\\/-}"; n="${n//:/-}"
    n="${n//\*/_}"; n="${n//\?/_}"; n="${n//\"/_}"
    n="${n//\</_}"; n="${n//\>/_}"; n="${n//|/_}"
    printf '%s' "$n"
}

format_duration() {
    local secs="$1"
    printf "%02d:%02d:%02d" \
        "$(( secs / 3600 ))" \
        "$(( (secs % 3600) / 60 ))" \
        "$(( secs % 60 ))"
}

progress_pipe() {
    local total="$1"
    [ "$total" -le 0 ] 2>/dev/null && total=1
    awk -v total="$total" '
        BEGIN { bar=30 }
        {
            split($0,a,"=")
            if (a[1]=="out_time_ms") {
                t = int(a[2]/1000000)
                p = int(t*100/total)
                if (p > 100) p = 100
                f = int(p*bar/100)
                printf "\r  ["
                for (i=0; i<f; i++) printf "#"
                for (i=f; i<bar; i++) printf " "
                printf "] %3d%%", p
                fflush()
            }
        }
        END { print "" }
    '
}

ask_exit() {
    echo
    echo -en "${YELLOW}Exit and close terminal? ${GRAY}[${GREEN}Y${GRAY}/${NC}n${GRAY}]${YELLOW}:${NC} "
    read -r -n1 -t 10 ans || ans=""
    echo
    case "$ans" in
        [nN])
            [ "$FINDER_LAUNCH" -eq 1 ] && exec $SHELL
            ;;
        *)
            _cnt=$(w -h | grep -c "^$(whoami) *s")
            if [ "$_cnt" -gt 1 ]; then
                osascript -e 'tell application "Terminal" to close front window saving no' &
            else
                osascript -e 'tell application "Terminal" to quit' &
            fi
            exit 0
            ;;
    esac
}

# ------------------------------------------------------------
# Finder launch detection  (double-click, no args, low SHLVL)
# ------------------------------------------------------------

FINDER_LAUNCH=0
[ "$#" -eq 0 ] && [ "$SHLVL" -le 2 ] && FINDER_LAUNCH=1

if [ "$FINDER_LAUNCH" -eq 1 ]; then
    printf '\033[97;40m'
    clear 2>/dev/null || true
    echo -e "\033[1;96m$SCRIPT_NAME v$VERSION\033[97;40m"
    echo
    usage
    exec $SHELL
fi

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

NC='\033[97;40m'
RED='\033[1;91m'
YELLOW='\033[1;93m'
GREEN='\033[1;92m'
CYAN='\033[1;96m'
GRAY='\033[1;90m'
MAGENTA='\033[1;95m'

printf '\033[97;40m'
clear 2>/dev/null || true

# ------------------------------------------------------------
# Terminal state
# ------------------------------------------------------------

SAVED_STTY=$(stty -g 2>/dev/null || true)
WORK_DIR=""

# shellcheck disable=SC2329
cleanup() {
    [ -n "$SAVED_STTY" ] && stty "$SAVED_STTY" 2>/dev/null || true
    printf '\033[0m'
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
}
trap 'cleanup' EXIT INT TERM

# ------------------------------------------------------------
# Defaults
# ------------------------------------------------------------

FFMPEG=ffmpeg
FFPROBE=ffprobe
INPUT_DIR="/Volumes/NO NAME/X_LIVE"
NAMES_FILE=tracks.txt
CHANNEL_SELECT=""
DRY_RUN=0

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        -i|-o|-n|-c|-f|-s)
            [ -z "$2" ] || [ "${2#-}" != "$2" ] && {
                echo -e "${RED}Error: ${NC}$1 ${MAGENTA}requires an argument${NC}"; usage; exit 1; }
            ;;
    esac
    case "$1" in
        -i) INPUT_DIR="$2"; shift 2 ;;
        -o) OUTPUT_DIR="$2"; shift 2 ;;
        -n) NAMES_FILE="$2"; shift 2 ;;
        -c) CARD="$2"; shift 2 ;;
        -f) FFMPEG="$2/ffmpeg"; FFPROBE="$2/ffprobe"; shift 2 ;;
        -s) CHANNEL_SELECT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -v|--version) show_version ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}Error: ${MAGENTA}unknown option ${NC}$1"; usage; exit 1 ;;
    esac
done

# ------------------------------------------------------------
# Parse channel selection
# ------------------------------------------------------------

SELECTED_CHANNELS=()
if [ -n "$CHANNEL_SELECT" ]; then
    IFS=',' read -r -a RANGES <<< "$CHANNEL_SELECT"
    for range in "${RANGES[@]}"; do
        range="${range// /}"
        _lo=$(echo "$range" | sed -n 's/^\([0-9][0-9]*\)-\([0-9][0-9]*\)$/\1/p')
        _hi=$(echo "$range" | sed -n 's/^\([0-9][0-9]*\)-\([0-9][0-9]*\)$/\2/p')
        if [ -n "$_lo" ] && [ -n "$_hi" ]; then
            c="$_lo"
            while [ "$c" -le "$_hi" ]; do
                SELECTED_CHANNELS+=("$c")
                c=$(( c + 1 ))
            done
        else
            case "$range" in
                *[!0-9]*|"") ;;
                *) SELECTED_CHANNELS+=("$range") ;;
            esac
        fi
    done
    # shellcheck disable=SC2207
    SELECTED_CHANNELS=($(printf "%s\n" "${SELECTED_CHANNELS[@]}" | sort -nu))
fi

# ------------------------------------------------------------
# Validate arguments
# ------------------------------------------------------------

_err=0
[ -z "$INPUT_DIR"  ] && { echo -e "${RED}Error: ${NC}-i ${MAGENTA}input_dir required${NC}";  _err=1; }
[ -z "$OUTPUT_DIR" ] && { echo -e "${RED}Error: ${NC}-o ${MAGENTA}output_dir required${NC}"; _err=1; }
[ -z "$CARD"       ] && { echo -e "${RED}Error: ${NC}-c ${MAGENTA}card_nr required${NC}";    _err=1; }
[ "$_err" -eq 1 ]  && { usage; exit 1; }

# Expand OUTPUT_DIR to full path early — before any checks or prompts use it.
# If it exists: resolve via cd. If not: resolve existing parent + basename.
if [ -d "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
elif [ -n "$OUTPUT_DIR" ]; then
    _op="$(dirname "$OUTPUT_DIR")"
    _ob="$(basename "$OUTPUT_DIR")"
    _op_real="$(cd "$_op" 2>/dev/null && pwd)"
    [ -n "$_op_real" ] && OUTPUT_DIR="$_op_real/$_ob"
fi

[ "$CARD" != "1" ] && [ "$CARD" != "2" ] && {
    echo -e "${RED}Error: ${NC}-c ${MAGENTA}must be ${NC}1 ${MAGENTA}or ${NC}2"; exit 1; }

[ ! -d "$INPUT_DIR" ] && {
    echo -e "${RED}Error: ${MAGENTA}input folder does not exist: \n${NC}$INPUT_DIR\n"; exit 1; }

INPUT_DIR_REAL="$(cd "$INPUT_DIR" 2>/dev/null && pwd)"
# Check output is not the same as, or nested inside, the input directory.
# Resolve OUTPUT_DIR via its first existing ancestor to handle not-yet-created paths.
if [ -n "$OUTPUT_DIR" ] && [ -n "$INPUT_DIR_REAL" ]; then
    _out_check="$OUTPUT_DIR"
    while [ -n "$_out_check" ] && [ "$_out_check" != "/" ]; do
        if [ -d "$_out_check" ]; then
            _out_real="$(cd "$_out_check" 2>/dev/null && pwd)"
            break
        fi
        _out_check="$(dirname "$_out_check")"
    done
    _out_real="${_out_real:-/}"
    # Fail if output resolves to input dir, or if input dir is a prefix of output
    case "${_out_real}/" in
        "${INPUT_DIR_REAL}/"*)
            echo -e "${RED}Error: ${MAGENTA}output directory cannot be the same as or nested inside input directory${NC}"
            echo -e "  Input:  $INPUT_DIR_REAL"
            echo -e "  Output: $OUTPUT_DIR"
            exit 1
            ;;
    esac
fi

[ ! -f "$NAMES_FILE" ] && {
    echo -e "${YELLOW}Info:${NC} names file not found: \n${MAGENTA}$NAMES_FILE ${NC}\ntracks will use fallback names (Track01, Track02 ...)\n"
    NAMES_FILE=""
}

command -v "$FFMPEG"  >/dev/null 2>&1 || {
    echo -e "${RED}Error: ${MAGENTA}ffmpeg not found: \n${NC}$FFMPEG\n"; exit 1; }

command -v "$FFPROBE" >/dev/null 2>&1 || {
    echo -e "${RED}Error: ${MAGENTA}ffprobe not found: \n${NC}$FFPROBE\n"; exit 1; }

INPUT_DIR="$(cd "$INPUT_DIR" && pwd)"

TRACK_OFFSET=0
[ "$CARD" = "2" ] && TRACK_OFFSET=32

WORK_DIR=$(mktemp -d)
ERR_LOG="$WORK_DIR/errors.log"
true > "$ERR_LOG"

# ------------------------------------------------------------
# Dry run mode
# ------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${CYAN}============================================${NC}"
    echo -e "${GREEN}DRY RUN MODE${NC} - no files will be extracted"
    echo -e "${CYAN}============================================${NC}"
    echo
fi

# ------------------------------------------------------------
# Load track names (optional)
# ------------------------------------------------------------

TRACK_NAMES=()
if [ -n "$NAMES_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        TRACK_NAMES+=("$line")
    done < "$NAMES_FILE"
fi

# ------------------------------------------------------------
# Find recording folders
# ------------------------------------------------------------

echo -e "${CYAN}Reading WING card ${NC}$CARD ${CYAN}..."

RECORD_DIRS=()
while IFS= read -r -d '' d; do
    RECORD_DIRS+=("$d")
done < <(find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

SELECTED_DIRS=()

if [ ${#RECORD_DIRS[@]} -eq 0 ]; then

    SELECTED_DIRS=("$INPUT_DIR")

else

    echo -e "${GREEN}Available recordings:${NC}"
    echo
    i=1
    for d in "${RECORD_DIRS[@]}"; do
        ts=$(stat -f "%SB" -t "%Y-%m-%d %H:%M:%S" "$d")

        wav_files=()
        while IFS= read -r f; do
            wav_files+=("$f")
        done < <(find "$d" -maxdepth 1 -type f -iname "*.WAV" | sort)
        wav_count=${#wav_files[@]}
        rec_secs=0
        if [ "$wav_count" -gt 0 ]; then
            first_dur=$(
                "$FFPROBE" -v error -show_entries format=duration \
                    -of csv=p=0 "${wav_files[0]}" 2>/dev/null \
                | awk '{printf "%d", $1+0}'
            )
            [ -z "$first_dur" ] && first_dur=0
            if [ "$wav_count" -eq 1 ]; then
                rec_secs="$first_dur"
            else
                last_dur=$(
                    "$FFPROBE" -v error -show_entries format=duration \
                        -of csv=p=0 "${wav_files[$((wav_count-1))]}" 2>/dev/null \
                    | awk '{printf "%d", $1+0}'
                )
                [ -z "$last_dur" ] && last_dur=0
                rec_secs=$(( first_dur * (wav_count - 1) + last_dur ))
            fi
        fi

        rec_len=$(format_duration "$rec_secs")
        printf " %2d${GRAY})${NC} %-15s ${GRAY}%s${NC}  (%s)\n" \
            "$i" "$(basename "$d")" "$rec_len" "$ts"
        i=$(( i + 1 ))
    done

    echo
    echo -e "  a${GRAY})${NC} process ALL"
    echo
    echo -e "  ${GRAY}Enter number(s) separated by commas, e.g. ${NC}1,3${GRAY} or ${NC}a${GRAY} for all${NC}"
    echo -en "${YELLOW}Selection:${NC} "
    read -r sel

    if echo "$sel" | grep -qiE '^[aA]$'; then
        SELECTED_DIRS=("${RECORD_DIRS[@]}")
    else
        IFS=',' read -r -a IDX <<< "$sel"
        for idx in "${IDX[@]}"; do
            idx="${idx// /}"
            case "$idx" in ''|*[!0-9]*) continue ;; esac
            if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#RECORD_DIRS[@]}" ]; then
                echo -e "${YELLOW}  Warning:${NC} $idx out of range — skipped"
                continue
            fi
            dir="${RECORD_DIRS[$(( idx - 1 ))]}"
            [ -d "$dir" ] && SELECTED_DIRS+=("$dir")
        done
    fi

fi

if [ ${#SELECTED_DIRS[@]} -eq 0 ]; then
    echo
    echo -e "${RED}No valid directories selected.${NC}"
    ask_exit
    exit 1
fi

# ------------------------------------------------------------
# Output folder — created only after selection is confirmed
# ------------------------------------------------------------

if [ ! -d "$OUTPUT_DIR" ]; then
    echo
    echo -en "${RED}Output folder missing. ${NC}\n$OUTPUT_DIR\n${YELLOW}Create? ${GRAY}[${GREEN}Y${GRAY}/${NC}n${GRAY}]${YELLOW}:${NC} "
    read -r -n1 ans; echo
    case "$ans" in [nN]) ask_exit; exit 0 ;; esac
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${GRAY}  [DRY RUN] Would create directory: $OUTPUT_DIR${NC}"
    else
        mkdir -p "$OUTPUT_DIR"
    fi
fi

TOTAL_DIRS=${#SELECTED_DIRS[@]}
CURRENT_DIR=0
GRAND_MONO=0
GRAND_STEREO=0
GRAND_FAILED=0

# ============================================================
# PROCESS EACH RECORDING
# ============================================================

for CURRENT_INPUT_DIR in "${SELECTED_DIRS[@]}"; do

    CURRENT_DIR=$(( CURRENT_DIR + 1 ))
    REC_NAME="$(basename "$CURRENT_INPUT_DIR")"
    OUT_REC_DIR="$OUTPUT_DIR/$REC_NAME"

    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$OUT_REC_DIR"
    fi



    echo
    echo -e "${CYAN}============================================"
    echo -e "  Processing: ${NC}$REC_NAME${GRAY} ($CURRENT_DIR of $TOTAL_DIRS)"
    [ "$DRY_RUN" -eq 1 ] && echo -e "  ${GRAY}[DRY RUN MODE]${NC}"
    echo -e "${CYAN}============================================${NC}"

    # ----------------------------------------------------------
    # Collect WAV chunks
    # ----------------------------------------------------------

    CHUNKS=()
    while IFS= read -r -d '' f; do
        [ -f "$f" ] && CHUNKS+=("$f")
    done < <(find "$CURRENT_INPUT_DIR" -maxdepth 1 -type f -iname "*.WAV" -print0 | sort -z)

    if [ ${#CHUNKS[@]} -eq 0 ]; then
        echo -e "${RED}  No WAV files found — skipping.${NC}"
        continue
    fi

    FIRST_CHUNK="${CHUNKS[0]}"

    # ----------------------------------------------------------
    # Probe channel count from first chunk
    # ----------------------------------------------------------

    CHANNELS=$(
        "$FFPROBE" -v error \
            -select_streams a:0 \
            -show_entries stream=channels \
            -of csv=p=0 \
            "$FIRST_CHUNK" 2>>"$ERR_LOG"
    )

    if [ -z "$CHANNELS" ] || [ "$CHANNELS" -eq 0 ] 2>/dev/null; then
        echo -e "${RED}  Could not detect channels — skipping.${NC}"
        continue
    fi

    echo -e "${GREEN}  Detected ${NC}$CHANNELS${GREEN} channels${NC}"

    # Sample rate consistency check across chunks
    if [ ${#CHUNKS[@]} -gt 1 ]; then
        REF_RATE=$(
            "$FFPROBE" -v error -select_streams a:0 \
                -show_entries stream=sample_rate -of csv=p=0 \
                "$FIRST_CHUNK" 2>>"$ERR_LOG"
        )
        for f in "${CHUNKS[@]}"; do
            rate=$(
                "$FFPROBE" -v error -select_streams a:0 \
                    -show_entries stream=sample_rate -of csv=p=0 \
                    "$f" 2>>"$ERR_LOG"
            )
            if [ "$rate" != "$REF_RATE" ]; then
                echo -e "${YELLOW}  Warning:${NC} sample rate mismatch in ${MAGENTA}$(basename "$f") ${NC}(${rate} vs ${REF_RATE} Hz)"
            fi
        done
    fi

    # Track names count check
    NEEDED=$(( CHANNELS + TRACK_OFFSET ))
    if [ ${#TRACK_NAMES[@]} -lt "$NEEDED" ]; then
        echo -e "${YELLOW}  Warning:${MAGENTA} tracks.txt ${NC}has ${MAGENTA}${#TRACK_NAMES[@]} ${NC}entries, need ${MAGENTA}$NEEDED${NC}"
    fi

    # Disk space check (skip during dry run — output dir may not exist yet)
    if [ "$DRY_RUN" -eq 0 ]; then
        REC_SIZE=$(du -sk "$CURRENT_INPUT_DIR" 2>/dev/null | awk '{print $1}')
        AVAIL=$(df -k "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2{print $4}')
        if [ -n "$REC_SIZE" ] && [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$REC_SIZE" ]; then
            echo -e "${YELLOW}  Warning:${NC} low disk space (need ~${REC_SIZE}K, have ${AVAIL}K)"
        fi
    fi

    # ----------------------------------------------------------
    # Apply channel selection if specified
    # ----------------------------------------------------------

    PROCESS_CHANNELS=()
    if [ ${#SELECTED_CHANNELS[@]} -gt 0 ]; then
        for ch in "${SELECTED_CHANNELS[@]}"; do
            ch_idx=$(( ch - 1 ))
            if [ "$ch_idx" -ge 0 ] && [ "$ch_idx" -lt "$CHANNELS" ]; then
                PROCESS_CHANNELS+=("$ch_idx")
            else
                echo -e "${YELLOW}  Warning:${NC} channel ${MAGENTA}$ch ${NC}out of range ${MAGENTA}(1-$CHANNELS) ${NC}— skipped"
            fi
        done
        echo -e "${GREEN}  Selected ${NC}${#PROCESS_CHANNELS[@]}${GREEN} channels for extraction${NC}"
    else
        c=0
        while [ "$c" -lt "$CHANNELS" ]; do
            PROCESS_CHANNELS+=("$c")
            c=$(( c + 1 ))
        done
    fi

    # ----------------------------------------------------------
    # Build filter + output map
    # ----------------------------------------------------------

    echo -e "${CYAN}  Building track map ...${NC}"

    FILTER=""
    MAPS=()
    USED_LIST=" "
    REC_MONO=0
    REC_STEREO=0
    REC_FAILED=0

    for i in "${PROCESS_CHANNELS[@]}"; do

        if echo "$USED_LIST" | grep -qw "$i"; then
            continue
        fi

        track_no=$(printf "%02d" $(( i + 1 + TRACK_OFFSET )))
        raw_name="${TRACK_NAMES[$(( i + TRACK_OFFSET ))]}"
        [ -z "$raw_name" ] && raw_name="Track${track_no}"
        name="$(sanitize_name "$raw_name")"

        # ---- Stereo pair: Name.L + Name.R ----
        if echo "$name" | grep -q '\.L$'; then
            base="${name%.L}"
            next_i=$(( i + 1 ))
            next_in_list=0
            for _ch in "${PROCESS_CHANNELS[@]}"; do
                [ "$_ch" -eq "$next_i" ] && next_in_list=1 && break
            done
            if [ "$next_i" -lt "$CHANNELS" ] && [ "$next_in_list" -eq 1 ]; then
                next_name="$(sanitize_name "${TRACK_NAMES[$(( next_i + TRACK_OFFSET ))]:-}")"
                if [ "$next_name" = "${base}.R" ]; then
                    left_no=$(printf "%02d" $(( i + 1 + TRACK_OFFSET )))
                    right_no=$(printf "%02d" $(( i + 2 + TRACK_OFFSET )))
                    out="$OUT_REC_DIR/${left_no}_${right_no}-${base}.wav"
                    if [ "$DRY_RUN" -eq 0 ]; then
                        FILTER="${FILTER}[0:a]pan=mono|c0=c${i}[l${i}];"
                        FILTER="${FILTER}[0:a]pan=mono|c0=c${next_i}[r${i}];"
                        FILTER="${FILTER}[l${i}][r${i}]join=inputs=2:channel_layout=stereo[s${i}];"
                        MAPS+=(-map "[s${i}]" -c:a pcm_s24le "$out")
                    fi
                    printf "${GRAY}  %-6s${NC}  %s_%s-%s" "stereo" "$left_no" "$right_no" "$base"
                    [ "$DRY_RUN" -eq 1 ] && printf "%b\n" "${GRAY} [DRY RUN]${NC}" || printf "\n"
                    REC_STEREO=$(( REC_STEREO + 1 ))
                    USED_LIST="$USED_LIST $i $next_i "
                    continue
                fi
            fi
        fi

        # ---- Standalone .R ----
        if echo "$name" | grep -q '\.R$'; then
            base="${name%.R}"
            out="$OUT_REC_DIR/${track_no}-${base}.R.wav"
            if [ "$DRY_RUN" -eq 0 ]; then
                FILTER="${FILTER}[0:a]pan=mono|c0=c${i}[a${i}];"
                MAPS+=(-map "[a${i}]" -c:a pcm_s24le "$out")
            fi
            printf "${GRAY}  %-6s${NC}  %s-%s" "mono.R" "$track_no" "${base}.R"
            [ "$DRY_RUN" -eq 1 ] && printf "%b\n" "${GRAY} [DRY RUN]${NC}" || printf "\n"
            REC_MONO=$(( REC_MONO + 1 ))
            continue
        fi

        # ---- Standalone .L ----
        if echo "$name" | grep -q '\.L$'; then
            base="${name%.L}"
            out="$OUT_REC_DIR/${track_no}-${base}.L.wav"
            if [ "$DRY_RUN" -eq 0 ]; then
                FILTER="${FILTER}[0:a]pan=mono|c0=c${i}[a${i}];"
                MAPS+=(-map "[a${i}]" -c:a pcm_s24le "$out")
            fi
            printf "${GRAY}  %-6s${NC}  %s-%s" "mono.L" "$track_no" "${base}.L"
            [ "$DRY_RUN" -eq 1 ] && printf "%b\n" "${GRAY} [DRY RUN]${NC}" || printf "\n"
            REC_MONO=$(( REC_MONO + 1 ))
            continue
        fi

        # ---- Standard mono ----
        out="$OUT_REC_DIR/${track_no}-${name}.wav"
        if [ "$DRY_RUN" -eq 0 ]; then
            FILTER="${FILTER}[0:a]pan=mono|c0=c${i}[a${i}];"
            MAPS+=(-map "[a${i}]" -c:a pcm_s24le "$out")
        fi
        printf "${GRAY}  %-6s${NC}  %s-%s" "mono" "$track_no" "$name"
        [ "$DRY_RUN" -eq 1 ] && printf "%b\n" "${GRAY} [DRY RUN]${NC}" || printf "\n"
        REC_MONO=$(( REC_MONO + 1 ))

    done

    if [ "$DRY_RUN" -eq 0 ]; then
        FILTER="${FILTER%;}"
        if [ -z "$FILTER" ]; then
            echo -e "${YELLOW}  Warning:${NC} no channels selected for extraction"
            continue
        fi

        # Check if any output files from this recording already exist
        _conflicts=0
        for _arg in "${MAPS[@]}"; do
            case "$_arg" in *.wav) [ -f "$_arg" ] && _conflicts=$(( _conflicts + 1 )) ;; esac
        done
        if [ "$_conflicts" -gt 0 ]; then
            echo
            echo -e "${RED}Output folder already contains ${NC}$_conflicts${YELLOW} matching${RED} WAV file(s):\n${NC}$OUT_REC_DIR"
            echo -en "\n${YELLOW}Overwrite? ${GRAY}[${NC}y${GRAY}/${GREEN}N${GRAY}]${YELLOW}:${NC} "
            read -r -n1 ans; echo
            case "$ans" in [yY]) ;; *) echo -e "${GRAY}  Skipping $REC_NAME${NC}"; continue ;; esac
        fi
    fi

    # ----------------------------------------------------------
    # Fast duration — probe only first and last chunk
    # ----------------------------------------------------------

    CHUNK_COUNT=${#CHUNKS[@]}
    FIRST_DUR=$(
        "$FFPROBE" -v error -show_entries format=duration \
            -of csv=p=0 "${CHUNKS[0]}" 2>>"$ERR_LOG" \
        | awk '{printf "%d", $1+0}'
    )
    [ -z "$FIRST_DUR" ] && FIRST_DUR=0

    if [ "$CHUNK_COUNT" -eq 1 ]; then
        DUR="$FIRST_DUR"
    else
        LAST_DUR=$(
            "$FFPROBE" -v error -show_entries format=duration \
                -of csv=p=0 "${CHUNKS[$(( CHUNK_COUNT - 1 ))]}" 2>>"$ERR_LOG" \
            | awk '{printf "%d", $1+0}'
        )
        [ -z "$LAST_DUR" ] && LAST_DUR=0
        DUR=$(( FIRST_DUR * (CHUNK_COUNT - 1) + LAST_DUR ))
    fi
    [ -z "$DUR" ] || [ "$DUR" -le 0 ] 2>/dev/null && DUR=1

    echo -e "\n${GREEN}  Recording length: ${NC}$(format_duration "$DUR")"

    # ----------------------------------------------------------
    # Dry run — show summary and skip extraction
    # ----------------------------------------------------------

    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${CYAN}  [DRY RUN] Would extract ${NC}${#PROCESS_CHANNELS[@]}${CYAN} channels to:${NC}"
        echo -e "  ${GRAY}  $OUT_REC_DIR${NC}"
        echo
        echo -e "${GREEN}  [DRY RUN] Complete - no files written.${NC}"
        GRAND_MONO=$(( GRAND_MONO + REC_MONO ))
        GRAND_STEREO=$(( GRAND_STEREO + REC_STEREO ))
        continue
    fi

    # ----------------------------------------------------------
    # Single ffmpeg pass — extract + name in one shot
    # ----------------------------------------------------------

    echo -e "${CYAN}  Extracting ${NC}${#PROCESS_CHANNELS[@]}${CYAN} channels ...${NC}"

    if [ ${#CHUNKS[@]} -gt 1 ]; then

        LIST="$WORK_DIR/list.txt"
        true > "$LIST"
        for f in "${CHUNKS[@]}"; do
            printf "file '%s'\n" "$f" >> "$LIST"
        done

        "$FFMPEG" -hide_banner -loglevel error -y \
            -f concat -safe 0 -i "$LIST" \
            -f wav pipe:1 2>>"$ERR_LOG" \
        | "$FFMPEG" -hide_banner -loglevel error -y \
            -i pipe:0 \
            -filter_complex "$FILTER" \
            "${MAPS[@]}" \
            -progress pipe:2 2>&1 >/dev/null \
        | progress_pipe "$DUR"

    else

        "$FFMPEG" -hide_banner -loglevel error -y \
            -i "$FIRST_CHUNK" \
            -filter_complex "$FILTER" \
            "${MAPS[@]}" \
            -progress pipe:1 2>>"$ERR_LOG" \
        | progress_pipe "$DUR"

    fi

    # Verify at least one output was written
    out_count=$(find "$OUT_REC_DIR" -maxdepth 1 -type f -iname "*.wav" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$out_count" -eq 0 ]; then
        echo -e "${RED}  Extraction failed — no output files written. See: ${NC}$ERR_LOG"
        REC_FAILED=$(( REC_FAILED + 1 ))
        continue
    fi

    # Per-recording summary
    OUT_SIZE=$(du -sh "$OUT_REC_DIR" 2>/dev/null | awk '{print $1}')
    echo
    echo -e "${GREEN}  Done: ${NC}$REC_NAME"
    printf "  ${GRAY}Tracks written:${NC}  %d mono" "$REC_MONO"
    [ "$REC_STEREO" -gt 0 ] && printf ", %d stereo pair(s)" "$REC_STEREO"
    echo
    echo -e "  ${GRAY}Output size:${NC}     $OUT_SIZE"
    echo -e "  ${GRAY}Location:${NC}        $OUT_REC_DIR"
    [ "$REC_FAILED" -gt 0 ] && \
        echo -e "  ${RED}Failed: $REC_FAILED — check $ERR_LOG${NC}"

    GRAND_MONO=$(( GRAND_MONO + REC_MONO ))
    GRAND_STEREO=$(( GRAND_STEREO + REC_STEREO ))
    GRAND_FAILED=$(( GRAND_FAILED + REC_FAILED ))

done

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

echo
echo -e "${GREEN}All done.${NC}"

[ "$DRY_RUN" -eq 1 ] && echo -e "${GRAY}[DRY RUN] No files were actually written.${NC}"

if [ "$TOTAL_DIRS" -gt 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    echo
    printf "  ${GRAY}Total tracks:${NC}  %d mono" "$GRAND_MONO"
    [ "$GRAND_STEREO" -gt 0 ] && printf ", %d stereo pair(s)" "$GRAND_STEREO"
    echo
    [ "$GRAND_FAILED" -gt 0 ] && \
        echo -e "  ${RED}Total failed: ${NC}$GRAND_FAILED$"
fi

if [ -s "$ERR_LOG" ] && [ "$DRY_RUN" -eq 0 ]; then
    echo
    echo -e "${YELLOW}  Warning:${NC} ffmpeg reported errors during processing."
    echo -en "${YELLOW}Show error log? ${GRAY}[${GREEN}Y${GRAY}/${NC}n${GRAY}]${YELLOW}:${NC} "
    read -r -n1 ans; echo
    case "$ans" in [nN]) ;; *) cat "$ERR_LOG" ;; esac
fi

ask_exit

exit 0
