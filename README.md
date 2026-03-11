# WING Multichannel Tracks Extractor

WING Multichannel Tracks Extractor — extracts individual WAV tracks from Behringer WING console SD card recordings on macOS. Supports named tracks, stereo pairs, multi-chunk recordings, and channel selection.

- Single ffmpeg pass — no temp files
- Multi-chunk recordings concatenated on the fly
- Stereo pairs merged inline from `.L` / `.R` named tracks
- Optional channel selection
- macOS, bash 3.2 compatible

## Requirements

- macOS
- [ffmpeg](https://ffmpeg.org/download.html) (with ffprobe) — must be in `$PATH` or specify with `-f`

## Installation

```bash
git clone https://github.com/yourname/wing-extractor.git
cd wing-extractor
chmod +x wing_tracks_extract.command
```

## Usage

```bash
./wing_tracks_extract.command -i /Volumes/SD/X_LIVE -o ~/Sessions/2025-01-31 -c 1
```

**Flags:**

| Flag | Description |
|------|-------------|
| `-i` | Input directory (default: SD card `X_LIVE` folder) |
| `-o` | Output directory |
| `-c` | Card number: `1` (ch01–32) or `2` (ch33–64) |
| `-n` | Track names file (default: `tracks.txt` next to script) |
| `-f` | Path to directory containing `ffmpeg`/`ffprobe` |
| `-s` | Channel selection, e.g. `1,3,5-8` |
| `--dry-run` | Show what would be extracted without writing files |
| `-v` | Show version |

**Examples:**

```bash
# Card 1, custom ffmpeg path
./wing_tracks_extract.command -i /Volumes/SD/X_LIVE -o ~/out -c 1 -f /usr/local/bin

# Card 2, extract only channels 1-8
./wing_tracks_extract.command -i /Volumes/SD/X_LIVE -o ~/out -c 2 -s 1-8

# Dry run to verify track map before extracting
./wing_tracks_extract.command -i /Volumes/SD/X_LIVE -o ~/out -c 1 --dry-run
```

Double-clicking the `.command` file in Finder shows usage and opens a shell.

## tracks.txt

One track name per line, in channel order. Lines starting with `#` are ignored.
Place `tracks.txt` in the same directory as the script or provide full path and file name.

```
# Drums
Kick
Snare
OH.L
OH.R
# Bass
Bass DI
```

Consecutive `.L` / `.R` pairs are automatically merged into a stereo WAV.
Missing or fewer entries than channels fall back to `Track01`, `Track02`, etc.

Output files are named `{track_nr}-{name}.wav`, stereo pairs as `{left_nr}_{right_nr}-{name}.wav`.

## License

MIT
