#!/bin/bash
set -eo pipefail

# --- Configuration ---
# File size limit (20 GiB). Files *over* this size will be processed.
# (20 * 1024 * 1024 * 1024)
SIZE_LIMIT_BYTES=21474836480

# Target file size (15 GiB).
# (15 * 1024 * 1024 * 1024)
TARGET_SIZE_BYTES=16106127360
TARGET_SIZE_BITS=$((TARGET_SIZE_BYTES * 8))

# FFMPEG settings
VIDEO_CODEC="libx265" # use CPU for final encode for quality
PRESET="medium"       # 'medium' is a good balance. 'slow' is smaller but much slower.
# Fallback bitrate (in BPS) for audio/subs if not detected (e.g., TrueHD)
# 8,000,000 bps = 8000 kbps (a very safe buffer for HD audio)
FALLBACK_OTHER_BITRATE=8000000 


# --- Helper Functions ---
function check_deps {
    if ! command -v ffmpeg &> /dev/null; then
        echo "Error: ffmpeg is not installed. Please install it." >&2
        exit 1
    fi
    if ! command -v ffprobe &> /dev/null; then
        echo "Error: ffprobe is not installed. Please install it (it usually comes with ffmpeg)." >&2
        exit 1
    fi
}

function print_usage {
    echo "Usage: $0 -d <search_directory> -a <action> [-m <move_directory>] [-h <intel|amd|nvidia>]"
    echo ""
    echo "Flags:"
    echo "  -d <path>    (Required) The directory to search recursively."
    echo "  -a <action>  (Required) The action to perform."
    echo "               Actions: 'delete', 'move', 'dryrun'"
    echo "  -m <path>    (Required if action is 'move') The destination for original files."
    echo "  -h <type>    (Optional) Hardware acceleration for decode/scale."
    echo "               Types: 'intel' (QSV), 'amd' (VAAPI), 'nvidia' (CUDA)"
    echo ""
    echo "Example (Intel QSV Hybrid):"
    echo "  $0 -d /mnt/movies -a delete -h intel"
    echo ""
    echo "Example (AMD VAAPI Hybrid):"
    echo "  $0 -d /mnt/movies -a delete -h amd"
    echo ""
    echo "Example (Nvidia CUDA Hybrid):"
    echo "  $0 -d /mnt/movies -a delete -h nvidia"
}

# --- Argument Validation ---
SEARCH_DIR=""
ACTION=""
MOVE_DIR=""
HW_TYPE=""

while getopts "d:a:m:h:" opt; do
  case $opt in
    d) SEARCH_DIR="$OPTARG" ;;
    a) ACTION="$OPTARG" ;;
    m) MOVE_DIR="$OPTARG" ;;
    h) HW_TYPE="$OPTARG" ;; # -h for hardware
    \?)
      echo "Invalid option: -$OPTARG" >&2
      print_usage
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      print_usage
      exit 1
      ;;
  esac
done

if [[ -z "$SEARCH_DIR" || ! -d "$SEARCH_DIR" ]]; then
    echo "Error: Please provide a valid search directory with -d." >&2
    print_usage
    exit 1
fi

if [[ "$ACTION" != "delete" && "$ACTION" != "move" && "$ACTION" != "dryrun" ]]; then
    echo "Error: Invalid action with -a. Must be 'delete', 'move', or 'dryrun'." >&2
    print_usage
    exit 1
fi

if [[ "$ACTION" == "move" ]]; then
    if [[ -z "$MOVE_DIR" ]]; then
        echo "Error: 'move' action requires a move directory with -m." >&2
        print_usage
        exit 1
    fi
    if ! mkdir -p "$MOVE_DIR"; then
        echo "Error: Could not create move directory '$MOVE_DIR'." >&2
        exit 1
    fi
    MOVE_DIR=$(realpath "$MOVE_DIR") # Get absolute path
fi

if [[ "$HW_TYPE" != "" && "$HW_TYPE" != "intel" && "$HW_TYPE" != "amd" && "$HW_TYPE" != "nvidia" ]]; then
    echo "Error: Invalid hardware type with -h. Must be 'intel', 'amd', or 'nvidia'." >&2
    print_usage
    exit 1
fi

# --- Main Script ---
check_deps

echo "Starting video conversion process..."
echo "  Search Directory: $SEARCH_DIR"
echo "  Action: $ACTION"
[[ "$ACTION" == "move" ]] && echo "  Move Originals To: $MOVE_DIR"
[[ "$HW_TYPE" != "" ]] && echo "  Hardware Acceleration: $HW_TYPE" || echo "  Hardware Acceleration: None (CPU only)"
echo "  Finding files larger than $(($SIZE_LIMIT_BYTES / 1024 / 1024 / 1024)) GiB..."

