# Batch-Video-Convert
# Best to be ran in a screen or tmux session as it can take several hours/days to go through and complete. - Be sure your output directory is not inside of your input folder so it is not converting the same files over and over

Feed it a directory, any file 20GB or over is scanned and transcoded with ffmpeg to 15GB or as close as possible. How? 

## Step 1: The Analysis (What ffmpeg is doing)

The video codec (e.g., libx265) is put into a special analysis-only mode by the -pass 1 flag. It performs the most computationally difficult parts of the encoding process without writing the final video.

The main jobs it performs are:

- Motion Estimation: It compares each frame to the one before it and tracks where blocks of pixels (macroblocks) have moved.

- Scene-Change Detection: It identifies when a scene cuts completely, which requires a new "full" frame (an I-frame).

- Frame Complexity Analysis: This is the key. The codec calculates the "cost" to encode every single frame at a baseline quality.

- Low "Cost" Frame: A static scene, like two people talking, has very little change from one frame to the next. The motion vectors are small and the difference (residual data) is minimal. It's "cheap" to encode.

- High "Cost" Frame: An action scene with an explosion, rain, and fast camera movement has massive, chaotic changes. The motion vectors are complex and the residual data is huge. It's "expensive" to encode.

It does this for all 235,152 frames in your video.

## Step 2: The Log File (What ffmpeg is writing)

The codec does not output a video file. Instead, it outputs a text-based statistics file (e.t., ffmpeg2pass-0.log).

This file is essentially a database, with a new line for every frame. Each line records the statistics it just gathered, primarily:

- The frame number.

- The frame type it decided on (I-frame, P-frame, or B-frame).

- The quantizer (QP) value, which is the "cost" metric.

- The bits required to encode that frame at the baseline quality.

## How This Is Used in Pass 2

When Pass 2 begins, it first reads this entire log file.

- It knows the total "cost" of the whole movie.

- It knows your target average bitrate (the 11,111k we calculated for the 15GB file).

- It then performs rate distribution. It goes back through the video, and this time, it allocates your limited bit budget proportionally based on the log.

It "borrows" bits from the "cheap" talking-head scenes (giving them just enough to look good) and "spends" those saved bits on the "expensive" action scenes. This prevents the action scenes from looking blocky, which is what would happen if every frame got the same number of bits.

## How does it do what it does
- Check Tools: First, it makes sure you have ffmpeg and ffprobe installed. If not, it stops and tells you.

- Parse Your Order: It reads your -d (directory), -a (action), and -m (move) (optional) flags to understand where to look, what to do, and where to put old files.

- Find Big Files: It recursively scans the directory you gave it and makes a list of every video file larger than 20GB.

- Loop Through List: It then starts looping through that list, processing one file at a time.

## Do the Math (The "Intelligent" Part):

- It uses ffprobe to get the video's exact duration in seconds.

- It also uses ffprobe to find the bitrate of all audio and subtitle tracks.

- It calculates the total bitrate it has available for a 15GB file.

- It subtracts the audio/subtitle bitrates from that total. The result is the exact video bitrate it needs to aim for to hit 15GB.

## Clean Up: Once the new _15GB.mkv file is successfully created, it performs your chosen action (-a):

- delete: Deletes the original file.

- move: Moves the original to your backup (-m) folder.

- dryrun: Does nothing except print what it would have done.

# The Flags

-d <path>: Directory
The folder you want to search. It searches this folder and all subfolders.

-a <action>: Action
What you want to do. Your options are:
dryrun: (Safe) Reports what it would convert without touching any files.
delete: (Destructive) Converts the file, then deletes the original.
move: (Safe) Converts the file, then moves the original to a backup folder.

-m <path>: Move
The backup folder where original files are sent. You only use this if you set -a move.

Example Commands

1. Dry Run (Recommended First) This command will just look in your /mnt/movies folder and tell you what it plans to do.
Bash

`bash convert_videos.sh -d "/mnt/movies" -a dryrun`

2. Convert & Delete This will find, convert, and permanently delete the originals in your "New Volume" folder.
Bash

`bash convert_videos.sh -d "/mnt/movies" -a delete`

3. Convert & Move (Recommended Action) This will convert everything in /mnt/movies and move the large originals to /mnt/originals_backup.
Bash

`bash convert_videos.sh -d "/mnt/movies" -a move -m "/mnt/originals_backup"`
