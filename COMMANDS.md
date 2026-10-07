# Plex Storage Balancer - Command Reference

Every command for the toolset in `%USERPROFILE%\plex-balancer`.

**Everything is a dry run unless you pass `-Apply`.** That is deliberate: the
balancer moves real media, and it will never touch a file you have not asked it
to.

- [What is in the folder](#what-is-in-the-folder)
- [Running the scripts](#running-the-scripts)
- [Tests](#tests)
- [Scheduled task](#scheduled-task)
- [Config](#config)
- [Logs](#logs)
- [Checking disk space](#checking-disk-space)
- [Execution policy](#execution-policy)
- [Routine](#routine)
- [Troubleshooting](#troubleshooting)
- [Undo](#undo)
- [Known gaps](#known-gaps)

---

## What is in the folder

| File | Purpose |
|---|---|
| `README.md` | The front door: what it is, how to run it, and the decisions worth knowing. Start there; this file is the reference. |
| `balance.ps1` | The worker. Plans and performs moves. |
| `watch.ps1` | Poller. Runs reconcile, prunes expired logs, then balance when room appears. |
| `reconcile.ps1` | Repairs runs that were interrupted mid-copy. |
| `status.ps1` | Live view of what is running right now. |
| `config.json` | Your policy: drive roles, limits, thresholds. **Not committed** - it names your drive letters and paths. Copy `config.example.json` and edit that. |
| `config.example.json` | The committed template, with placeholder paths. Copy it to `config.json` on a new machine. |
| `logs\` | JSONL audit logs, one file per day, pruned after `logRetentionDays`, plus two state files that are never pruned: `state.json`, and `diskmap.json` (which physical disk held each failing disk number, so errors can be attributed to the right drive - see [Failing drives](#failing-drives)). |
| `Run-Tests.ps1` | Runs every suite and reports one verdict. Start here - see [Tests](#tests). |
| `COMMANDS.md` | This file. |
| `tests\` | Test suites. Run them before trusting a change - see [Tests](#tests). |
| `backup\` | Snapshots and working copies. Expires on `logRetentionDays`; never committed. |

Drive roles as currently configured.

Sources are offered in `priority` order, and the balancer falls through to the
next one only when everything above it has been tried and nothing fit:

**C: → K: → D: → F: → G:**

| Drive | Role | Priority | Notes |
|---|---|---|---|
| C: | source | 1 | Download landing zone. Drains whenever any sink has room. **Never a sink** - see below. |
| K: | source + sink | 2 | USB. Sheds what it cannot hold, and accepts down to **0.5% free** - the one sink that holds space back. |
| D: | source + sink | 3 | Fills completely. Starts shedding once under 5% free. |
| F: | source + sink | 4 | USB. Fills completely, then pushes to `G:`, `H:` and `J:`. |
| G: | source + sink | 5 | Internal NVMe. Fills completely, then pushes to `H:` and `J:`. **The parking lot** - see below. |
| H: | source + sink | - | exFAT. Fills to **0** free, then pushes to `J:`. 50% rule off. Not a chain link. |
| J: | sink | - | exFAT, removable. Fills to **0** free. Max 8 GB per file. 50% rule off. Not a chain link, and the end of the road. |

**Every sink fills completely except `C:` and `K:`.** `D:`, `F:`, `G:`, `H:` and `J:`
all have a target of `0`, which means no floor at all - they accept until the
volume is physically full. The two exceptions are deliberate and different in kind:

- **`C:` holds its space by role, not by target.** It is `sources: true` with no
  `alsoSink`, and both `balance.ps1` and `watch.ps1` skip a drive in that shape
  when building the sink list, so `C:` can never be a destination and its free
  space is never spent. Downloads land there first, and it keeps the most room on
  the machine by construction. Adding a target to `C:` would be dead config that
  reads as though it were doing something.
- **`K:` holds space back on purpose**, with `targetFreePct: 0.5` - about 4.7 GB on
  a 931 GB drive. It is a real sink, so the value is live.

**The chain runs one way.** Among the five chain drives, content may move forward
to a drive with a *higher* priority number, never back to a lower one. `H:` and
`J:` sit outside the chain and are open to every source:

```
                    forward only                open to every source
  C:  (1)  ->   K:   D:   F:   G:        +      H:    J:
  K:  (2)  ->         D:   F:   G:        +      H:    J:
  D:  (3)  ->                 F:   G:        +      H:    J:
  F:  (4)  ->                         G:        +      H:    J:
  G:  (5)  ->                                 +      H:    J:
```

So `F:` content can land on `G:` but never back on `D:`, and `D:` content can never
land on `C:` or `K:`. Without this rule the destination was chosen purely by
whichever drive had the least room, and a file lifted off `G:` would land on `D:`
- a drive already being drained - which reversed the ordering.

**`H:` and `J:` are reachable from every source, forward and backward alike.**
They declare no `priority`, so they are not chain links and the one-way rule never
applies to them. `C:`, `K:`, `D:`, `G:` and `F:` may all move content there. They
are also `sources: false`, so they never give content back and the relationship
is one-way by omission. What they accept is governed separately:

| | H: | J: |
|---|---|---|
| Accepts | any file | `maxUnitGB: 8` - small files only |
| 50% rule | **off** - `exemptHeadroomRule` | **off** - `exemptHeadroomRule` |
| Fills until | 0 - completely full | 0 - completely full |

The exemption is honoured in both places the rule is applied - when a
destination is picked, and again immediately before the copy starts - so a
destination on `H:` or `J:` is never held back by the 50% margin. The `8 GB`
cap on `J:` is a separate limit and still applies.

**Nothing ever moves backwards, and `G:` is no exception.**

`G:` used to be permitted one step back to `F:` as a *give-back*: content that
landed on the last drive had nowhere further to go, so handing it upstream would
"keep that space in circulation". In practice it did the opposite. `F:` and `G:`
traded the same files back and forth across runs, each copy paid for in full and
undone an hour later, and on 2026-10-06 the last leg left three files stranded on
a full `F:` that could reach neither `G:` (refused) nor `H:`/`J:` (full). The chain
ends at `J:` because `J:` is the end of the road, not because the drive before it
needs to hand content back.

**The one gate that remains is on receiving, not sending.** `G:` is last in the
chain, so it accepts from `F:` only when something is genuinely waiting for room
on `F:`. The balancer tracks how many units were turned away from each drive for
lack of space earlier in the run, and only opens that route when the count for
`F:` is above zero. Without it `F:` would spend every run relocating its own
library into a drive that has nowhere to pass it onward.

This gate **cannot grant a move the direction check refused** - it only ever
removes destinations from the candidate list. `G: -> F:` is refused by the
direction rule before the gate is ever consulted, no matter how much is waiting.
`tests\shed-gate.ps1` asserts that directly, with the demand figure set absurdly
high, because a gate that can add permissions is not a gate.

**The last drive in the chain is a declared role, read from `config.json`** - not
worked out from the drives that happen to be in use. This matters, and getting it
wrong was a real bug. The end of the chain used to be taken from whichever drives
were sources or sinks *on that run*. When `F:` was absent from both - unplugged,
full, or simply `sources: false` - the highest priority present collapsed from 5 to
`G:`'s 4, `G:` was crowned parking lot, and the give-back rule then correctly sent
`G:` content **backwards** to `D:`. Observed live on 2026-10-04: four files moved
`G: -> D:` in one apply run, and planned on every run since 2026-10-03 16:05. The
role assignment was wrong, not the rule. A drive inherits the role only because
`config.json` says it is last.

#### There is no give-back ledger any more

There used to be one. Because the give-back was a loop, a ledger recorded every
give-back so the parking lot would not take the same unit straight back in -
`logs/givenback.json`, entries expiring after 7 days. With backwards movement
removed there is no give-back to record, and the ledger had no writer left: it was
still read every run, still pruned every run, and still documented as a protection
that no longer existed. It has been deleted rather than left dormant.

The three files that were stuck on the ledger are free again.

Skip reasons in the run output:

| Reason | Meaning |
|---|---|
| `skip (cascade)` | Nothing downstream of this drive has room. |
| `skip (no demand)` | The parking lot was the only option, and nothing upstream is waiting for the room it would free. |

Any *source* that declares no `priority` is likewise left unrestricted rather
than frozen, since there is no position to compare it against.

**`alsoSink` is mandatory on any source.** A drive with `sources: true` and no
`alsoSink` is dropped from the destination list entirely, so it can only give
content away and never receive it. That is the intent for a pure source, but on a
drive that also needs to be filled it silently removes the drive as a target.

**The cascade redistributes, it does not create space.** A move takes bytes off
one drive and puts the same bytes on another, so the total free space across the
library never changes. When every drive is full the cascade will shuffle content
between F:, D: and G: and finish with exactly as much room as it started with.
It is not a way to fix "I am out of space" - only deleting content or adding a
drive does that.

---

## Running the scripts

Run them from the folder or use full paths:

```powershell
cd %USERPROFILE%\plex-balancer
```

### `balance.ps1` - moves media

```powershell
.\balance.ps1                          # dry run: plan and report, moves nothing
.\balance.ps1 -Apply                   # actually move
.\balance.ps1 -Report                  # drive status only, no planning
.\balance.ps1 -Hash                    # verify with SHA256 instead of file size
.\balance.ps1 -Apply -Hash             # move, verifying with SHA256
.\balance.ps1 -ConfigPath D:\other.json    # run against a different policy
```

| Switch | Effect |
|---|---|
| `-Apply` | Without this, nothing is moved. |
| `-Report` | Print drive status and exit. Fastest way to see current state. |
| `-Hash` | Verify the copy by SHA256 instead of byte count. Catches two files of equal length with different content. Slow on large files. |
| `-ConfigPath` | Use a different config file. |

`-Hash` is worth it for anything you care about. Byte-count verification is what
the unattended runs use, because hashing a 10 GB file takes minutes.

#### Recycle Bin reclaim

Every run, before the move phase, checks the Recycle Bin for media that was
deleted out of a configured library root and destroys it, so the space comes
back before anything tries to move. It runs before the drive free-space figures
are read, so what it frees is available to planning in the *same* run rather
than the next one.

> **On by default again as of 2026-10-05**, after the pass was rewritten. It is
> no longer the risky thing in the run. Set `"recycleReclaim": false` in
> `config.json` to switch it back off.
>
> The version that was switched off on 2026-10-03 asked the shell for the Recycle
> Bin. That namespace is *shell-wide*, so enumerating it walked `$Recycle.Bin` on
> every mounted volume - including two drives then logging hardware errors - and a
> COM enumeration cannot be given a timeout. It now walks each volume's
> `$Recycle.Bin\<SID>` folder by path instead. Three things follow from that:
>
> - It only ever looks at volumes that hold library media, because the origin
>   check can only match a configured root.
> - It is bounded. Only the top level of each SID folder is listed, and the only
>   file read is the small `$I` header.
> - It does **not** sit behind the [failing-drive gate](#failing-drives). That
>   gate exists for the library scan, where 2026-10-03 proved that walking tens
>   of thousands of files on a retrying disk blocks instead of erroring. Emptying
>   a bin is a shallow listing plus a few header reads and deletes, and Explorer's
>   own Empty Recycle Bin does more work on the same files - so a failing disk
>   costs a drive its read protection, not its bin space.
>
> It also now **measures what it freed** instead of reporting what it expected to
> free — see [Verification](#recycle-bin-verification).

```
RECYCLE BIN
--------------------------------------------------------------------------
     14,98GB  Some.Movie.2025.2160p.WEB-DL.mkv                  [D:]
      2,23GB  Another.Show.S02E06.1080p.WEB-DL.mkv               [F:]

  destroyed 2 item(s) across 1 volume(s) before the move phase
  D:  freed 17,21GB of an expected 17,21GB
```

Rules:

- **Only library media is destroyed.** An item qualifies by *where it was
  deleted from* matching a `roots` entry in `config.json` — not by its filename.
  The origin is read out of the item's `$I` record, because there is nowhere else
  to get it once the shell is out of the picture. Anything from anywhere else,
  including plain `Downloads`, is left alone.
- **An unreadable origin means left alone.** If the `$I` record does not parse,
  the layout is not one this code knows, or the path is truncated, the item is
  skipped and counted in `left N item(s) alone`. The `$I` layout is undocumented
  by Microsoft, so this is the only safe direction: a wrong answer here is
  indistinguishable from no check at all.
- **Two bin layouts are handled.** A fixed volume keeps one folder per account and
  the `$I` records sit inside it. **A removable or exFAT volume has no such folder
  and puts them directly in `$Recycle.Bin`** - that is H: and every USB stick, so
  both levels are listed. Only these two levels are ever enumerated; nothing
  recurses into a payload tree.
- **A metadata record with no payload is reported, not ignored.** `$I` files
  outlive their `$R` payload - an emptied bin leaves zero-length stubs behind. There
  is nothing to free, but a stale record is what makes an entry linger in Explorer,
  so the run says
  `N entry/entries have a metadata record but no payload left` and you clear them by
  hand.
- **It is permanent.** `Remove-Item -Force` on the `$R` payload, plus the `$I`
  metadata record. There is no second chance, and no undo entry.
- **Only with `-Apply`.** A dry run lists exactly what it would destroy and
  deletes nothing.
- **Only your own items.** The task runs as your own account, so another account's
  deletions on the same drive are not visible and cannot be touched.
- **It cannot block a run.** If anything in it throws, it warns and the balancer
  carries on to the move phase.

#### Recycle Bin verification

Destroying a file does not guarantee the bytes come back — it can be held open,
sit behind a reparse point, or be sparse. So after the purge the balancer reads
`AvailableFreeSpace` on each affected volume again and compares it against the
figure it expected, per volume:

```
  D:  freed  8,10GB of an expected 17,21GB
```

Anything short of 90% of the expected figure is a warning, and both numbers are
logged as a `recycle_verify` event per volume:

| field | meaning |
| --- | --- |
| `drive` | the volume, e.g. `D:` |
| `expectedGB` | the size of the items destroyed from that volume |
| `freedGB` | the measured change in free space, which may be negative |
| `verdict` | `ok`, `short` (freed under 90% of expected) or `unmeasurable` |

`status.ps1` shows one row per volume, with the measured figure in SIZE and the
expected figure beside it, so a purge that did not work reads as:

```
  09:05:13  bin verified    F:           0,40GB         -  expected 2,23GB (18%)
```

The verdict is decided once, in `balance.ps1`, and written into the event, so
that `status.ps1` cannot end up applying a different tolerance than the run that
produced the row. A `short` verdict means the entries may still be listed in
Explorer even though the log says they were destroyed.

This matters because the summary line it replaced reported the *estimate*. A
purge that silently freed nothing was logged as a purge that freed 17GB, and
nothing downstream could tell.

The balancer's own deletes never land here — every one of them is
`Remove-Item -Force`, which bypasses the Recycle Bin — so what it destroys is
always something you deleted by hand in Explorer, and only if it was library
media.

### `reconcile.ps1` - repairs interrupted runs

```powershell
.\reconcile.ps1                        # report what it found, change nothing
.\reconcile.ps1 -Apply                 # repair
.\reconcile.ps1 -Hash -Apply           # verify with SHA256 before removing anything
```

Safe to run at any time. Finds partial and duplicate copies by filename across all
roots. It takes the same mutex as the balancer, so if a run is in progress it
declines rather than interfering.

### `status.ps1` - see what is happening

```powershell
.\status.ps1                           # one snapshot
.\status.ps1 -Watch                    # live view, refreshes every 30s
.\status.ps1 -Watch -RefreshSeconds 5  # closer look while diagnosing
.\status.ps1 -Tail 30                  # more log history
```

| Switch | Default | Effect |
|---|---|---|
| `-Watch` | off | Redraw on a timer instead of exiting. |
| `-RefreshSeconds` | 30 | How often `-Watch` redraws. |
| `-Tail` | 12 | How many log lines to show. |

The **DRIVES** table lists drives in the order given by `statusDisplayOrder` in
`config.json`:

```
DRIVE FORMAT         TOTAL       FREE   FREE%  ROLE
C:     NTFS         953,0GB    239,5GB   25,1%  source
K:     NTFS         931,5GB     18,2GB      2%  source + sink
D:     NTFS         953,9GB      9,0GB    0,9%  source + sink
F:     NTFS         931,5GB      1,2GB    0,1%  source + sink
G:     NTFS         930,8GB      1,0GB    0,1%  source + sink
H:     exFAT      1.863,0GB      0,0GB      0%  sink
J:     exFAT        116,5GB      0,0GB      0%  sink
```

**`statusDisplayOrder` is cosmetic and cannot affect behaviour.** `balance.ps1`
never reads it - only `status.ps1` does - so it cannot change what gets moved
where, and the cascade still runs `C: -> K: -> D: -> G: -> F:` regardless of
how the table is arranged.

Delete the key and the table reverts to `priority` order, with drives that
declare no `priority` last.

### `watch.ps1` - the polling loop

```powershell
.\watch.ps1                                # loop forever, every 60 min, applies moves
.\watch.ps1 -IntervalMinutes 5             # poll more often
.\watch.ps1 -Once                          # single check then exit (what the task runs)
.\watch.ps1 -Once -DryRun                  # single check, moves nothing
.\watch.ps1 -MinSlackGB 5                  # only react when 5+ GB of room appears
.\watch.ps1 -StartupDelaySeconds 300       # wait 5 min at startup, for USB drives
.\watch.ps1 -BalanceTimeoutSeconds 900     # kill a balancer run after 15 min
.\watch.ps1 -ReconcileTimeoutSeconds 300   # kill a reconcile run after 5 min
```

#### Timeouts and the in-flight check

Both protections exist because of 2026-10-03, when a hung `balance.ps1` took
the watcher down with it.

**Children run under a hard timeout.** `balance.ps1` and `reconcile.ps1` are
started as separate processes and waited on with a deadline, so a run that stops
responding is killed rather than waited on forever. `Stop-Process` is used
deliberately: a thread blocked in a failing disk's I/O cannot be asked to stop
politely, it has to be killed. A normal run takes about 15 seconds, so
`-BalanceTimeoutSeconds 1800` (the default) is a very generous ceiling - it is
there to catch a hang, not to pace normal work.

When a run is killed the watcher says so and stops for that cycle. Anything the
run had already copied is left behind on purpose; `reconcile.ps1` repairs it on
a later cycle.

**A cycle will not start on top of a running one.** The task fires hourly *and*
at logon, so a second watcher can begin while the first is still scanning. Each
cycle first asks whether the `Global\PlexBalancer` mutex is already taken, and
if it is, skips reconcile and balance and says so. The mutex is the authority
because `balance.ps1` holds it for the whole run.

If you ever see this line, the previous cycle did not finish - the log entry
immediately above it is where to start looking.

```
[WARN ] a balancer run is still in progress - skipping reconcile and balance this cycle
```

| Switch | Default | Effect |
|---|---|---|
| `-IntervalMinutes` | 60 | Poll period when looping. The scheduled task does not use this - it runs `-Once` and relies on the task trigger instead. |
| `-Once` | off | One pass and exit. This is what the scheduled task uses. |
| `-DryRun` | off | Never move, just report. |
| `-StartupDelaySeconds` | 90 | Wait before the first check, so USB drives finish mounting. |
| `-MinSlackGB` | 1.0 | Only fire when a sink gains at least this much room. |

You rarely run this by hand. The scheduled task handles it.

---

## Tests

```powershell
# everything: preflight, then all ten suites, then a verdict
powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1

# quick go/no-go - just the summary table and the verdict
powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -Quiet

# one suite
powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -Suite watchdog

# what would run, without running it
powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -List

# give a wedged suite 20 minutes instead of the default 15
powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -TimeoutSeconds 1200
```

`Run-Tests.ps1` is the only entry point - it runs the suites itself, in a child
`powershell` each. Exit codes:

| Code | Meaning |
|---|---|
| **0** | Every suite that ran passed. Suites that skipped do not count as passes - see below. |
| **1** | Preflight failed, or at least one suite failed. |
| **2** | Usage error: `-Suite` named something that does not exist. Prints the real names. |

Each suite runs as its own process on purpose: they lift functions by defining
them in their own scope, and the watchdog suite takes and releases the balancer's
real mutex. Sharing a process would let one suite's leftovers decide the next
suite's answer. `-TimeoutSeconds` (default 900) kills a suite that overruns,
along with any children it started, so one wedged suite cannot stall the run - or
leave a child holding the mutex the next suite needs.

**A suite can SKIP, and a skip is not a pass.** `tests\watchdog.ps1` exits 3 when
the balancer is mid-run. That suite asserts on whether `Global\PlexBalancer` is
free, so a scheduled run firing while it executes makes those assertions fail for
a reason that has nothing to do with the code under test - observed on 2026-10-07,
when the hourly task started at 00:40 and two checks failed while the watcher was
working perfectly.

So the suite **waits** for the machine to go quiet (up to 30 minutes,
`PB_TEST_QUIET_WAIT` to change it) and only skips if that wait runs out. A skip:

- is reported on its own `SKIP` line, never as `PASS`
- does not fail the run - the verdict reads `PASS with skips`
- cannot end in a bare green tick, because the summary names what did not run

A skip that silently became a pass would be worse than the original failure: the
suite would go on reporting success for a check it never made.

Before any suite runs it checks three things that the suites could not report
about themselves, and stops if any fails:

- **Every script parses.** A syntax error in `balance.ps1` is not a test failure,
  it is a suite that cannot load the function it was trying to lift.
- **Every test file is pure ASCII.** `powershell -File` reads a script as ANSI, so
  one accented byte turns a path comparison into a failure that looks nothing like
  an encoding problem.
- **`config.example.json` parses.** `config.json` is not committed, so a fresh
  clone falls back to the example - and without the example the cascade suite
  fails with a complaint about drives rather than about the missing file.

```
CHECK  preflight
--------------------------------------------------------------------------
  ok   18 script(s) parse
  ok   13 test file(s) are pure ASCII
  ok   config.example.json parses; local config.json present

SUMMARY
--------------------------------------------------------------------------
  PASS cascade-direction      28 ok    0 failed       1s
  PASS disk-identity          28 ok    0 failed     1,4s
  PASS download-guard         54 ok    0 failed     7,1s
  PASS drive-health           15 ok    0 failed     2,6s
  PASS recycle-bin            93 ok    0 failed     2,4s
  PASS retention              36 ok    0 failed     1,2s
  PASS shed-gate              23 ok    0 failed     0,9s
  PASS sink-target            32 ok    0 failed     1,1s
  PASS verify-mode            27 ok    0 failed     0,9s
  PASS watchdog               16 ok    0 failed     6,4s

  10 suite(s) run, 371 checks reported (371 ok, 0 failed)
  PASS - every suite reported success
```

Three outcomes the summary will not confuse with each other:

- **A suite that exits 0 having printed no checks** is treated as **failed**. A
  suite that dies before running anything still exits 0, and counting that as a
  pass would let a suite silently stop asserting while the run stays green.
- **A suite killed by the timeout** is reported with its own reason rather than as
  a bare non-zero exit.
- **A skipped suite** is reported as `SKIP`, never as `PASS`, and never fails the
  run. See the exit codes above.

| Suite | Covers |
|---|---|
| `tests\cascade-direction.ps1` | Which directions the cascade allows, and that the parking lot does not slide to another drive when the last drive is absent. |
| `tests\disk-identity.ps1` | Attributing a disk error to the drive that actually caused it when Windows has reassigned disk numbers: the exact 2026-10-06 misattribution, and the limit that errors already logged cannot be re-resolved. |
| `tests\download-guard.ps1` | The [download guard](#the-download-guard): that a finished torrent still blocks, that a prefix is matched on a separator boundary, that the UTF-8 decode and the unwrapped `ConvertFrom-Json` survive, and that an unreachable client falls back instead of failing open. Also that **only a client the guard started itself is ever closed** - ownership by pid, not by a flag that a startup race could set wrongly, which is the bug that closed a Windows-started client on 2026-10-07. Talks to `tests\_fake-qbittorrent.ps1`; never touches the real client. |
| `tests\drive-health.ps1` | Reading a disk number out of a Windows error message in both English and Portuguese, and mapping a drive letter to a physical disk. |
| `tests\shed-gate.ps1` | The demand gate on the last drive: that it blocks when nothing is waiting, opens when something is, and **cannot grant a move the direction check refused** — asserted with the demand figure set absurdly high, which is the ping-pong that happened on 2026-10-06. |
| `tests\recycle-bin.ps1` | Reading an item's origin out of its `$I` record, including two real header layouts with the paths swapped for invented ones, every shape that must be *refused*, and the whole pass over a throwaway `subst` volume. |
| `tests\retention.ps1` | Which dated logs and which snapshots the prunes destroy and when, that a dry run cannot delete by accident, and that the log prune can only ever reach files directly inside `logs\`. |
| `tests\sink-target.ps1` | How much space a sink keeps: that `0` is a real setting meaning "fill completely" and not a falsy fallback, that both copies of the rule agree, and the regression where a target above the drive's free space removed it from the cascade while the screen showed room. |
| `tests\verify-mode.ps1` | That `verify` in `config.json` decides the verification method, that a bad value is refused rather than guessed, and that `-Hash` overrides it in one direction only - the bug this key was silently carrying. |
| `tests\watchdog.ps1` | The child deadline - including that a hung process is actually killed - and the in-flight check. Waits for the balancer to go idle before starting, and **skips** (exit 3) rather than failing if it cannot: this suite asserts on whether the real mutex is free, so a scheduled run firing mid-suite is not a defect in it. |

**Tests lift the real functions, they never copy them.** Each suite parses
`balance.ps1` or `watch.ps1` and defines the functions it needs by name, so a
suite cannot quietly pass against a stale copy. If a function is renamed or
deleted the suite throws rather than skipping. `drive-health.ps1` goes further
and pulls the regex out of the source text, because the bug it guards against -
a pattern that only matched English wording on a Portuguese machine - would
otherwise be invisible until a real disk failed.

Two things to know if you add to them:

- **The tests must stay ASCII.** `powershell -File` reads a script as ANSI, so a
  single non-ASCII byte becomes mojibake. Read anything with accents through
  `[System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)`, never by
  embedding the literal.
- **The in-flight case needs a second process.** A Windows mutex is recursive: a
  thread that already owns `Global\PlexBalancer` re-acquires it successfully, so
  testing it on the same thread reports "idle" when a run is actually going.
- **A volume-shaped test needs a `subst` drive.** Anything that works in terms of
  drive letters cannot be pointed at a temp folder. `recycle-bin.ps1` borrows the
  first two free letters, maps them at two *separate* directories, and unmaps
  them in a `finally` - pointing both at one directory would make them the same
  volume and quietly invalidate the per-volume assertions.
- **A file whose name starts with `_` is a helper, not a suite.** The runners skip
  them. `_helpers.ps1` and `_fake-qbittorrent.ps1` are both support code, and
  running the fake server as a suite would block forever waiting for a request.
  Do not start a listener inside a suite: a `BeginGetContext` callback in a
  `powershell -File` script makes the host exit 2 whatever the script asked for,
  which every other suite's result then inherits. Keep the server in its own process
  and signal readiness through a file, because `Start-Process -RedirectStandardOutput`
  holds its output file exclusively and the parent cannot read it.
- **Seams are named as such.** `recycle-bin.ps1` replaces `Write-Log`,
  `Write-Warning` and `Get-DriveFree` so it can inspect what was logged and force a
  purge to appear to free nothing. Everything that decides *what gets destroyed*
  is the real lifted function.

---

## Scheduled task

Runs at logon and every hour thereafter.

```powershell
# status and next run time
Get-ScheduledTask -TaskName PlexStorageBalancer | Get-ScheduledTaskInfo

# state only
Get-ScheduledTask -TaskName PlexStorageBalancer

# run a check right now, without waiting for the timer
Start-ScheduledTask -TaskName PlexStorageBalancer

# stop the current run
Stop-ScheduledTask -TaskName PlexStorageBalancer

# pause the timer, keep the task
Disable-ScheduledTask -TaskName PlexStorageBalancer

# resume
Enable-ScheduledTask -TaskName PlexStorageBalancer

# remove entirely (kills both the timer and the logon trigger)
Unregister-ScheduledTask -TaskName PlexStorageBalancer -Confirm:$false
```

The task runs as your own account (Interactive, limited privileges) rather than SYSTEM,
because this session is not elevated. **Consequence: it only runs while you are
logged in.** To make it run from boot, re-register it from an elevated
PowerShell with the principal changed to SYSTEM.

Exit code `2147946720` (`0x800710E0`) means a trigger fired while a previous run
was still going and was skipped. That is `MultipleInstances IgnoreNew` working as
intended, not an error to chase.

---

## Config

`config.json` is **not committed to git**. It names your drive letters, your
library paths and your account, which is exactly the information a public repo
should not carry. What *is* committed is `config.example.json` - the same file
with placeholder paths - so the repository is complete and readable without
publishing anything about your machine.

On a new machine:

```powershell
git clone <your-url> plex-balancer
cd plex-balancer
Copy-Item .\config.example.json .\config.json
notepad .\config.json     # set your drives and roots
```

Nothing else changes. Every script already looks for `config.json` beside itself,
and each one now fails with that exact instruction rather than a bare
`FileNotFoundException` if it is missing.

`backup\` is likewise ignored. Snapshots and working copies from while you were
changing something - not part of the tool. It expires on the same
`logRetentionDays` clock as the logs, so with the default setting a snapshot older
than 7 days is deleted on the next watcher cycle. Report of what went:

```
deleted backup test-dedup.ps1.bak-before-settag (8 days old, 12.6 KB)
```

Two deliberate differences from how the logs are pruned:

- **Age comes from `LastWriteTime`, not the filename.** A log is named for its day,
  so the name is the truth. A snapshot is named for the edit that produced it -
  `qbt-manager.ps1.bak-queuewin`, `test-dedup.ps1.bak-before-settag` - so there is
  nothing to parse and the timestamp is the only evidence.
- **No filename pattern at all.** Everything in `backup\` is a snapshot by
  definition, so none of it is filtered. The log prune matches three specific
  patterns and exempts `state.json`; here that would mean deciding some snapshots
  are too important to expire, which is not a judgement this function should make.

It recurses into subfolders, so `backup\test\` is swept too. Folders themselves are
never removed, only files.

**`config.json` must never be committed, even by accident.** It is in
`.gitignore`, but git only respects that for files that were never tracked - if
you ever `git add` it by hand, the ignore stops applying. Check before your first
push:

```powershell
git check-ignore -v config.json      # must print a .gitignore line
git ls-files config.json             # must print nothing
```

If the second one prints a filename, it is already staged or tracked. `git rm
--cached config.json` takes it back out without touching the file on disk, then
verify and push. Note that GitHub keeps clones and forks, so a config that was
pushed once is disclosed permanently - removing it in a later commit does not
un-publish it.

The only other thing in the project that carries personal information is
`logs\`, which holds ~1900 media filenames with drive-letter paths. That is
ignored as well, and pruned after `logRetentionDays` anyway.

```powershell
# open it
notepad .\config.json

# validate the JSON without running anything
[System.IO.File]::ReadAllText("$PWD\config.json", [System.Text.Encoding]::UTF8) | ConvertFrom-Json
```

Always read it with explicit UTF-8, as above. Plain `Get-Content -Raw` reads it as
ANSI under PowerShell 5.1 and mangles the accent in `Séries`, which silently
caused all series content to be skipped.

### Global settings

| Key | Value | Meaning |
|---|---|---|
| `maxUnitPctOfFree` | 50 | A unit may only move if it is at most this share of the destination's actual free space. H: and J: are exempt. |
| `copyMarginGB` | 0.2 | Slack subtracted from every sink's headroom before it is considered. |
| `unitOrder` | `smallestFirst` | Order of the shared pool. Set `largestFirst` to free C: faster. |
| `sinkOrder` | `bestFit` | Among destinations that are downstream in the cascade, sinks are tried tightest-first, so small drives get used before large ones. |
| `statusDisplayOrder` | `C:, K:, D:, F:, G:, H:, J:` | Row order in the `status.ps1` DRIVES table. **Cosmetic only - `balance.ps1` never reads it**, so it cannot affect what moves where. Remove it to fall back to `priority` order. |
| `verify` | `size` | Verification method for `balance.ps1`: `size` (file count + total length) or `hash` (SHA256 of every file), both before the source is deleted. `-Hash` forces hashing for one run. Any other value is an error, not a fallback. It does **not** apply to `reconcile.ps1`, which only takes `-Hash` - see [Known gaps](#known-gaps). |
| `skipFilesModifiedWithinHours` | 24 | **Fallback only.** While the [download guard](#the-download-guard) can reach qBittorrent this key does nothing; it applies only when the client cannot be read at all, so a stopped torrent client cannot release a half-written file. |
| `downloadGuard.enabled` | `true` | Ask qBittorrent whether a file is still owned by a torrent. See [The download guard](#the-download-guard). |
| `downloadGuard.url` | `http://127.0.0.1:8080` | Its Web API. Must be reachable from this machine; `AuthSubnetWhitelist` already allows `127.0.0.1`. |
| `downloadGuard.blockSeeded` | `true` | Hold files whose torrent is finished but still listed. `false` holds only unfinished ones - but qBittorrent keeps seeded torrents indefinitely, so `false` releases files the client is still tracking. |
| `downloadGuard.startIfStopped` | `true` | Start qBittorrent if it is not running, so the check does not require it. |
| `downloadGuard.stopAfterCheck` | `true` | Close it again afterwards, so a client kept shut by hand is not left running. Only ever a client this guard started itself, identified by pid - see [Start and stop](#the-download-guard). |
| `downloadGuard.exePath` | `C:\Program Files\qBittorrent\qbittorrent.exe` | What `startIfStopped` launches. |
| `downloadGuard.startTimeoutSeconds` | 90 | How long to wait for its API to answer after starting it, or after finding it already running but not yet bound. |
| `downloadGuard.bootGraceSeconds` | 300 | How long after boot to wait for a client **Windows** is launching before concluding nothing is running. Only uptime is counted, so an established machine does not wait. |
| `logDir` | `logs` | Where audit logs are written. |
| `logRetentionDays` | 7 | Watcher deletes dated logs once they reach this age. `0` keeps everything. See [Retention](#retention). |
| `recycleReclaim` | `true` | [Recycle Bin reclaim](#recycle-bin-reclaim) of library media sitting in the bins. Set `false` to skip it; it then costs one line of output per run. |
| `driveErrorWindowHours` | 24 | How far back to look for Windows disk errors. Any drive whose physical disk logged a hardware or paging error inside this window is **not read** that run. See [Failing drives](#failing-drives). |

### Failing drives

A drive that is failing does not report an error and move on - it **retries**, and a recursive scan of it blocks the whole run with no way out. On 2026-10-03 two USB drives did this for 40 minutes while the watcher kept starting new runs, and the machine stopped being able to start anything.

So before reading a drive, `balance.ps1` asks Windows which physical disks have logged errors recently and skips those. It watches for:

| Event | Meaning |
|---|---|
| 51 | Error during a paging operation |
| 153 | I/O operation was retried |
| 154 | I/O operation failed, hardware error |
| 157 | Device surprise removal |

**The letter comes from the disk's identity, not its number.** These events name a
disk by number and nothing else - event 154 reads `Disco 3 (nome PDO: \Device\00000059)`
and event 51 reads `\Device\Harddisk3\DR3`, with no serial number and unnamed
`EventData`. Disk numbers are reassigned across reboots and USB reconnections, so
"disk 3" in September is not necessarily the drive holding number 3 now.

That was not theoretical. On 2026-10-06 the gate held `H:` out of a run because the
drive that had really failed was `K:`, `K:` has since become disk 4, and `H:` is
disk 3 - while manual moves to `H:` worked perfectly throughout.

Since the events carry too little to resolve retroactively, every run writes the
identity that holds each failing number into `logs\diskmap.json` and re-resolves the
letter from that identity. Two consequences:

- **The first run after enabling it can still misattribute**, because there was
  nothing recorded yet. It says so in the log, and every run after that is correct.
- **Errors logged before this existed are still attributed to the current holder**,
  for the same reason. Only errors inside the window from now on are resolved
  properly.

The map holds only the numbers failing on the current run and is rebuilt rather than
merged, so a stale entry cannot survive the window and blame an innocent drive on
the next genuine failure. A drive that has been removed entirely holds nothing out,
because there is no letter left to skip. A run that skips a drive says so:

```
AVISO: not reading F: - disk 4 has logged hardware or paging errors in the last 24h. Treat it as failed until it is replaced or the errors stop.
```

and when the number moved between disks it names the reassignment instead:

```
AVISO: not reading K: - disk 3 was a different physical disk when the errors were logged - it is K: now
```

Three consequences worth knowing:

- **Skipping is not deleting.** A skipped drive is simply not scanned. Its files stay exactly where they are.
- **The gate reopens by itself.** It looks at a moving window, so once the errors age out the drive is scanned again with no config change. If it fails again, it is skipped again.
- **It only blocks reads.** A drive can still be written to, because a sink is a destination and not a scan target. On K: and F: that is deliberate for now, and it is the reason those two drives should be replaced rather than trusted - see [Known gaps](#known-gaps).

If a drive is skipped, the run continues normally and simply plans less. There is no separate failure mode to handle.

### Per-drive settings

| Key | Applies to | Meaning |
|---|---|---|
| `sources` | C:, K:, D:, F:, G:, H: | Drive offers files to be moved out. Only `J:` is `false` - it is the end of the chain and is never read. **K:, `F:` and `H:` were `false` until 2026-10-06**, when they became sources again: they had been held back because Windows was reporting one disk's errors against whichever drive held that disk *number* at the time, and the true chain `C: -> K: -> D: -> F: -> G:` could not reach `J:` at all without them. See [Failing drives](#failing-drives). |
| `alsoSink` | K:, D:, G:, F: | Drive is both a source and a destination. Required on any source that also needs to receive. |
| `drain` | C:, K: | `always` means offer files unconditionally. |
| `maxFillPct` | D:, G:, F: | Become a source once free space drops below `100 - maxFillPct` percent. Set to 95, so a drive only gives content away when it is genuinely nearly full. Without it a source must also set `drain`. |
| `priority` | C:, K:, D:, G:, F: | Position in the cascade. Lower numbers are offered first as sources, and content only moves to a *higher* number - except the last drive, which may give back one step. |
| `targetFreePct` | D:, F:, G:, H:, K: | Stop accepting once free space drops to this percent. **The value is a percentage, so `0.1` means 0.1%, not 10%** - it is why D:, F:, G: and H: are configured to fill to the brim. |
| `targetFreeGB` | J: | Same, in absolute gigabytes. |

**`0` is a real setting, meaning "fill completely".** It is tested against `$null`
rather than truthiness, so `0` reaches the arithmetic instead of falling through as
if the key were absent - both answers are `0` bytes, but only one of them is the
one you asked for. `H:` and `J:` are both set to `0`, so they accept until the drive
is physically full.

A percentage target on a large volume is a large absolute reserve, which is the
opposite of what it looks like. `1.0` on `H:`'s 1863 GB is 18.63 GB reserved, and
`H:` had 4.45 GB free, so it was **below its own target and refused everything** -
which reads as an idle balancer while 4.45 GB sits on screen. A drive below its
target is not a sink at all. Check the TARGETS table in the run output before
concluding a drive has no room: `at target` on a drive showing free space means
exactly that.
| `maxUnitGB` | J: | Largest single file J: will accept. |
| `maxUnitPctOfFree` | – | Global only (50). A unit may not exceed this share of the destination's free space. Can also be set per drive, which overrides the global. |
| `exemptHeadroomRule` | H:, J: | Disables the 50% rule on this drive. |

---

## Logs

Append-only, one file per day. Lines are never rewritten or removed from an
existing file, but whole days are pruned once they fall outside the retention
window (see below).

```powershell
# what is there
Get-ChildItem .\logs

# today's moves
Get-Content .\logs\moves-$(Get-Date -Format yyyyMMdd).jsonl |
  ForEach-Object { $_ | ConvertFrom-Json } |
  Select-Object at, event, source, dest | Format-Table -AutoSize

# only failures from the last 24h
Get-Content .\logs\moves-$(Get-Date -Format yyyyMMdd).jsonl |
  ForEach-Object { $_ | ConvertFrom-Json } |
  Where-Object { $_.event -match 'failed' -and [datetime]$_.at -gt (Get-Date).AddHours(-24) } |
  Format-Table -AutoSize

# watcher activity
Get-Content .\logs\watch-$(Get-Date -Format yyyyMMdd).log -Tail 20

# repairs
Get-Content .\logs\reconcile-$(Get-Date -Format yyyyMMdd).jsonl -Tail 20

# live machine-readable state (prefer status.ps1 over reading this by eye)
Get-Content .\logs\state.json -Raw
```

Event names in `moves-*.jsonl`: `moved`, `planned`, `move_failed`, `skipped`,
`recycle_destroyed`, `recycle_would_destroy`, `recycle_verify`,
`recycle_destroy_failed`, `recycle_meta_failed`, `reconcile_*`.

Note: `moves-20261003.jsonl` contains `move_failed` entries from an early failed
run. The log is append-only by design, so those lines stay as a record. They do
not indicate a current problem - check the timestamps.

### The download guard

A file is held while qBittorrent still lists the torrent that owns it. It replaced
a rule that was purely time-based - anything modified in the last
`skipFilesModifiedWithinHours` was left alone - which held back a whole library
because a file inside it was touched that morning, and knew nothing about what was
actually downloading.

```
skip (fresh) [C:] Apollo.13.1995.4K.HDR.2160p.BDRemux...mkv - still downloading
```

Three things about it that are easy to get wrong, and are pinned by
`tests\download-guard.ps1`:

- **It holds the torrent's actual files, not its folder.** `save_path` is whatever
  directory was picked when the torrent was added, and that is very often a whole
  library rather than the release inside it. Blocking on `save_path` held **48 files
  when only 6 torrents existed** - every file under `Downloads\Filmes` and the
  accented series root with it, including finished movies belonging to no torrent at
  all. The guard now asks `/api/v2/torrents/files?hash=` per torrent and holds
  exactly those paths: **16 files on the same machine, 3 of them media.**
- **A finished torrent still blocks.** `blockSeeded` is `true`. qBittorrent keeps
  seeded torrents in its list indefinitely, so a progress test would release files
  the user has not removed from the client yet. Removing a torrent from the client is
  the signal that the file is yours to move.
- **The reply is decoded as UTF-8 by hand.** qBittorrent sends `application/json`
  with no charset, so PowerShell decodes it as Latin-1 and an accented library root
  arrives mangled. Every path comparison then fails and the guard is inert while
  appearing to be on.

One more that is not visible from the outside: an empty torrent list is a real
answer, not a failure. `[]` parses to an empty array, and returning an empty array
from a function assigns `$null` to the caller, which reads as "the client did not
answer" - so a machine with no torrents at all would fall back to the time rule.

If one torrent's own file list cannot be read, that torrent falls back to holding its
whole `save_path`. Coarse, but in the safe direction: guessing open there would let a
half-written file be moved.

If the client cannot be reached at all the guard reports itself Unknown and the older
time-based rule applies instead, because "qBittorrent is not running" must never
become "that half-downloaded file is fine to move".

**Start and stop, and who is allowed to close it.** With `startIfStopped`, a client
that is genuinely not running is launched, waited for, read, and then closed through
its own `/api/v2/app/shutdown` endpoint - not `Stop-Process`, because qBittorrent
saves its session and rewrites its `.torrent` files on the way out and a kill loses
that. The close is in a `finally`, so a failure mid-check cannot leave behind a client
that was only started to answer one question.

**A client the guard did not start is never closed, and closing is decided by pid,
not by a flag.** That distinction is a bug that was live for an hour on 2026-10-07.
qBittorrent is registered in the Windows Run key, so it starts at logon; its tray icon
appears *before* the WebUI binds port 8080. The old code asked "is a qbittorrent
process running?" during exactly that gap, got "no", started a **second** instance,
set a boolean saying it had started one, and then shut the whole thing down one second
after the API came up. The client's own log:

```
01:05:35  WebUI: Now listening on IP: *, port: 8080
01:05:36  qBittorrent termination initiated
```

Now:

- **A pid is recorded** for an instance this guard launches. Nothing else sets it.
- **The close needs that pid to be set AND to still be the only qBittorrent
  process.** `/api/v2/app/shutdown` kills whatever owns port 8080, so if a second
  instance appeared meanwhile the call would close the *user's* client. When that is
  possible the client is left running and the reason says so.
- **A process that exists but is not answering is waited for**, on
  `startTimeoutSeconds`. A second instance is only launched when nothing is running
  at all.

**On a freshly booted machine the guard waits Windows out first.** `bootGraceSeconds`
defaults to **300**. Only time actually spent since boot is counted, so the first run
after a restart waits out the remaining minutes and an established machine never
waits at all. Without this, a run that started while Windows was still launching
qBittorrent would conclude it was absent and interfere with it.

**One security note.** qBittorrent's `AuthSubnetWhitelist` covers `127.0.0.1`, so its
API answers any request from this machine **without a password**. That is what lets
the balancer read the torrent list with no credentials stored anywhere - and it also
means anything else running as this user can query and control the client.

---

### Retention

`logRetentionDays` (7; `0` keeps everything) is applied by the watcher on every
cycle, so expired logs are cleared even on days when the balancer has nothing to
do. Deletions are reported in that day's `watch-*.log`:

```
deleted moves-20260920.jsonl (13 days old, 1.4 MB)
```

Seven days means a log is destroyed once it *reaches* seven days old: it exists
on days 0-6 and goes on day 7. (Before this was fixed the setting was off by one
and a value of 7 kept eight days' logs.)

Three details worth knowing:

- **Age comes from the date in the filename, not `LastWriteTime`.** A day whose
  watcher was switched off would otherwise keep its logs forever, since nothing
  refreshes their timestamp.
- **Only `moves-*`, `watch-*` and `reconcile-*` are ever considered.**
  `state.json` is live, is rewritten by whatever run is in progress, and is never
  a candidate. The prune looks at files sitting directly in `logs\` and matches the
  name, so it cannot reach media even in principle.
- **`moves-*.jsonl` is the only record of what was moved and deleted from
  where.** Seven days is enough to trace a bad run back through its own logs. If
  you need a longer window, raise `logRetentionDays` *before* the days you care
  about age out.

**`backup\` is pruned by `LastWriteTime`, and copying a file resets it.** Restore a
snapshot into `backup\` rather than moving it and its clock restarts, so it will sit
there another 7 days. That is the safe direction to be wrong in.

A name that is not a real date (`moves-bogus.jsonl`, `moves-20261301.jsonl`) is
kept rather than treated as ancient - pruning should never be the thing that
breaks a run. Check what a prune would do before it does it:

```powershell
.\watch.ps1 -Once -DryRun     # reports "would delete ..." and deletes nothing
```

---

## Checking disk space

```powershell
# all drives, raw figures
Get-CimInstance Win32_LogicalDisk |
  Where-Object DeviceID -in 'C:','D:','F:','G:','H:','J:','K:' |
  Select-Object DeviceID, @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,2)}} |
  Sort-Object DeviceID | Format-Table -AutoSize

# what the balancer thinks, including targets and roles
.\balance.ps1 -Report
```

On a nearly-full NTFS volume, Windows' reported free space is unreliable - it can
over-report by a whole file or more, and only settles on reboot. The balancer
re-reads the destination immediately before every copy, which is what makes the
unattended runs safe. If you want trustworthy numbers, reboot first.

Unplugged portable drives are skipped, never counted as full.

---

## Execution policy

Changed once so the scripts run without a bypass flag:

```powershell
Get-ExecutionPolicy                                            # check current
Get-ExecutionPolicy -List                                      # all scopes
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned    # what is set now
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Restricted      # revert
```

`CurrentUser` scope only. Nothing machine-wide was modified.

---

## Routine

What a normal cycle looks like:

```powershell
.\balance.ps1          # look at the plan
.\balance.ps1 -Apply   # do it
.\reconcile.ps1        # confirm nothing was left behind
.\status.ps1           # check the result
```

If a run is interrupted - power cut, unplugged drive, closed lid - just run
`.\reconcile.ps1 -Apply` then `.\balance.ps1 -Apply`. The balancer also runs
reconcile first on every scheduled cycle, so unattended recovery is automatic.

---

## Troubleshooting

**"not reading F: - disk 4 has logged hardware errors."**
Working as intended, and worth acting on. Windows has recorded hardware or paging
errors for that drive inside `driveErrorWindowHours`, so the run skipped it rather
than risk blocking. To see the raw evidence:

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Id=51,153,154,157;
                               StartTime=(Get-Date).AddHours(-6)} |
  Select-Object TimeCreated,Id,Message | Format-List

Get-Partition -DriveLetter F          # which physical disk the letter maps to
```

The drive is not repaired by waiting. It re-enters the run once its errors age
out of the window, which is the point at which you should have replaced it - the
gate stops a drive from being read, it does not stop a disk from dying.

**A run was killed for exceeding its timeout.**
Look for the `did not finish within` line in `watch-2026*.log`; the PID it names
is gone. Almost always a drive stalling mid-scan. Raise
`-BalanceTimeoutSeconds` only if a healthy run is genuinely being cut short -
a normal run is about 15 seconds.

**"a balancer run is still in progress - skipping reconcile and balance this cycle"**
The previous cycle did not finish. The entry above it is where the run stopped;
if there is no entry above it, the task started two watchers close together and
one of them is still working.

**"Another balancer run is already in progress - nothing to do."**
A run holds a named mutex (`Global\PlexBalancer`) shared by balance, reconcile and
watch. Wait, or find it:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Select-Object ProcessId, CreationDate, CommandLine | Format-List

Get-Content .\logs\state.json -Raw      # shows pid, phase, current file
.\status.ps1                            # human-readable version of the same
```

**A drive is missing from the report.**
It is unplugged. Portable drives (H:, J:, K:) are skipped when absent rather than
treated as full.

**A file was skipped with `drive too small` when it is not that big.**
Check `.\balance.ps1 -Report`. The reason is the largest free space on any single
sink, so a file can be blocked by one constraint even when another is satisfied.

**Everything is skipped with `over 50% free`.**
Working as intended. The file would take more than half of what the destination
actually has free, which on a nearly-full NTFS volume is how the reported space
turns out to be wrong. Let smaller files through first.

**A drive has free space but nothing moves to it.**
Two independent limits have to be satisfied, and it is worth checking both,
because the drive status table only shows the first:

1. **Room.** `free - targetFreePct - copyMarginGB` must exceed the file size.
2. **The 50% rule.** The file must also be at most `maxUnitPctOfFree` (50) of
   the destination's *current* free space.

So a drive with 11.7 GB free only accepts files up to **5.8 GB**, even though it
reports 10.6 GB of room. A library whose smallest file is 7 GB will show plenty of
free space and move nothing at all. The fix is to lower `maxUnitPctOfFree` on
that drive (it may be set per drive and overrides the global), or to free real
space elsewhere. The rule exists because NTFS over-reports free space on a
nearly-full volume and copies fail partway through with *"Espaço insuficiente no
disco"*; the live re-read before each copy plus `copyMarginGB` are the other two
guards.

**Nothing moves and every sink reads `at target`.**
All destinations are full. The balancer can only fill drives, never free them.
Something has to be deleted by hand.

**Kill a stuck run:**

```powershell
Stop-ScheduledTask -TaskName PlexStorageBalancer
# then, if a manual run is wedged:
Stop-Process -Id <pid from state.json> -Force
.\reconcile.ps1 -Apply
```

---

## Undo

```powershell
Unregister-ScheduledTask -TaskName PlexStorageBalancer -Confirm:$false
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Restricted
```

Read the next command before running it:

```powershell
Remove-Item %USERPROFILE%\plex-balancer -Recurse -Force
```

Your media roots live under `%USERPROFILE%\Downloads` and at the root of D:, F:,
G:, H:, J: and K:, not inside the balancer folder. But read any recursive delete
before you run it.

---

## Known gaps

Honest list of what is incomplete or worth knowing:

- **The drives that logged hardware errors in September are being read and written
  again.** `K:` logged tens of thousands of paging errors and thousands of hardware
  I/O failures; another drive logged a hundred-odd retried reads. They were set to
  `sources: false` on 2026-10-03 and turned back into sources on 2026-10-06,
  because holding them back was preventing the chain from reaching `J:` at all and
  because the gate was misattributing one disk's errors to whichever drive held that
  disk number at the time - now fixed by keying on the disk's unique id, see
  [Failing drives](#failing-drives). The event log no longer reports errors against
  any of them. If they
  start reporting again the gate will hold them out of reads on its own - but treat
  every file on them as unbacked-up, and replace them. Nothing in this folder can
  recover a drive.
- **A drive whose disk is logging errors is still written to.** The gate in
  [Failing drives](#failing-drives) protects reads only, and has done since the
  incident. That is the one deliberate gap left in it.
- **You cannot force `size` from the command line.** `verify` in `config.json` sets
  the method and `-Hash` forces hashing for one run, but the reverse has no clean
  switch. `-Hash:$false` would do it and does work when `balance.ps1` is called
  from inside PowerShell, but `powershell -File` passes it through as the literal
  string `-Hash:$false`, which then fails to bind. So if your config says `hash`
  and you want size for one run, either call it in-session or point `-ConfigPath`
  at a config that says `size`. Adding a `-Verify size|hash` parameter would close
  this properly and is deliberately not done yet: two parameters and a config key
  all meaning the same thing is how the key ended up inert in the first place.
- **The 2026-10-03 raw logs are gone.** `watch-20261003.log`, `moves-20261003.jsonl`
  and `reconcile-20261003.jsonl` (and the same three for 2026-10-04) were deleted
  on 2026-10-05 by mistake, five days before retention at its current setting of
  7 would have reached the Oct 3 pair. Cause: `Invoke-LogPrune` read a `$DryRun`
  it never declared, so a caller passing `-DryRun` got `$null` instead of a switch
  and the "dry run" deleted for real. The parameter is now declared, the call site
  passes it explicitly, and `tests\retention.ps1` fails if that regresses.
  Nothing was recoverable - `Remove-Item -Force` bypasses the Recycle Bin and there
  are no shadow copies - but the *conclusion* drawn from those logs is written up
  under Known gaps above, so the diagnosis survives even though the evidence does
  not. Anything that needs the raw rows from those two days is gone.
- **The `$I` layout is reverse-engineered, not documented.** Microsoft publishes
  nothing about it, so `Read-RecycleMeta` is built from the observed bytes of
  version 1 and version 2 headers and from nothing else. It refuses anything it
  does not recognise rather than guessing, so a future layout change shows up as
  "left N item(s) alone" in the run output rather than as wrong deletions - but it
  would mean reclaim quietly stops reclaiming. `tests\recycle-bin.ps1` holds two
  real headers as fixtures for exactly this reason.
- **The recycle-bin pass can only see what the shell could.** A `$R` payload with
  no readable `$I` beside it is left alone, and there is no way to tell from the
  payload what it used to be. Those entries have to be cleared by hand.
- **`-MaxMinutes` (`balance.ps1`) and `-LookbackDays` (`reconcile.ps1`) do
  nothing.** Both are declared in the param block and never referenced by the
  code. They are inert. Do not rely on them.
- **The scheduled task only runs while you are logged in.** It is registered as
  your account (Interactive) because this session is not elevated. A SYSTEM-wide task
  needs an elevated shell to create.
- **K: is now filled only.** It was briefly both filled and drained, which reversed
  the earlier "keep K: away from 100%" rule at your request. It is no longer a
  source, so nothing moves off it - see [Failing drives](#failing-drives). It
  stops accepting at 0.5% free, and the 50% rule still applies to it as a sink.
- **Free space on a nearly-full NTFS volume cannot be trusted.** Figures settle
  only after a reboot. The live re-read before each copy mitigates this; it does
  not make the numbers correct.
- **H: and J: sit at literally 0 bytes free.** Nothing the balancer can do about
  that - it can only fill drives. Deleting on them has to be manual.
- **Plex re-matches on its own after a cross-volume move.** A move within one
  library shows up as a delete plus an add. Watch status or manual edits on a
  moved title may reset; the same filename re-matches, but playback history does
  not necessarily come back.
- **A file can be moved out from under Plex mid-scan.** `Test-UnitLocked` opens
  the unit with `FileShare::None`, so a file Plex holds *at that instant* is
  skipped. But the check guards a moment, not the copy: an 11 GB file copied from
  `C:` to `K:` took six minutes on 2026-10-04, and Plex opened the source inside
  that window. Plex logged
  `Exception analyzing media file ... (error=-2): No such file or directory` and
  then re-found the file at its new path **one second later**, analysing it fully.
  No data was lost - `Invoke-Move` verifies before deleting the source - and Plex
  self-heals, so this is noise rather than damage. Closing the gap properly means
  either re-checking the lock after the copy completes or asking Plex to pause
  scanning during a run; neither is done here.
