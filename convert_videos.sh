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
VIDEO_CODEC="libx265" # Use libx265 (HEVC) for best compression
PRESET="medium"       # 'medium' is a good balance. 'slow' is smaller but much slower.

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
    echo "Usage: $0 -d <search_directory> -a <action> [-m <move_directory>]"
    echo ""
    echo "Flags:"
    echo "  -d <path>    (Required) The directory to search recursively."
    echo "  -a <action>  (Required) The action to perform."
    echo "               Actions: 'delete', 'move', 'dryrun'"
    echo "  -m <path>    (Required if action is 'move') The destination for original files."
    echo ""
    echo "Example (dry run):"
    echo "  $0 -d /mnt/movies -a dryrun"
    echo ""
    echo "Example (delete original):"
    echo "  $0 -d /mnt/movies/4k_rips -a delete"
    echo ""
    echo "Example (move original):"
    echo "  $0 -d /mnt/tv_shows -a move -m /mnt/originals"
}

# --- Argument Validation ---
SEARCH_DIR=""
ACTION=""
MOVE_DIR=""

while getopts "d:a:m:" opt; do
  case $opt in
    d) SEARCH_DIR="$OPTARG" ;;
    a) ACTION="$OPTARG" ;;
    m) MOVE_DIR="$OPTARG" ;;
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

# --- Main Script ---
check_deps

echo "Starting video conversion process..."
echo "  Search Directory: $SEARCH_DIR"
echo "  Action: $ACTION"
if [[ "$ACTION" == "move" ]]; then
    echo "  Move Originals To: $MOVE_DIR"
fi
echo "  Finding files larger than $(($SIZE_LIMIT_BYTES / 1024 / 1024 / 1024)) GiB..."

# Find files, print null-terminated, and pipe to 'while read' loop
find "$SEARCH_DIR" -type f -size +${SIZE_LIMIT_BYTES}c -iname "*.mkv" -print0 | while IFS= read -r -d '' file; do
    echo "-------------------------------------"
    echo "Processing file: $file"

    # Get original size for comparison
    ORIG_SIZE_GB=$(awk "BEGIN {print $(stat -c%s \"$file\") / 1024 / 1024 / 1024}")
    echo "  - Original size: $(printf "%.2f" $ORIG_SIZE_GB) GiB"

    # 1. Get duration in seconds
    DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file")
    if [[ -z "$DURATION" ]]; then
        echo "  - ERROR: Could not get video duration. Skipping."
        continue
    fi
    DURATION_S=$(printf "%.0f" "$DURATION")
    echo "  - Duration: $DURATION_S seconds"

    # 2. Get total audio/subtitle bitrate (in bits per second)
    AUDIO_BITRATE=$(ffprobe -v error -select_streams a -show_entries stream=bit_rate -of csv=s=x:p=0 "$file" | awk '{s+=$1} END {print s}')
    SUB_BITRATE=$(ffprobe -v error -select_streams s -show_entries stream=bit_rate -of csv=s=x:p=0 "$file" | awk '{s+=$1} END {print s}')
    
    # Handle missing bitrate (N/A)
    [[ -z "$AUDIO_BITRATE" ]] && AUDIO_BITRATE=0
    [[ -z "$SUB_BITRATE" ]] && SUB_BITRATE=0
    
    OTHER_BITRATE=$((AUDIO_BITRATE + SUB_BITRATE))
    OTHER_BITRATE_K=$((OTHER_BITRATE / 1000))
    echo "  - Total audio/sub bitrate: ${OTHER_BITRATE_K}k"

    # 3. Check resolution and set scale filter if needed
    # Get the height of the first video stream
    SOURCE_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$file")
    SCALE_FILTER=""

    if [[ -z "$SOURCE_HEIGHT" ]]; then
        echo "  - WARNING: Could not determine source height. Will not scale."
    elif [[ "$SOURCE_HEIGHT" -gt 1080 ]]; then
        echo "  - Source height is ${SOURCE_HEIGHT}p. Downscaling to 1080p."
        # -vf "scale=-2:1080" means: scale height to 1080, width is auto (-2) to keep aspect ratio
        SCALE_FILTER="-vf scale=-2:1080"
    else
        echo "  - Source height is ${SOURCE_HEIGHT}p. Retaining original resolution."
        # SCALE_FILTER remains empty, so no scaling is done
    fi

    # 4. Calculate target video bitrate
    TARGET_VIDEO_BITS=$((TARGET_SIZE_BITS - (OTHER_BITRATE * DURATION_S)))
    TARGET_VIDEO_BPS=$((TARGET_VIDEO_BITS / DURATION_S))
    TARGET_VIDEO_BPS_K=$((TARGET_VIDEO_BPS / 1000))

    if [[ "$TARGET_VIDEO_BPS" -le 0 ]]; then
        echo "  - ERROR: Calculated target bitrate is zero or negative."
        echo "  - This might mean the audio/subs are already larger than the target size."
        echo "  - Skipping file."
        continue
    fi
    echo "  - Target video bitrate: ${TARGET_VIDEO_BPS_K}k"

    # Define output filename
    DIRNAME=$(dirname "$file")
    FILENAME=$(basename "$file")
    EXTENSION="${FILENAME##*.}"
    BASENAME="${FILENAME%.*}"
    OUTPUT_FILE="${DIRNAME}/${BASENAME}_15GB.${EXTENSION}"

    echo "  - Output file: $OUTPUT_FILE"

    # Handle 'dryrun' action
    if [[ "$ACTION" == "dryrun" ]]; then
        echo "  [DRY RUN] Would convert this file. Skipping."
        continue
    fi

    # 5. Run 2-Pass FFMPEG
    LOG_FILE_BASE="/tmp/ffmpeg2pass_$(date +%s)_${RANDOM}"
    
    # Pass 1: Analysis
    echo "  - Starting Pass 1..."
    if ! ffmpeg -y -nostdin -i "$file" \
        -c:v "$VIDEO_CODEC" -preset "$PRESET" -b:v "${TARGET_VIDEO_BPS}" \
        $SCALE_FILTER \
        -pass 1 -passlogfile "$LOG_FILE_BASE" \
        -map 0 -c:a copy -c:s copy -c:d copy \
        -f matroska /dev/null; then
        
        echo "  - ERROR: FFMPEG Pass 1 failed. Check logs."
        rm -f "${LOG_FILE_BASE}-0.log" "${LOG_FILE_BASE}-0.log.mbtree"
        continue
    fi
    echo "  - Pass 1 complete."

    # Pass 2: Encoding
    echo "  - Starting Pass 2..."
    if ! ffmpeg -y -nostdin -i "$file" \
        -c:v "$VIDEO_CODEC" -preset "$PRESET" -b:v "${TARGET_VIDEO_BPS}" \
        $SCALE_FILTER \
        -pass 2 -passlogfile "$LOG_FILE_BASE" \
        -map 0 -c:a copy -c:s copy -c:d copy \
        "$OUTPUT_FILE"; then

        echo "  - ERROR: FFMPEG Pass 2 failed. Check logs."
        echo "  - The new file '$OUTPUT_FILE' may be corrupt. Deleting it."
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
