#!/bin/bash
#
# Interactive FFmpeg Transcoder Script (SDR ONLY)
#
# Interactively prompts for settings, then scans a directory for large
# video files to transcode to HEVC/H.265. Processes ONLY SDR files and
# SKIPS ALL HDR files, logging them for manual conversion (e.g., Handbrake).
#
# Usage: ./Interactive_Media_Transcoder.sh [--dry-run] [--help]
#
# --- Version 7 ---
# - Added --dry-run and --help flags.
# - Fixed VAAPI hwaccel_output_format (must be 'vaapi', not 'yuv420p').
# - Fixed NVIDIA filter chain to stay on GPU surface correctly.
# - Replaced unsafe eval tilde expansion with parameter substitution.
# - Added set -uo pipefail for stricter error handling.
# - Added trap for Ctrl+C cleanup of in-progress temp files.
# - Added numeric validation for RF value.
# - Added per-file elapsed time reporting.
# - Added final summary (processed / skipped-HDR / skipped-exists / failed).
# - HDR log now deduplicates entries.
# - Added startup validation of all output directories (writable check).
# - Added -map_chapters 0 to preserve chapters.
# - Used conditional audio/subtitle mapping to avoid errors on streams that
#   may not exist.

# --- Strict mode (safe variant — pipefail is set but the find|while loop
#     uses a process substitution to avoid the last-pipe-exit-code problem) ---
set -uo pipefail

# --- Globals ---
TARGET_DIR=""
ACTION=""
MOVE_PATH=""
HW_TYPE=""
RF_VALUE=""
TARGET_H=""
MIN_SIZE_GB=""
TRANSCODE_PATH=""
WORK_IN_PROGRESS_PATH=""
FINAL_OUTPUT_DIR=""
HDR_LOG_FILE=""

VCODEC="libx265"
HW_OPTS=""
QUALITY_OPTS=""
VF_STRING=""
X265_PARAMS=""

DRY_RUN=false

# Counters for final summary
COUNT_PROCESSED=0
COUNT_HDR=0
COUNT_SKIPPED=0
COUNT_FAILED=0

# Track current temp file for trap cleanup
CURRENT_TEMP_FILE=""

# --- Parse CLI Flags ---
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            echo "*** DRY RUN MODE: No files will be moved, deleted, or transcoded. ***"
            ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--help]"
            echo ""
            echo "  --dry-run   Show what would be processed without changing anything."
            echo "  --help      Show this help message."
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Use --help for usage." >&2
            exit 1
            ;;
    esac
done

# --- Trap: Clean up temp file on Ctrl+C or SIGTERM ---
cleanup() {
    echo ""
    echo "Interrupted. Cleaning up..."
    if [ -n "$CURRENT_TEMP_FILE" ] && [ -f "$CURRENT_TEMP_FILE" ]; then
        echo "Removing incomplete temp file: $CURRENT_TEMP_FILE"
        rm -f "$CURRENT_TEMP_FILE"
    fi
    echo "Exiting."
    exit 1
}
trap cleanup INT TERM

# --- Helper: Yes/No Prompt ---
ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local response

    if [ "$default" = "Y" ]; then
        read -rp "$prompt (Y/n): " response
    else
        read -rp "$prompt (y/N): " response
    fi
    response="${response:-$default}"

    [[ "$response" =~ ^[Yy]$ ]]
}

# --- Helper: Ask for an Existing Directory ---
ask_for_dir() {
    local prompt="$1"
    local var_name="$2"
    local dir_path=""

    while true; do
        read -rp "$prompt: " dir_path
        # Safe tilde expansion (no eval)
        dir_path="${dir_path/#\~/$HOME}"
        # Strip trailing slash
        dir_path="${dir_path%/}"

        if [ -d "$dir_path" ]; then
            # Check it's writable (unless dry run)
            if [ "$DRY_RUN" = false ] && [ ! -w "$dir_path" ]; then
                echo "Error: Directory '$dir_path' is not writable. Please choose another." >&2
                continue
            fi
            printf -v "$var_name" '%s' "$dir_path"
            break
        else
            echo "Error: Directory not found: '$dir_path'. Please try again." >&2
        fi
    done
}

# --- Helper: Validate Integer ---
ask_for_int() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local value=""

    while true; do
        read -rp "$prompt (Default $default): " value
        value="${value:-$default}"
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            printf -v "$var_name" '%s' "$value"
            break
        else
            echo "Error: Please enter a whole number." >&2
        fi
    done
}

# ===========================================================================
# --- Interactive Setup ---
# ===========================================================================
echo "=============================================="
echo "   Interactive Media Transcoder Setup (SDR)  "
echo "=============================================="
echo ""

