# plex-balancer

A PowerShell tool that moves already-optimised media between drives to hit
per-drive free-space targets, so a multi-drive Plex library stops filling one disk
to 100% while another sits empty.

Storage balancing moves files without deleting media, re-encoding, or touching
Plex. Its only folder changes are recreating the file's existing folder at the
destination and removing empty source folders after a verified move. The separate
managed-playlist feature has an opt-in watched-head retirement setting; see
[Managed Plex playlist](#managed-plex-playlist).

```
C:\Downloads\Movies\  ->  K:\Movies\  ->  D:\Movies\  ->  F:\Movies\  ->  G:\Movies\  ->  H:\  ->  J:\
(landing zone)            (USB)         (internal)       (USB)         (NVMe)       (exFAT)   (stick)
```

---

## Requirements

For managed playlist ordering, missing-item recovery and update notifications,
see [PLAYLIST.md](PLAYLIST.md). The manager edits only the configured copy with
`-Apply`; it never deletes media or edits the original manual playlist.

Windows 10 or 11, and nothing else. No modules to install, no runtime, no Python.

Developed against Windows PowerShell 5.1, which ships with the OS. It uses
`Get-Partition`, `Get-WinEvent`, `Get-ScheduledTask` and `Get-FileHash`, all of
which are present on a stock Windows install. It is **not** tested on PowerShell 7
and does not need it.

The scheduled task is optional. Everything works from a plain shell.

---

## Quick start

```powershell
git clone <url> plex-balancer
cd plex-balancer

Copy-Item .\config.example.json .\config.json
notepad .\config.json          # your drives, your library roots

powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1   # prove it works
powershell -ExecutionPolicy Bypass -File .\balance.ps1     # dry run, moves nothing
```

`balance.ps1` is a **dry run unless you pass `-Apply`**. Read its output. It tells
you what it would move and where, and touches nothing.

```powershell
powershell -File .\balance.ps1 -Apply     # actually move
```

To leave it running on its own, register the task - see
[Scheduled task](COMMANDS.md#scheduled-task) in `COMMANDS.md`.

`config.json` is deliberately **not** in this repository, because it names your
drive letters and folder paths. `config.example.json` is the committed template.

---

## What the four scripts do

| Script | Job |
|---|---|
| `balance.ps1` | The worker. Measures every drive, plans moves, performs them. |
| `watch.ps1` | The loop. Polls free space, then runs reconcile and balance only when there is slack. |
| `reconcile.ps1` | Repairs whatever a killed run left behind. |
| `status.ps1` | Live view, from a second window. |
| `Run-Tests.ps1` | Runs every test suite and gives one verdict. |

A normal unattended cycle is `watch.ps1`: reconcile first, then balance, then prune
expired logs and snapshots.

### Managed Plex playlist

When `maintenanceEnabled` is `true` in the local `playlist.config.json`, the hourly
watcher also runs `playlist-manager.ps1`. It updates only the configured managed
playlist; the source playlist and media files are not changed. The manager keeps
durable queue intent so a temporary Plex or storage problem does not silently
rewrite the viewing order.

- TV rotation follows alphabetical show order, with episodes ordered by season and
  episode. It stops at the first blocked show rather than jumping ahead or starting
  another cycle. A 25-show rotation can therefore pause with 24 usable shows when
  the next slot is blocked.
- A standby series can fill that slot only when Plex already has an unwatched
  episode downloaded locally. Merely being announced, released, or downloadable
  is not enough. Missing released episodes on the outgoing show also prevent a
  replacement.
- Already watched episodes are skipped. For example, after Penn & Teller S11E06
  and S11E07 were watched, the next queued episode is S11E08; it follows Parks and
  Recreation S05E04 in the current rotation.
- Preserve selected movie/franchise order and related documentary sequences, such
  as the Louis Theroux group. Do not append unrelated random films after the
  selected sequence ends.
- A missing Plex playlist entry is not proof that its media was deleted or watched:
  a drive can be temporarily unavailable, Plex can be rescanning, or a file can
  move. Keep the item's intended queue position, notify and retry recovery when
  storage is accessible. Do not write a shortened playlist while any intended item
  remains unresolved. Recovery is limited to the managed copy and does not empty
  Plex trash or delete media.
- Watched queue-head retirement is part of playlist maintenance. With
  `watchedFileDeletion: true`, an apply permanently deletes consecutive watched
  episode files at the managed queue head after Plex session checks and with a
  durable recovery transaction. It never skips past an unwatched head item. Set
  the option `false` to keep media files untouched.

See [PLAYLIST.md](PLAYLIST.md) for the manager commands, durable recovery details,
and playlist-specific tests. Local queue state and configuration are Git-ignored.
Portable diagnostic helper templates are committed as `check-mutex.template.ps1`,
`check-standby.template.ps1`, and `verify.template.py`; machine-specific working
copies with the shorter names are ignored.

---

## The parts that are not obvious

Most of what makes this safe is invisible when it works. These are the decisions
worth knowing about before you trust it with your library.

**A failing disk is gated on reads, not on hope.** If Windows logs hardware or
paging errors against a disk, the balancer refuses to *read* that drive. A failing
disk retries rather than failing, so a recursive scan of one does not error out -
it blocks, and the run hangs until it is killed. This is not theoretical: it is why
the tool exists. The gate is time-based and clears itself after
`driveErrorWindowHours`, and it deliberately does not block writes - see
[Known gaps](COMMANDS.md#known-gaps) for why that half is open.

**The parking lot is declared, not derived.** The last drive in the chain is read
from `priority` in `config.json` and nothing else. An earlier version inferred it
from whichever drives happened to be sources on a given run, and when one drive was
absent the cascade reversed - content moved *uphill*, every hour, planning the same
move forever. `tests\cascade-direction.ps1` exists to make that unrepeatable.

**The source is deleted only after the copy is verified.** Verification is
`size` by default - file count plus total length - or `hash` for SHA256 of every
file, set with `"verify": "hash"` in `config.json`. `balance.ps1 -Hash` forces
hashing for one run regardless of the config. Any value other than `size` or `hash`
is refused at startup rather than quietly treated as `size`. On a failed check the
source is kept and the copy is left for `reconcile.ps1` to deal with.

After a verified move removes its source file, any now-empty Season/Show folders
are removed up to (but never including) the configured library root. Folders
containing other files, including hidden files, are left alone. Dry runs do not
remove folders.

Note that hashing reads every byte of both copies, which on a slow drive is most
of a large move. It is a real cost, not a formality - `size` catches truncation and
miscounts, not corruption.

**An interrupted run heals itself.** A partial copy on the destination is detected
on the next cycle by comparing the same filename across every configured root,
removed, and the source left alone. This runs *before* balance every cycle, so a
run killed by a timeout costs a wasted copy and an hour of delay, not data.

**Reclaiming the Recycle Bin measures what it freed.** Library media you deleted in
Explorer is destroyed on the next run, before planning, so the space counts in the
same run. After deleting, the volume is read again and compared against what was
expected, per volume - because a deleted file can be held open or sparse, and a
purge that freed nothing should not be logged as one that freed 17 GB. The
original location of each item is read out of its `$I` record, since that is the
only place it exists once the shell is out of the picture. **An item whose origin
cannot be read is left alone.** The format is undocumented by Microsoft, so the
parser refuses anything it does not recognise rather than guessing.

**Downloads are asked about, not guessed at.** A file is held while qBittorrent
still lists the torrent that owns it - the specific files the torrent contains, not
its containing folder. Media you have finished watching becomes movable the moment
you remove the torrent from the client, rather than a flat 24 hours after it was last
written. If qBittorrent is not running it is started for the check and closed again
afterwards; if it cannot be reached even then the older time-based rule takes over,
so a half-written file is never moved. Set `"downloadGuard": {"enabled": false}` to
turn it off.

**Nothing moves backwards.** Every destination is further along the chain than its
source, or outside the chain entirely (`H:` and `J:`, which have no priority). There
is no give-back and no give-back ledger. Both existed, and together they produced
exactly the ping-pong they were meant to prevent: a file would travel forward, be
handed back one step, and travel forward again — each copy paid for in full and
undone an hour later, and the last leg could strand the file on a drive that could
no longer pass it on.

**One balancer at a time.** `balance.ps1` takes a named mutex. A manual run started
while the watcher is mid-run reports "already in progress" and exits, rather than
two processes racing over the same file.

---

## Safety properties, plainly

- **Dry run is the default.** `-Apply` is required to move anything.
- **Nothing is committed to this repo that names your machine.** `config.json`,
  `logs\` and `backup\` are all ignored. See
  [Config](COMMANDS.md#config).
- **The log prune cannot reach media.** It matches three exact filename patterns and
  only ever looks at files sitting directly inside `logs\`.
- **Backup snapshots expire.** `backup\` is swept on the same clock as the logs, so
  old working copies do not accumulate forever.
- **A dry run cannot delete anything.** This sounds obvious. It was not: the log
  prune once read a `$DryRun` variable it had never declared, so a caller passing
  `-DryRun` got `$null` instead of a switch and the "dry run" deleted real logs.
  Both prunes now declare it, and `tests\retention.ps1` fails if that regresses.

---

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1
```

```
CHECK  preflight
--------------------------------------------------------------------------
  ok   13 script(s) parse
  ok   8 test file(s) are pure ASCII
  ok   config.example.json parses; local config.json present

RESULT
--------------------------------------------------------------------------
  6 suite(s) run, 193 checks reported (193 passed, 0 failed)
  PASS
```

Exit code 0 only when everything passes, so it can gate a commit. Exit 2 means you
asked for a suite that does not exist.

Suites **lift the real functions** out of the shipping scripts by parsing them,
rather than keeping copies. A renamed or deleted function fails the suite loudly
instead of quietly passing against a stale copy. One suite goes further and pulls a
regex literal out of the source text, because the bug it guards against - a pattern
that only matched English event wording on a Portuguese machine - would otherwise
stay invisible until a real disk failed.

`tests\recycle-bin.ps1` runs the real reclaim pass over a throwaway `subst` volume
and proves that a personal file, a corrupt header and an orphaned `$I` record all
survive while library media is destroyed. It covers both bin layouts - the
per-account folder that fixed volumes use, and the flat one removable and exFAT
volumes use.

---

## Full documentation

[`COMMANDS.md`](COMMANDS.md) is the reference: every config key, every log event,
the failure modes, the undo procedure, and an honest list of
[known gaps](COMMANDS.md#known-gaps) including the one that is deliberately left
open.

## Licence

None yet. Add one before publishing if you intend others to use it.
