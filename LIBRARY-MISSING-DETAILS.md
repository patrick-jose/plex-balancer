# Library missing — full detail and history

This is the **archive**: every dated investigation, resolved row, move-log finding and
playlist-gap note about media that was missing from the local Plex library. For the short
"what do I download" checklist, open `LIBRARY-MISSING.md` instead — the manager regenerates
that file from TMDb plus the local library on every run.

- **Last updated:** 2026-11-19 12:07 -03:00
- **Source of truth:** Plex library `http://127.0.0.1:32400` (show leaves + file existence), `playlist-data/notifications.json` (TMDb release check), `logs/moves-*.jsonl` (balancer move outcomes).
- **Companion:** `INCIDENT-move-failed-missing-files.md` (why files vanish after `move_failed`).

> **Playlist-managed section:** the `playlist-manager.ps1` run rewrites only the
> marked block appended at the end of this file (delimited by HTML comments named
> for the playlist manager's missing-media section). Everything above it is
> maintained by hand and is never touched. Items whose Plex identity
> vanishes are moved there with their saved queue slot and restored to that slot
> automatically when a Plex library refresh lists them again. Re-keyed items are
> rebound by stable identity first, so a changed `ratingKey` is never mistaken for
> missing media. Set `missingMediaLedgerPath` in `playlist.config.json` to relocate
> this file.

## Missing now — 9 episodes, 6 shows (checked 2026-11-18)

Source: the balancer's TMDb + local-library check, starting at each show's
**collection start** (first source-playlist episode, or first local unwatched episode
for shows added later). It deliberately does **not** apply the rotation-cursor filter
used for retirement, so aired episodes already passed in an earlier cycle are still
listed when their file is missing. Destructive move-log events are folded in too as a
safety net. **Watched episodes are excluded** — a viewed item whose file was later
retired or deleted is not offered for download again. The short checklist
`LIBRARY-MISSING.md` is regenerated from all of these.

| Show | Missing | Why it is missing | Notes |
| --- | --- | --- | --- |
| Dark Matter | **S02E10** | Aired; no local file or Plex item | S02E07 is still in `Downloads` behind the fresh-file guard (repeated `skip_in_use` today); S02E01 moved to `K:` on 11-17 |
| Ted Lasso | **S04E10 "Being Alive"** | Lost to `move_failed` on 2026-11-07 (access denied on `K:`); never re-downloaded | Still missing after 11 days; no `moved` or deletion record |
| VisionQuest | **S01E08** | Aired; no local file or Plex item | Briefly reappeared in Plex at ~22:35 as key `4549` (TMDb id `7063227`, unwatched) from `C:\Users\patri\Downloads\Séries\VisionQuest\Season 1\...`, so it dropped off the checklist; gone again by 23:01 with no file and no move-log record. Currently listed as missing |
| The Simpsons | **S38E07** | Aired; no local file or Plex item | S38E06 moved to `D:` at 21:06 today, so E06 is resolved and E07 is now the frontier |
| Dexter: Resurrection | **S02E03** | Aired; no local file or Plex item | S02E02 is downloaded but still in `Downloads` (repeated `skip_in_use` today), not in a library drive |
| VisionQuest | **S01E03, S01E04** | Purged from the Recycle Bin on 2026-11-18 21:05 (`recycle_destroyed`, `logs/moves-20261118.jsonl`) | Behind the rotation cursor; old keys `4202`/`4204` were already removed from `Queue`/`BaseQueue`, so the deferral logic never saw them. Now reported by the collection-start TMDb check and cross-checked against the move logs |
| Lanterns | ~~S01E08 "Dirt and Stars"~~ | **Not actually missing** — the balancer moved it `K:` → `F:` at 2026-11-18 22:09 (`logs/moves-20261118.jsonl`); the 6.19 GB file exists on `F:` | Plex has no S01E08 item because it has not indexed the new path, so the manager defers the saved slot #149. The file must **not** be re-downloaded: refresh the Plex library section so the item reappears and the slot can be restored. Added `Get-PlaylistRelocatedMedia` so a verified move-log destination removes the episode from the download list |
| Penn & Teller: Fool Us | **S11E06, S11E07** | Aired 2025-02-28 / 2025-03-07; no local file or Plex item | Behind the rotation cursor — these are exactly the episodes the current-frontier check used to hide. The collection-start check now includes them |

## Current state (2026-11-18)

- Managed playlist and saved state both hold **232 items** (`Queue` 232, `BaseQueue` 232, `Movies` 73, `Applied` true). The 219/228/229 counts in older sections below are historical snapshots.
- Last read-only preview: `intended=232, add=0, remove from copy=0, unresolved=0`. No live edits were made during this reconciliation.
- `ActiveIds` is **23** (was 24 on 2026-11-17).
- Rotation stopped in **Cycle 8 at 23/25 show slots**; 2 slots remain until cycle end. No remaining active show has an eligible next episode or ready replacement.
- Two cadence gaps remain, each 4 TV episodes where 5 are expected: movie **#131** (Louis Theroux: America's Medicated Kids) to **#136** (Origin), and movie **#160** (Perfect Days) to **#165** (Louis Theroux: The Ultra Zionists). `UnfilledGaps=4`.
- `last-result.json` shows `Verified=false` only because read-only previews overwrite it after the last verified apply; the next `-Apply` is expected to restore `Verified=true`.

## Historical snapshot — 2026-11-17 playlist restoration and roster change

> The "now" statements in this section were true on 2026-11-17. Current values are in
> **Current state (2026-11-18)** above; this section is kept as history, not a status report.

- **Lanterns S01E06 "Bad Optics"** was missing from the **saved state** (`state.json`),
  not just from Plex — so `-RecoverOnly` could not bring it back. Its file/item is
  present in Plex with identity `plex://episode/673ffc678ed664b364de7ae3` (key `4447`,
  current identity after the 3225 -> 4407 -> 4423 -> 4447 quality/key swaps). It was
  re-inserted into `state.json` at position **92**, just before Louis
  Theroux: Life on the Edge S1E3, then applied. Live playlist verified at **219 items**,
  `Queue`/`BaseQueue` 219, `Applied` true. The 90 -> 95 cadence is whole again:
  Tron: Ares (#90), Lanterns S1E6 (#92), Louis Theroux S1E3,
  Modern Family S4E8, Parks and Recreation S5E6 (#95).
- A deliberately deleted active show is now treated as a roster vacancy: the balancer
  drops the dead id from `ActiveIds` and the consumed cycle prefix, promotes an eligible
  downloaded standby when one exists, and otherwise continues in rotation and stops at
  the first blocked show instead of pausing solely because fewer than 25 shows are
  visible. `ActiveIds` is now 24.
- Rotation currently stops at **Lanterns: no downloadable episodes remain** — no eligible
  standby or next local episode is available. New TV episodes queue again once content
  or a substitution is added; the manager resumes at that exact slot.
- The historical 4-TV blocks (after movies #90, #119, #148; 3-TV after #176) are the
  empty Good Morning, Verônica rotation slot after its final S03E03 was queued at
  position 56. They were left unchanged to preserve saved order; retroactive reflow
  needs explicit user direction.

## Historical snapshot — related gaps not covered by the automated missing check

> Resolved history from 2026-11-14/17, kept for context. The current gaps are in
> **Current state (2026-11-18)** above. These no longer describe the live playlist.

These left holes in the managed playlist but TMDb did not flag them as "released episode missing":

- **Lanterns S1E6 "Bad Optics"** and **S1E8 "Dirt and Stars"** — lost to `move_failed` with access denied on `K:` on 2026-11-09 (`logs/moves-20261109.jsonl`, 10:17 and 10:12). Both were resolved as of 2026-11-14:
  - **S1E8:** re-downloaded 2026-11-14 (6.19 GB, `C:\Users\patri\Downloads\Séries\Lanterns\Season 1\...`). Plex lists it; restored to the managed playlist at position **158**, before Modern Family S4E10.
  - **S1E6:** first came back as a 1080p Russian LostFilm release (2.93 GB) at 09:24, then was replaced at 09:56 by a 2160p AMZN FLUX copy (5.82 GB, same as S1E8) in `C:\Users\patri\Downloads\Séries\Lanterns\Season 1\...`; Plex lists that one. Restored at position **98**, just before Louis Theroux: Life on the Edge S1E3. The storage ledger recorded the 1080p file as `vanished` and the 2160p file as `appeared`, so the replacement is on record rather than unexplained.
  - Replacing the file made Plex recreate the episode item (ratingKey 3225 -> 4408), which silently dropped its playlist entry a few minutes after the restore verified clean. `-Apply -RecoverOnly` put it back at 98. Expect this after any quality upgrade; check the playlist afterwards.
  - Both blocks were back to five episodes. **Update 2026-11-18:** S01E8 has since been drained from `C:` (moved to `K:` on 11-16 17:49); check the move logs before assuming the same for the current S01E6 file.
- **Euphoria S3E8 "In God We Trust"** - was never downloaded, so the block between movies **#180 and #185** had four episodes. **Resolved on 2026-11-18:** S03E08 (key `4413`) was inserted into the short block between *Nocturnal Animals* and *40 Acres*, so that block is whole again. It is no longer the only playlist gap — the two current gaps are listed under **Current state (2026-11-18)** above.
- **`Relay` (movie)** - removed by hand from the managed playlist earlier. Restored on 2026-11-14 at position **188**, between Louis Theroux: America's Most Hated Family in Crisis and The Secret Agent; file is on `D:`. The playlist was **229 items** at that time and matched the saved order exactly; the current count is 232 (see **Current state (2026-11-18)**).
  - Note for the next restore: adding a hand-removed movie only to `state.json` makes the manager treat it as a manual removal and replace it with a random movie. It must also be added to the live playlist first; see `COMMANDS.md` under the Plex notes.

## Maintenance

1. Recheck against Plex, not against this file: each show's `allLeaves` plus `Test-Path` on the reported file.
2. Add a row when a new aired/released episode is absent locally; keep the date it was first seen.
3. Move a row to **Resolved** only when Plex lists the episode **and** its file exists. Never delete history.
4. Refresh the verification section and the log every time. `Last updated` is now rewritten automatically by `Update-PlaylistMissingLedger` on each `-Apply`; previews stay read-only and do not touch it.
5. The hourly watcher already rewrites `playlist-data/notifications.json`; use its `tv-missing-*` keys as a cross-check, not as the only input.

## Resolved

| Show | Episode | Was missing | Resolved | How |
| --- | --- | --- | --- | --- |
| Saturday Night Live | S52E02 | 2026-11-07 (`move_failed`, access denied on `K:`) | 2026-11-14 | Re-downloaded; Plex lists it, file on `D:` |
| Dexter: Resurrection | S01E10 "And Justice for All…" | 2026-11-07 (`move_failed`, access denied on `K:`) | 2026-11-14 | Re-downloaded 2026-11-11; Plex lists it (file still in `Downloads`) |
| Lanterns | S01E08 "Dirt and Stars" | 2026-11-09 (`move_failed`, access denied on `K:`) | 2026-11-14 | Re-downloaded; Plex lists it; restored to playlist position 158 |
| Lanterns | S01E06 "Bad Optics" | 2026-11-09 (`move_failed`, access denied on `K:`) | 2026-11-14; re-restored 2026-11-17 | Re-downloaded, then upgraded to 2160p AMZN FLUX; Plex lists it. Restored to playlist position 98 on 11-14, dropped from saved state again, re-inserted at position 92 on 11-17 (identity `plex://episode/673ffc678ed664b364de7ae3`, key 4447) |
| Saturday Night Live | S52E05, S52E06 | 2026-11-14 (aired, no local file) | 2026-11-18 | No longer reported missing by the current check; S52E06 moved to `D:` at 20:11 on 11-18. No move-log record for S52E05 — confirm in Plex if it matters |
| South Park | S29E05 | 2026-11-14 (aired, no local file) | 2026-11-18 | No longer reported missing by the current check; no move-log record found |
| The Simpsons | S38E06 | 2026-11-14 (aired, no local file) | 2026-11-18 21:06 | Re-downloaded and moved from `Downloads` to `D:\Séries\The Simpsons\Season 38\...`; S38E07 is now the missing frontier |
| Dexter: Resurrection | S02E02 | 2026-11-14 (aired, no local file) | 2026-11-18 | Downloaded to `Downloads` but still `skip_in_use` (not on a library drive); no longer the missing frontier — S02E03 is |

## Log

- **2026-11-14** — Ledger created from the user's list. Verified all 7 episodes / 6 shows against Plex and the move logs; marked SNL S52E02 and Dexter S01E10 as resolved; recorded the Lanterns and Euphoria playlist gaps that the automated check does not report.
- **2026-11-14 09:10** — Found `Lanterns S1E8` re-downloaded in `Downloads` (6.19 GB, not yet a Plex item, held by the 24h fresh-file guard); `S1E6` still has no local file.
- **2026-11-14 09:47** - `Lanterns S1E6` (1080p Russian LostFilm, 2.93 GB) and `S1E8` both became Plex items. Restored both to the managed playlist at their historical positions (98 and 158); live playlist verified at 228 items, both blocks back to five episodes. Only the Euphoria S3E8 gap remains.
- **2026-11-14 09:56** - Movie `Relay` restored at position 188 after the user chose to bring it back. First attempt was replaced by a random movie (`Rebel Moon - Part One: A Child of Fire`) because it was only in the saved state; the replacement was removed and the correct sequence (live playlist first, then `-Apply -RecoverOnly`) put Relay in place. Live playlist verified at **229 items**, state `Queue`/`BaseQueue` 229, `Movies` 74, `Applied` true. Euphoria S3E8 is now the only playlist gap.
- **2026-11-14 10:10** - `Lanterns S1E6` was upgraded: the 1080p Russian LostFilm file disappeared at 09:56 and a 2160p AMZN FLUX copy (5.82 GB) took its place. The storage ledger recorded `vanished` + `appeared`. Plex recreated the episode item (ratingKey 3225 -> 4408) and silently dropped the playlist entry; `-Apply -RecoverOnly` restored it at position 98. Live playlist and saved state now match exactly at 229 items, preview `add=0`.
- **2026-11-17 06:50** - Reported cadence gaps traced to the exhausted Good Morning, Verônica rotation slot (final S03E03 queued at position 56). `Lanterns S01E06 "Bad Optics"` was found missing from `state.json` (not just Plex), re-inserted at position 92 and applied; live playlist verified at 219 items. A dead active id from a deliberately deleted show was removed from `ActiveIds` and `CycleConsumed`. `playlist-lib.ps1` updated so deleted active shows become roster vacancies (eligible standby promoted, else rotation continues and stops at the first blocked show) instead of a hard pause; the 25-show gate was confirmed to be roster size, not an eligibility requirement. All 15 test suites pass (playlist-manager: 206 checks, including new deleted-show regressions). Final read-only preview: `intended=219, add=0, remove=0`.
- **2026-11-18 23:30** — User reported the playlist block between movie #146 and movie #151 had only 4 episodes (expected 5). Root cause: the deferred Lanterns S01E08 left slot #149 empty in the live playlist. A targeted Plex scan of the `F:` file was accepted but did not index it; a full refresh of section #2 ('Séries') picked it up as key `4550` (TMDb `7179889`, path on `F:`). That refresh also re-keyed Lanterns S01E06 (old `4447` → new `4551` after its nested `www.UIndex.org ...` folder was re-scanned), so a targeted folder refresh was needed to bring it back. The manager's preview now rebinds all four re-keyed Lanterns items (`Adds=4`, `ReboundKeys=4`, `Unresolved=0`, `DeferredMissing=0`) and the intended playlist closes the #146→#151 gap to 5 episodes. **No re-download; no live `-Apply` run by the assistant.** The two pre-existing intended gaps (#131 'America's Medicated Kids' → #136 'Origin', and #160 'Perfect Days' → #165 'The Ultra Zionists') remain and still need explicit approval to change.
- **2026-11-18 23:07** — User asked why Lanterns S01E08 was missing again; they had not deleted it. Investigation: the disk balancer moved the 6.19 GB file `K:` → `F:` at 22:09 (`moved` event in `logs/moves-20261118.jsonl`); the `F:` destination exists, but Plex has no S01E08 item because it has **not indexed the new path**, and the saved queue entry still holds old key `4446` plus the dead `K:` path. Added `Get-PlaylistRelocatedMedia`: a verified `moved` destination that still exists removes the episode from the download list and raises a `file-relocated-not-in-plex-...` alert ("Refresh the library section; do not re-download"). The download-summary count is now derived from the same pruned `DownloadMissing` set, so the alert and the short checklist agree. Lanterns S01E08 is **not** to be re-downloaded — a Plex library refresh should let the saved slot #149 be restored automatically. The short checklist is back to **9 episodes across 6 shows**; VisionQuest S01E08 is listed again after briefly reappearing at 22:35 and then vanishing with no file or move-log record.
- **2026-11-18 22:46** — User added the rule that "missing means unwatched": a watched episode must never be offered for download again, even if its file was retired afterward. The status now receives the set of watched TMDb episode ids from Plex items, saved queue entries and `state.Retired` records; move-log detections are checked against the same set. Re-running the preview dropped VisionQuest S01E08 because it was independently re-added to Plex at ~22:35, not because of the watched filter. The checklist is now **9 episodes across 7 shows**.
- **2026-11-18 22:37** — User clarified that the file's purpose is simply "what to download, again or for the first time", and that missing files **behind** the rotation cursor belong in it too. The download list no longer reuses the retirement check's cursor-filtered `Missing`; `Get-PlaylistTvStatus` now also returns `DownloadMissing` from each show's collection start, independent of the cursor. This added Lanterns S01E08 and Penn & Teller S11E06/E07 to the list alongside the two VisionQuest purges. The checklist is now **10 episodes across 7 shows**, and the download summary alert uses the same set.
- **2026-11-18 22:17** — User pointed out that VisionQuest S01E03/S01E04 must appear as missing. Both files were purged from the Recycle Bin at 21:05 (`recycle_destroyed` for the `F:` and `G:` copies), their old keys `4202`/`4204` had already been removed from `Queue`/`BaseQueue`, and they sit behind the rotation cursor — so neither the deferral logic nor the TMDb check reported them. Added a destructive-move-log detector (`Get-PlaylistDestroyedMedia`) that verifies the old path is gone and no replacement exists in Plex; the short checklist now lists **7 episodes across 5 shows**.
- **2026-11-18 21:50** — Reconciled this ledger against the current balancer check instead of the stale hand-written list. **Missing now** is **5 episodes / 5 shows** (Dark Matter S02E10, Ted Lasso S04E10, VisionQuest S01E08, The Simpsons S38E07, Dexter: Resurrection S02E03), sourced from `notifications.json` and the 21:44 read-only preview. The 2026-11-17 section is marked historical; current figures are 232 items, `ActiveIds` 23, Cycle 8 at 23/25. Euphoria S03E8 (key `4413`) is recorded as resolved. `Update-PlaylistMissingLedger` now refreshes `Last updated` on `-Apply`, with a regression test covering it. No live playlist writes.

<!-- playlist-manager:missing:start -->
## Auto-tracked missing media

_None._

### Auto-tracked resolved media

_None._

<!-- playlist-manager:missing:end -->