# 1. Target Directory
ask_for_dir "Directory to SCAN for media files" TARGET_DIR

# 2. Action on originals
if ask_yes_no "Keep the original file after transcoding (move it to an archive)?" "Y"; then
    ACTION="move"
    ask_for_dir "Where should original files be MOVED to (archive directory)" MOVE_PATH
else
    ACTION="delete"
    echo "Originals will be DELETED after successful transcoding."
fi

# 3. Hardware or CPU
while true; do
    read -rp "Encoding mode — hardware (hw) or CPU? [hw/cpu, default: cpu]: " hw_choice
    hw_choice="${hw_choice:-cpu}"
    hw_choice_lower="${hw_choice,,}"

    if [ "$hw_choice_lower" = "cpu" ]; then
        HW_TYPE="cpu"
        break
    elif [ "$hw_choice_lower" = "hw" ]; then
        while true; do
            read -rp "Hardware vendor — amd / intel / nvidia: " hw_specific
            hw_specific_lower="${hw_specific,,}"
            case "$hw_specific_lower" in
                amd|intel|nvidia)
                    HW_TYPE="$hw_specific_lower"
                    break 2
                    ;;
                *)
                    echo "Please enter 'amd', 'intel', or 'nvidia'." >&2
                    ;;
            esac
        done
    else
        echo "Please enter 'hw' or 'cpu'." >&2
    fi
done

# 4. RF / Quality value
ask_for_int "RF quality value (lower = better quality, larger file; typical range 15-28)" "15" RF_VALUE

# 5. Target resolution height
read -rp "Target resolution height in pixels, e.g. 720 or 1080 (Default: 720): " TARGET_SIZE_RAW
TARGET_SIZE_RAW="${TARGET_SIZE_RAW:-720}"
TARGET_H=$(echo "$TARGET_SIZE_RAW" | grep -oE '[0-9]+' | head -n1)
echo "Target height: ${TARGET_H}p"

# 6. Minimum file size threshold
ask_for_int "Minimum file size to process in GB (skip smaller files)" "20" MIN_SIZE_GB
echo "Only files larger than ${MIN_SIZE_GB} GB will be processed."

# 7. WIP / checkout directory (prevents concurrent processing of the same file)
if ask_yes_no "Move each file to a 'working' directory before transcoding? (Prevents two instances colliding)" "N"; then
    ask_for_dir "Working/checkout directory" WORK_IN_PROGRESS_PATH
fi

# 8. Temporary transcode directory (transcode to fast scratch disk, then move)
if ask_yes_no "Transcode to a temporary directory first, then move finished file to destination?" "N"; then
    ask_for_dir "Temporary transcoding directory (scratch space)" TRANSCODE_PATH
fi

# 9. Final output directory (different from scan directory)
if ask_yes_no "Place finished (shrunk) files in a directory different from where they were scanned?" "N"; then
    ask_for_dir "Final output directory for shrunk files" FINAL_OUTPUT_DIR
fi

# --- HDR Log File ---
HDR_LOG_FILE="$TARGET_DIR/_HDR_files_to_check.log"

# ===========================================================================
# --- Build FFmpeg Options ---
# ===========================================================================
case "$HW_TYPE" in
    cpu)
        VCODEC="libx265"
        HW_OPTS=""
        X265_PARAMS="strong-intra-smoothing=0:rect=0:aq-mode=1:rd=4:psy-rd=0.75:psy-rdoq=4.0:rdoq-level=1:rskip=2"
        QUALITY_OPTS="-crf $RF_VALUE -preset slow -x265-params $X265_PARAMS"
        VF_STRING="scale=w=-2:h='trunc(min(ih,$TARGET_H)/16)*16',format=yuv420p"
        echo "Encoder: CPU (libx265), preset slow — best compression."
        ;;
    nvidia)
        VCODEC="hevc_nvenc"
        # Decode on GPU; keep frames in CUDA memory for scale_cuda
        HW_OPTS="-hwaccel cuda -hwaccel_output_format cuda"
        QUALITY_OPTS="-preset p5 -tune hq -cq $RF_VALUE -rc-lookahead 32"
        # scale_cuda outputs NV12 on CUDA surface; no explicit format needed before encoder
        VF_STRING="scale_cuda=w=-2:h='trunc(min(ih,$TARGET_H)/16)*16':format=nv12"
        echo "Encoder: NVIDIA (hevc_nvenc) — fast GPU encoding."
        ;;
    intel|amd)
        VCODEC="hevc_vaapi"
        # hwaccel_output_format must be 'vaapi' to keep frames on the VAAPI surface
        HW_OPTS="-hwaccel vaapi -hwaccel_output_format vaapi -vaapi_device /dev/dri/renderD128"
        QUALITY_OPTS="-qp $RF_VALUE"
        # Scale in software first (format=nv12), then upload to VAAPI surface
        VF_STRING="scale=w=-2:h='trunc(min(ih,$TARGET_H)/16)*16',format=nv12,hwupload"
        echo "Encoder: VAAPI ($HW_TYPE: hevc_vaapi) — fast GPU encoding."
        ;;