# Find files, print null-terminated, and pipe to 'while read' loop
find "$SEARCH_DIR" -type f -size +${SIZE_LIMIT_BYTES}c \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" \) -print0 | while IFS= read -r -d '' file; do
    echo "-------------------------------------"
    echo "Processing file: $file"

    # --- Define file paths and log file location ---
    DIRNAME=$(dirname "$file")
    FILENAME=$(basename "$file")
    EXTENSION="${FILENAME##*.}"
    BASENAME="${FILENAME%.*}"
    OUTPUT_FILE="${DIRNAME}/${BASENAME}_15GB.${EXTENSION}"
    
    LOG_FILE_BASE="${DIRNAME}/${BASENAME}_ffmpeg2pass"
    
    echo "  - Output file: $OUTPUT_FILE"
    echo "  - Log files: ${LOG_FILE_BASE}-0.log"

    # --- Start Probing File ---
    
    ORIG_SIZE_BYTES_RAW=$(stat -c%s "$file")
    ORIG_SIZE_GB=$(awk "BEGIN {print $ORIG_SIZE_BYTES_RAW / 1024 / 1024 / 1024}")
    echo "  - Original size: $(printf "%.2f" $ORIG_SIZE_GB) GiB"

    # 1. Get duration
    DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file")
    if [[ -z "$DURATION" ]]; then
        echo "  - ERROR: Could not get video duration. Skipping."
        continue
    fi
    DURATION_S=$(printf "%.0f" "$DURATION")
    echo "  - Duration: $DURATION_S seconds"

    # 2. Get audio/sub bitrate
    AUDIO_BITRATE=$(ffprobe -v error -select_streams a -show_entries stream=bit_rate -of csv=s=x:p=0 "$file" | awk '{s+=$1} END {print s}')
    SUB_BITRATE=$(ffprobe -v error -select_streams s -show_entries stream=bit_rate -of csv=s=x:p=0 "$file" | awk '{s+=$1} END {print s}')
    [[ -z "$AUDIO_BITRATE" ]] && AUDIO_BITRATE=0
    [[ -z "$SUB_BITRATE" ]] && SUB_BITRATE=0
    
    OTHER_BITRATE=$((AUDIO_BITRATE + SUB_BITRATE))

    if [[ "$OTHER_BITRATE" -eq 0 ]]; then
        echo "  - WARNING: Could not detect audio/sub bitrate (may be PCM/TrueHD)."
        echo "  - Applying a $FALLBACK_OTHER_BITRATE bps safety buffer."
        OTHER_BITRATE=$FALLBACK_OTHER_BITRATE
    fi
    echo "  - Total audio/sub bitrate: $((OTHER_BITRATE / 1000))k"

    # 3. Set HW-Accel flags and Scaling filter
    SOURCE_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$file")
    
    HW_DECODE_FLAGS=()
    SCALE_CHAIN=""

    if [[ "$HW_TYPE" == "intel" ]]; then
        HW_DECODE_FLAGS=("-hwaccel" "qsv" "-c:v" "hevc_qsv")
        if [[ "$SOURCE_HEIGHT" -gt 1080 ]]; then
            echo "  - Using Intel QSV for decode and 1080p scaling."
            SCALE_CHAIN="scale_qsv=w=-2:h=1080"
        else
            echo "  - Using Intel QSV for decode. No scaling needed."
        fi
    
    elif [[ "$HW_TYPE" == "amd" ]]; then
        HW_DECODE_FLAGS=("-hwaccel" "vaapi" "-hwaccel_output_format" "vaapi")
        if [[ "$SOURCE_HEIGHT" -gt 1080 ]]; then
            echo "  - Using AMD VAAPI for decode and 1080p scaling."
            SCALE_CHAIN="scale_vaapi=w=-2:h=1080,hwdownload,format=yuv420p"
        else
            echo "  - Using AMD VAAPI for decode. No scaling needed."
            SCALE_CHAIN="hwdownload,format=yuv420p"
        fi
    
    elif [[ "$HW_TYPE" == "nvidia" ]]; then
        HW_DECODE_FLAGS=("-hwaccel" "cuda" "-c:v" "hevc_cuvid")
        if [[ "$SOURCE_HEIGHT" -gt 1080 ]]; then
            echo "  - Using Nvidia CUDA for decode and 1080p scaling."
            SCALE_CHAIN="scale_cuda=w=-2:h=1080,hwdownload,format=yuv420p"
        else
            echo "  - Using Nvidia CUDA for decode. No scaling needed."
            SCALE_CHAIN="hwdownload,format=yuv4G"
        fi

    else # No HW-Accel (CPU only)
        if [[ "$SOURCE_HEIGHT" -gt 1080 ]]; then
            echo "  - Using CPU for 1080p scaling."
            SCALE_CHAIN="scale=-2:1080"
        else
            echo "  - No scaling needed."
        fi
    fi

    # 4. Calculate target video bitrate
    TARGET_VIDEO_BITS=$((TARGET_SIZE_BITS - (OTHER_BITRATE * DURATION_S)))
    TARGET_VIDEO_BPS=$((TARGET_VIDEO_BITS / DURATION_S))
    TARGET_VIDEO_BPS_K=$((TARGET_VIDEO_BPS / 1000))

    if [[ "$TARGET_VIDEO_BPS" -le 0 ]]; then
        echo "  - ERROR: Calculated target bitrate is zero or negative (safety buffer may be too high). Skipping."
        continue
    fi
    echo "  - Target video bitrate: ${TARGET_VIDEO_BPS_K}k"

    if [[ "$ACTION" == "dryrun" ]]; then
        echo "  [DRY RUN] Would convert this file. Skipping."
        continue
    fi

    # 5. Run 2-Pass FFMPEG
    
    # --- Build FFMPEG Command Arrays ---
    
    # Base options
    FFMPEG_BASE_ARGS=(
        "-y"                # Overwrite output without asking
        "-nostdin"          # Disable interactive input
    )
    
    # Input options
    FFMPEG_INPUT_ARGS=(
        "${HW_DECODE_FLAGS[@]}" # Add hw-accel flags (if any)
        "-i" "$file"        # Set input file
    )

    # Output options
    # FIX: Changed -map 0 to be specific and avoid filtering/copying
    # the extra video stream (cover art).
    FFMPEG_OUTPUT_ARGS=(
        "-c:v" "$VIDEO_CODEC"   # Set video encoder to libx265
        "-preset" "$PRESET"       # Set CPU encode preset
        "-b:v" "$TARGET_VIDEO_BPS" # Set target video bitrate
        "-map" "0:v:0"          # Map ONLY the first video stream
        "-map" "0:a?"           # Map all audio streams (if any)
        "-map" "0:s?"           # Map all subtitle streams (if any)
        "-c:a" "copy"           # Copy audio streams
        "-c:s" "copy"           # Copy subtitle streams
    )

    # Build scale filter args array
    SCALE_ARGS=()
    if [[ -n "$SCALE_CHAIN" ]]; then
      SCALE_ARGS=("-vf" "$SCALE_CHAIN")
    fi

    # --- Pass 1: Analysis ---
    echo "  - Starting Pass 1 (Hybrid Mode)..."
    
    # Pass 1 specific args
    PASS1_ARGS=(
        "-pass" "1"
        "-passlogfile" "$LOG_FILE_BASE"
        "-f" "matroska"
        "/dev/null"
    )

    if ! ffmpeg "${FFMPEG_BASE_ARGS[@]}" \
                "${FFMPEG_INPUT_ARGS[@]}" \
                "${FFMPEG_OUTPUT_ARGS[@]}" \
                "${SCALE_ARGS[@]}" \
                "${PASS1_ARGS[@]}"; then
        
        echo "  - ERROR: FFMPEG Pass 1 failed. Check logs."
        rm -f "${LOG_FILE_BASE}-0.log" "${LOG_FILE_BASE}-0.log.mbtree"
        continue
    fi
    echo "  - Pass 1 complete."


    # --- Pass 2: Encoding ---
    echo "  - Starting Pass 2 (Hybrid Mode)..."
    
    # Pass 2 specific args
    PASS2_ARGS=(
        "-pass" "2"
        "-passlogfile" "$LOG_FILE_BASE"
        "$OUTPUT_FILE"
    )

    if ! ffmpeg "${FFMPEG_BASE_ARGS[@]}" \
                "${FFMPEG_INPUT_ARGS[@]}" \
                "${FFMPEG_OUTPUT_ARGS[@]}" \
                "${SCALE_ARGS[@]}" \
                "${PASS2_ARGS[@]}"; then

        echo "  - ERROR: FFMPEG Pass 2 failed. Check logs."
        echo "  - Deleting incomplete output file: $OUTPUT_FILE"
        rm -f "$OUTPUT_FILE"
        rm -f "${LOG_FILE_BASE}-0.log" "${LOG_FILE_BASE}-0.log.mbtree"
        continue
    fi
    echo "  - Pass 2 complete. New file created."

    # 6. Verify new file and perform action
    if [[ -f "$OUTPUT_FILE" && $(stat -c%s "$OUTPUT_FILE") -gt 1024 ]]; then
        echo "  - New file verified."
        
        if [[ "$ACTION" == "delete" ]]; then
            echo "  - Deleting original file: $file"
            rm -f "$file"
        elif [[ "$ACTION" == "move" ]]; then
            echo "  - Moving original file to: $MOVE_DIR"
            mv -f "$file" "$MOVE_DIR/"
        fi
    else
        echo "  - ERROR: New file '$OUTPUT_FILE' seems empty or invalid. Not touching original."
    fi

    # Clean up log files
    rm -f "${LOG_FILE_BASE}-0.log" "${LOG_FILE_BASE}-0.log.mbtree"

done

echo "-------------------------------------"
echo "All processing complete."

