# bambu-timelapse-sync

Bambu Lab printers record a timelapse of every print onto their SD card and
then leave it there forever. The only built-in way to get one off is Bambu
Studio's **Device → Storage** panel, one click at a time, and the card fills up.

This is a small container that does the same job on a schedule: it copies every
finished timelapse onto storage you control, verifies the copy, and only then
deletes it from the printer.

- **Verifies before deleting.** A file is removed from the printer only after a
  byte-for-byte size match against the copy on disk. A failed or short download
  leaves the original exactly where it was.
- **Skips prints that are still running.** The printer's FTP timestamps are not
  trustworthy, so the container lists the card twice a few seconds apart and
  ignores anything whose size is still changing.
- **Grabs the thumbnails too**, so nothing is orphaned on the card.
- **Safe to run repeatedly.** Files already stored are skipped, and overlapping
  runs cannot happen.

It talks to the printer over the same implicit FTPS service on port 990 that
Bambu Studio itself uses — no cloud account, no Bambu API, nothing leaves your
network.

## Quick start

```yaml
services:
  bambu-timelapse-sync:
    image: ghcr.io/pmaxhogan/bambu-timelapse-sync:latest
    container_name: bambu-timelapse-sync
    restart: unless-stopped
    environment:
      PRINTER_HOST: 192.168.1.50    # your printer's IP
      ACCESS_CODE: abcd1234         # LAN access code from the printer screen
      SYNC_INTERVAL: 3600           # check once an hour
      TZ: Etc/UTC
    volumes:
      - ./timelapses:/data
```

```sh
docker compose up -d
docker compose logs -f
```

The first run may take a while if the card has a backlog. Watch the log — every
file is reported as it is saved and freed.

### Finding the LAN access code

On the printer: **Settings → Network → LAN Only Mode** (wording varies slightly
by model). The access code is the 8-character string shown there. It changes if
you regenerate it, at which point the container will log an authentication
failure until you update the variable.

The printer must have a stable address, so give it a DHCP reservation on your
router before pointing the container at an IP.

## Configuration

Everything is set through environment variables.

| Variable | Default | What it does |
| --- | --- | --- |
| `PRINTER_HOST` | *required* | Printer IP or hostname. |
| `ACCESS_CODE` | *required* | LAN access code from the printer screen. |
| `SYNC_INTERVAL` | `3600` | Seconds between passes. `0` runs one pass and exits, which is handy for a host cron or a one-off catch-up. |
| `RUN_ON_START` | `true` | Sync immediately on startup instead of waiting out the first interval. |
| `SETTLE_SECONDS` | `15` | Gap between the two listings used to detect a print that is still recording. |
| `LAYOUT` | `month` | `month` files into `videos/YYYY-MM/`; `flat` puts everything in one directory. |
| `DOWNLOAD_THUMBNAILS` | `true` | Also copy the preview images. |
| `KEEP_REMOTE` | `false` | Download only; never delete anything from the printer. |
| `DRY_RUN` | `false` | Report what would happen and touch nothing, on either side. |
| `PRINTER_PORT` | `990` | FTPS port. |
| `FTP_USER` | `bblp` | FTP username. The same on every Bambu printer. |
| `PUID` / `PGID` | unset | Own the saved files as this uid/gid instead of root. |
| `TZ` | `UTC` | Timezone for log timestamps. |

Take a first look with nothing at stake:

```sh
docker compose run --rm -e DRY_RUN=true -e SYNC_INTERVAL=0 bambu-timelapse-sync
```

## What lands on disk

```
/data
├── videos/2026-04/video_2026-04-24_13-12-25.mp4
└── thumbnails/2026-04/video_2026-04-24_13-12-25.jpg
```

Plain files with the printer's own names — nothing proprietary, no database, no
sidecar state. The container works out what it already has by looking at the
directory, so you can move, rename, or archive anything at any time.

## Notes

- Timelapses are read from the printer's **removable SD card**, which is what
  the "External" tab in Bambu Studio shows.
- Tested against an X2D. The FTPS interface is shared across the current Bambu
  line, so other models are expected to work; reports welcome either way.
- The printer presents a self-signed certificate, so the container does not
  verify it. Credentials still travel inside the TLS session, and the traffic
  never leaves your LAN.
- Timelapses only exist if timelapse recording is enabled in your print
  settings.

## Troubleshooting

**`cannot list /timelapse`** — the printer is asleep, unreachable, or the access
code is wrong. Check that the printer answers on port 990 from wherever the
container runs.

**Files download but are never deleted** — `KEEP_REMOTE` is on, or the delete is
being refused. The log distinguishes the two, and a local copy is always kept
either way.

**Something is stuck as "still recording"** — that is the guard working. A print
in progress is left alone until its timelapse stops growing.

## Building it yourself

```sh
docker build -t bambu-timelapse-sync .
```

Images are built for `linux/amd64` and `linux/arm64` and published to GHCR on
every push to `main`.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Bambu Lab.