esac
echo "HDR files will be SKIPPED and logged."
echo ""

# ===========================================================================
# --- Initialize Log File ---
# ===========================================================================
if [ "$DRY_RUN" = false ]; then
    if [ ! -f "$HDR_LOG_FILE" ]; then
        {
            echo "# HDR Videos Log — Created $(date)"
            echo "# These files are HDR and were skipped. Use Handbrake for manual conversion."
            echo ""
        } > "$HDR_LOG_FILE"
        echo "Created HDR log: $HDR_LOG_FILE"
    fi
fi

# ===========================================================================
# --- Print Config Summary ---
# ===========================================================================
echo "======================================================"
echo "  Configuration Summary"
echo "======================================================"
echo "  Scan directory  : $TARGET_DIR"
echo "  Encoder         : $HW_TYPE ($VCODEC)"
echo "  RF/Quality      : $RF_VALUE"
echo "  Target height   : ${TARGET_H}p"
echo "  Min file size   : ${MIN_SIZE_GB} GB"
echo "  On success      : $ACTION originals"
[ "$ACTION" = "move" ]        && echo "  Archive path    : $MOVE_PATH"
[ -n "$WORK_IN_PROGRESS_PATH" ] && echo "  WIP/checkout    : $WORK_IN_PROGRESS_PATH"
[ -n "$TRANSCODE_PATH" ]        && echo "  Temp transcode  : $TRANSCODE_PATH"
[ -n "$FINAL_OUTPUT_DIR" ]      && echo "  Final output    : $FINAL_OUTPUT_DIR"
[ -z "$FINAL_OUTPUT_DIR" ]      && echo "  Final output    : (same as scan directory)"
echo "  HDR log         : $HDR_LOG_FILE"
[ "$DRY_RUN" = true ]           && echo "  *** DRY RUN — no changes will be made ***"
echo "======================================================"
echo ""

