# plex-balancer

A PowerShell tool that moves already-optimised media between drives to hit
per-drive free-space targets, so a multi-drive Plex library stops filling one disk
to 100% while another sits empty.

It moves files. It never deletes media, never re-encodes, never touches your Plex
server, and never rewrites a library's folder structure beyond recreating the
folder a file already belonged to.

```
C:\Downloads\Movies\  ->  D:\Movies\  ->  G:\Movies\  ->  F:\Movies\
(landing zone)            (internal)       (NVMe)          (parking lot)
```

---

## Requirements

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

**The source is deleted only after the copy is verified.** Default verification is
size plus file count. `balance.ps1 -Hash` compares SHA256 instead, at the cost of
reading both files end to end. On a failed check the source is kept and the copy is
left for `reconcile.ps1` to deal with.

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

**Give-backs are remembered.** When the balancer hands a file back up the chain to
free room for something bigger, it records that in `logs\givenback.json` and will
not take that file back for 7 days. Otherwise a marginal file ping-pongs between two
drives every hour, burning hours of I/O and achieving nothing.

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
survive while library media is destroyed.

---

## Full documentation

[`COMMANDS.md`](COMMANDS.md) is the reference: every config key, every log event,
the failure modes, the undo procedure, and an honest list of
[known gaps](COMMANDS.md#known-gaps) including the one that is deliberately left
open.

## Licence

None yet. Add one before publishing if you intend others to use it.