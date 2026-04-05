# whisper-docker

A Dockerised subtitle generator built on [stable-ts](https://github.com/jianfch/stable-ts) (OpenAI Whisper). It watches your media library for new files and automatically generates `.{lang}.whisper.srt` subtitle files alongside each video.

> **Personal utility, shared as-is.** This works for my setup; it may or may not work for yours. Issues and PRs are welcome but I can't promise timely responses.

---

## Requirements

- Docker + Docker Compose v2
- An NVIDIA GPU with [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) *(strongly recommended — CPU transcription is very slow)*

---

## Quick start

**1. Clone and configure**

```bash
git clone https://github.com/rickytwarner/whisper-docker.git
cd whisper-docker
```

Open `docker-compose.yml` and set the media volume mount to point at your library:

```yaml
volumes:
  - /path/to/your/media:/media   # <-- edit this line
```

**2. Build**

```bash
docker compose build
```

The first build downloads PyTorch with CUDA support (~2 GB). Subsequent builds are cached.

**3. Start the watcher**

```bash
docker compose up -d
```

The container starts, does an initial pass over your existing library (skipping anything already subtitled), then sits in the background watching for new files. When a new MKV or MP4 lands, it starts transcribing automatically.

The first run also downloads the Whisper model (~1.5 GB for `medium`) into a named volume so it persists between restarts.

---

## How it works

The default mode (`MODE=watch`) runs two phases:

1. **Initial batch pass** — scans all configured directories on startup, generating subtitles for any files that don't already have them. Safe to run repeatedly; existing `.{lang}.whisper.srt` files are skipped.
2. **inotify watcher** — after the batch pass completes, the container monitors the directories at the kernel level via `inotifywait`. When a new video file appears (either written directly or moved in by a download manager / \*arr app), it waits for the file to finish writing, then kicks off subtitle generation.

Each file goes through the subtitle strategy pipeline before any Whisper inference runs:

```
.{lang}.whisper.srt exists?  →  skip (idempotent)
        ↓ no
External .srt/.ass in matching language found?  →  align timing (fast path)
        ↓ no
Embedded text subtitle stream in matching language?  →  extract + align (fast path)
        ↓ no
Full Whisper transcription  →  slow path
```

The **smart strategy** (default) means files that already ship with subtitle text — Blu-ray rips with embedded Japanese tracks, official releases with external SRTs — get timing-aligned rather than re-transcribed. Alignment is typically 5–10× faster than full transcription since it skips speech recognition entirely. Files with no usable subtitles fall through to full transcription automatically.

Set `SUBTITLE_STRATEGY=transcribe` to always run full speech recognition regardless.

> **Network shares (NFS / SMB):** inotify is a Linux kernel feature and only works on locally-mounted filesystems. If your media lives on a NAS over NFS or SMB, use `MODE=batch` with an external cron job instead (see below).

---

## Directory layout

The default `SCAN_DIRS="."` scans everything recursively under `/media`, so any structure works:

```
/media/
├── movies/
│   └── Some Movie (2021)/
│       └── Some.Movie.2021.mkv
├── tv/
│   └── Some Show/
│       └── Season 01/
│           └── Some.Show.S01E01.mkv
└── home-videos/
    └── birthday-2024.mp4
```

If you want to limit the scan to specific subdirectories, set `SCAN_DIRS` to a space-separated list:

```yaml
SCAN_DIRS: "movies tv"   # ignores everything else under /media
```

Output SRT files are written next to the source video:

```
Some.Movie.2021.ja.whisper.srt
Some.Show.S01E01.ja.whisper.srt
```

---

## Configuration

All options are set via environment variables in `docker-compose.yml` (or with `-e` flags on `docker run`).

| Variable | Default | Description |
|---|---|---|
| `MODE` | `watch` | `watch` — react to new files via inotify. `batch` — single scan and exit. |
| `SUBTITLE_STRATEGY` | `smart` | `smart` — align existing subtitle text if found; fall back to transcription. `transcribe` — always run full speech recognition. |
| `MEDIA_ROOT` | `/media` | Root of the mounted media library |
| `SCAN_DIRS` | `.` | Space-separated subdirs of `MEDIA_ROOT` to scan. `.` scans the entire mount. |
| `WHISPER_LANGS` | `en` | Comma-separated Whisper language codes. Each produces its own SRT. |
| `STABLE_MODEL` | `medium` | Whisper model size: `tiny` `base` `small` `medium` `large` `large-v2` |
| `MODEL_DIR` | `/root/.cache/whisper` | Where downloaded models are cached |
| `LOG_FILE` | *(empty)* | Optional path to append logs inside the container |

### Multiple languages

```yaml
environment:
  WHISPER_LANGS: "ja,en"   # generates .ja.whisper.srt and .en.whisper.srt
```

The script picks the best matching audio track for each language separately, so dual-audio files (e.g. Japanese + English dub) are handled correctly.

### Model size trade-offs

| Model | VRAM | Relative speed | Quality |
|---|---|---|---|
| `tiny` | ~1 GB | ~10× | lower |
| `base` | ~1 GB | ~7× | lower |
| `small` | ~2 GB | ~4× | good |
| `medium` | ~5 GB | 1× (baseline) | very good |
| `large-v2` | ~10 GB | ~0.6× | best |

### CPU-only mode

Remove or comment out the `deploy` block in `docker-compose.yml`:

```yaml
# deploy:
#   resources:
#     reservations:
#       devices:
#         - driver: nvidia
#           count: 1
#           capabilities: [gpu]
```

PyTorch detects the absence of a GPU and falls back to CPU automatically.

---

## Windows

The container runs Linux internally, so the script and all its tools work the same regardless of host OS. There are two things to know for Windows specifically.

**Volume paths** use Windows syntax in `docker-compose.yml`:

```yaml
volumes:
  - C:\Users\You\Videos:/media
  # forward slashes also work:
  - C:/Users/You/Videos:/media
```

**Watch mode doesn't work reliably on Windows.** inotify is a Linux kernel feature and events don't propagate from Windows host volumes through the WSL2 layer into the container. Files added on the Windows side will not trigger automatic processing. Use `MODE=batch` instead and schedule it with Windows Task Scheduler:

1. Open Task Scheduler → Create Basic Task
2. Set your trigger (e.g. daily, or on login)
3. Action: Start a program
   - Program: `docker`
   - Arguments: `compose -f C:\path\to\whisper-docker\docker-compose.yml run --rm -e MODE=batch whisper`

**GPU on Windows** requires Docker Desktop with the WSL2 backend and an up-to-date NVIDIA driver. Enable it under Docker Desktop → Settings → Resources → GPU, then the `deploy` block in `docker-compose.yml` works as-is.

---

## Batch mode (cron / NFS setups)

If your media is on a network share (where inotify doesn't work), or you just prefer scheduled runs, set `MODE=batch` and trigger the container externally.

**One-off run:**

```bash
docker compose run --rm -e MODE=batch whisper
```

**Nightly cron job:**

```cron
0 3 * * * docker compose -f /path/to/whisper-docker/docker-compose.yml run --rm -e MODE=batch whisper
```

**systemd timer** (cleaner than cron on modern Linux):

```ini
# /etc/systemd/system/whisper-batch.service
[Unit]
Description=whisper-docker subtitle batch

[Service]
Type=oneshot
WorkingDirectory=/path/to/whisper-docker
ExecStart=docker compose run --rm -e MODE=batch whisper
```

```ini
# /etc/systemd/system/whisper-batch.timer
[Unit]
Description=Run whisper-docker nightly

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl enable --now whisper-batch.timer
```

---

## Viewing logs

```bash
# Live logs from the running watcher
docker compose logs -f

# Or if LOG_FILE is set, tail that directly
tail -f /path/to/your/whisper.log
```

---

## Track selection

The script uses a scoring system to pick the best audio and subtitle streams for each target language. It prefers language-tagged tracks, gives a bonus for descriptive titles (e.g. "Japanese 5.1"), and heavily penalises commentary and signs-only tracks. If no suitable track is found it falls back to the first audio stream.

Image-based subtitle formats (PGS, DVDSUB — common in raw Blu-ray rips) are excluded from the smart path since they can't be extracted to text. Files with only PGS subtitles fall through to full transcription automatically.