# ===========================================================================
# --- Main Processing Loop ---
# ===========================================================================
# Use process substitution instead of a pipe so the loop runs in the current
# shell (preserving counter variables) and pipefail doesn't trip on find.
while IFS= read -r -d '' filepath; do

    echo "------------------------------------------------------"
    echo "Found: $filepath"

    # --- HDR Detection ---
    color_transfer=""
    color_transfer=$(ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=color_transfer \
        -of default=noprint_wrappers=1:nokey=1 \
        "$filepath" 2>/dev/null || true)

    if [ "$color_transfer" = "smpte2084" ] || [ "$color_transfer" = "arib-std-b67" ]; then
        echo "  → HDR detected ($color_transfer). Skipping."
        # Deduplicate log entries
        if [ "$DRY_RUN" = false ]; then
            if ! grep -qxF "$filepath" "$HDR_LOG_FILE" 2>/dev/null; then
                echo "$filepath" >> "$HDR_LOG_FILE"
            fi
        fi
        (( COUNT_HDR++ )) || true
        continue
    fi
    echo "  → SDR ($color_transfer). Proceeding."

    # --- Derive Path Variables ---
    original_dir=$(dirname "$filepath")
    filename=$(basename "$filepath")
    filename_noext="${filename%.*}"
    output_filename="${filename_noext}_shrunk.mkv"

    # --- Claim File (WIP Move) ---
    input_for_ffmpeg="$filepath"

    if [ -n "$WORK_IN_PROGRESS_PATH" ]; then
        wip_filepath="$WORK_IN_PROGRESS_PATH/$filename"

        if [ -f "$wip_filepath" ]; then
            echo "  → Already in WIP directory. Another process may own it. Skipping."
            (( COUNT_SKIPPED++ )) || true
            continue
        fi

        if [ "$DRY_RUN" = false ]; then
            echo "  → Claiming: moving to $wip_filepath"
            if ! mv "$filepath" "$wip_filepath"; then
                echo "  → Error: Could not move to WIP. Skipping." >&2
                (( COUNT_SKIPPED++ )) || true
                continue
            fi
        else
            echo "  [DRY RUN] Would move to WIP: $wip_filepath"
        fi
        input_for_ffmpeg="$wip_filepath"
    fi

    # --- Determine Output Paths ---
    if [ -n "$FINAL_OUTPUT_DIR" ]; then
        final_output_path="$FINAL_OUTPUT_DIR/$output_filename"
    else
        final_output_path="$original_dir/$output_filename"
    fi

    if [ -n "$TRANSCODE_PATH" ]; then
        temp_output_path="$TRANSCODE_PATH/$output_filename"
    else
        temp_output_path="$final_output_path"
    fi

    # --- Skip if Output Already Exists ---
    if [ -f "$temp_output_path" ] || [ -f "$final_output_path" ]; then
        echo "  → Output already exists ('$output_filename'). Skipping."
        # Return claimed file if we moved it
        if [ -n "$WORK_IN_PROGRESS_PATH" ] && [ "$DRY_RUN" = false ]; then
            echo "  → Returning file to original location."
            mv "$input_for_ffmpeg" "$filepath" || true
        fi
        (( COUNT_SKIPPED++ )) || true
        continue
    fi

    # --- Dry Run Short-Circuit ---
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would transcode:"
        echo "    Input  : $input_for_ffmpeg"
        echo "    Temp   : $temp_output_path"
        echo "    Final  : $final_output_path"
        echo "    Action : $ACTION original"
        (( COUNT_PROCESSED++ )) || true
        continue
    fi

    # --- Transcode ---
    echo "  → Transcoding: $filename → $output_filename"
    [ -n "$TRANSCODE_PATH" ] && echo "     Temp path: $temp_output_path"

    CURRENT_TEMP_FILE="$temp_output_path"
    time_start=$(date +%s)

    ffmpeg -nostdin \
        $HW_OPTS \
        -analyzeduration 20M \
        -probesize 20M \
        -i "$input_for_ffmpeg" \
        -map 0:v:0 \
        -map 0:a? \
        -map 0:s? \
        -map_chapters 0 \
        -c:v "$VCODEC" $QUALITY_OPTS \
        -vf "$VF_STRING" \
        -c:a copy \
        -c:s copy \
        "$temp_output_path"

    ffmpeg_exit=$?
    CURRENT_TEMP_FILE=""
    time_end=$(date +%s)
    elapsed=$(( time_end - time_start ))
    elapsed_fmt=$(printf '%02dh %02dm %02ds' $(( elapsed/3600 )) $(( (elapsed%3600)/60 )) $(( elapsed%60 )))

    if [ $ffmpeg_exit -eq 0 ]; then
        echo "  → Success. Elapsed: $elapsed_fmt"

        # Handle original
        case "$ACTION" in
            delete)
                echo "  → Deleting original: $input_for_ffmpeg"
                rm "$input_for_ffmpeg"
                ;;
            move)
                echo "  → Archiving original to: $MOVE_PATH/"
                mv "$input_for_ffmpeg" "$MOVE_PATH/"
                ;;
        esac

        # Move from temp to final if using a scratch directory
        if [ -n "$TRANSCODE_PATH" ]; then
            echo "  → Moving to final destination: $final_output_path"
            mv "$temp_output_path" "$final_output_path"
        fi

        (( COUNT_PROCESSED++ )) || true

    else
        echo "  → FFmpeg FAILED (exit $ffmpeg_exit). Elapsed: $elapsed_fmt" >&2
        echo "     Removing incomplete output: $temp_output_path"
        rm -f "$temp_output_path"

        # Return claimed file if WIP was used
        if [ -n "$WORK_IN_PROGRESS_PATH" ]; then
            echo "  → Returning file to original location."
            mv "$input_for_ffmpeg" "$filepath" || true
        fi

        (( COUNT_FAILED++ )) || true
    fi

done < <(find "$TARGET_DIR" \
    -type f \
    -size +"${MIN_SIZE_GB}G" \
    \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" \
       -o -name "*.mov" -o -name "*.ts"  -o -name "*.m2ts" \
       -o -name "*.webm" \) \
    ! -name "*_shrunk.mkv" \
    -print0)

# ===========================================================================
# --- Final Summary ---
# ===========================================================================
echo ""
echo "======================================================"
echo "  Run Complete"
echo "======================================================"
echo "  Transcoded successfully : $COUNT_PROCESSED"
echo "  Skipped (HDR)           : $COUNT_HDR"
echo "  Skipped (exists/WIP)    : $COUNT_SKIPPED"
echo "  Failed                  : $COUNT_FAILED"
[ $COUNT_HDR -gt 0 ]   && echo "  HDR log                 : $HDR_LOG_FILE"
[ "$DRY_RUN" = true ]   && echo "  *** DRY RUN — nothing was changed ***"
echo "======================================================"
