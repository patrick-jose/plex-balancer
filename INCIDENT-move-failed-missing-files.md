# Incident: `move_failed` (access denied on source) followed by missing episode files

**Status:** Open / recurring concern (user reports this has happened before).  
**First documented:** 2026-11-07 (session `2026-10-03/session-45a7cc21-c381-44be-ab02-d78ca1950b8a`).  
**Affected host context:** Windows, `C:\Users\patri\plex-balancer` (uncommitted local changes may exist), Plex-managed balancer/playlist stack.

## Purpose
Capture concrete evidence when a balancer **move fails** and the source file is later **missing**, so future occurrences can be diagnosed to a definitive root cause. This doc must distinguish **proven facts** from **hypotheses**.

> **Safety note (user concern):** Deleting downloaded, unwatched files is dangerous. Any confirmed deletion path that can remove unwatched library media outside explicit, audited retirement rules is a critical bug.

## 2026-11-07 occurrence

### Reported/symptom
User observed balancer output showing `MOVE FAILED` for three episodes and later found those episodes missing from the library / not present at expected paths. User concern: balancer deleted files that should not be deleted.

### `logs/moves-20261107.jsonl` evidence (exact events)
All three were planned as `K:` → `D:` moves and failed with **access denied on the K: source path** (`"O acesso ao caminho 'K:\...' foi negado."`). No `moved`, `partial_removed`, or `partial_remove_failed` events were found for these files.

```json
{"at":"2026-11-07T11:10:33.0200853-03:00","event":"move_failed","apply":true,"dest":"D:\\SǸries\\Saturday Night Live\\Season 52\\Saturday Night Live S52E02 Dakota Johnson October 3 2026 2160p PCOK WEB-DL DD 5 1 Atmos HDR H 265-playWEB.mkv","path":"K:\\SǸries\\Saturday Night Live\\Season 52\\Saturday Night Live S52E02 Dakota Johnson October 3 2026 2160p PCOK WEB-DL DD 5 1 Atmos HDR H 265-playWEB.mkv","error":"O acesso ao caminho \u0027K:\\SǸries\\Saturday Night Live\\Season 52\\Saturday Night Live S52E02 Dakota Johnson October 3 2026 2160p PCOK WEB-DL DD 5 1 Atmos HDR H 265-playWEB.mkv\u0027 foi negado.","sizeGB":7.48}
{"at":"2026-11-07T11:14:53.1814078-03:00","event":"move_failed","apply":true,"dest":"D:\\SǸries\\Ted Lasso\\Season 4\\Ted Lasso S04E10 Being Alive 2160p ATVP WEB-DL DDP5 1 Atmos H 265-playWEB.mkv","path":"K:\\SǸries\\Ted Lasso\\Season 4\\Ted Lasso S04E10 Being Alive 2160p ATVP WEB-DL DDP5 1 Atmos H 265-playWEB.mkv","error":"O acesso ao caminho \u0027K:\\SǸries\\Ted Lasso\\Season 4\\Ted Lasso S04E10 Being Alive 2160p ATVP WEB-DL DDP5 1 Atmos H 265-playWEB.mkv\u0027 foi negado.","sizeGB":8.32}
{"at":"2026-11-07T14:11:56.9740521-03:00","event":"move_failed","apply":true,"dest":"D:\\SǸries\\Dexter Resurrection\\Season 1\\Dexter Resurrection S01E10 And Justice For All 1080p TrueHD 5 1 AVC REMUX-FraMeSToR.mkv","path":"K:\\SǸries\\Dexter Resurrection\\Season 1\\Dexter Resurrection S01E10 And Justice For All 1080p TrueHD 5 1 AVC REMUX-FraMeSToR.mkv","error":"O acesso ao caminho \u0027K:\\SǸries\\Dexter Resurrection\\Season 1\\Dexter Resurrection S01E10 And Justice For All 1080p TrueHD 5 1 AVC REMUX-FraMeSToR.mkv\u0027 foi negado.","sizeGB":9.79}
```

### State observed during investigation (2026-11-07)
- Exact recorded K: source and D: destination paths were **not found** by `Test-Path`/directory inspection in that session (some listings were inconclusive due to shell/access behavior; re-check manually with sufficient permissions).
- Plex library did **not** contain these as local present episodes in that investigation:
  - `Saturday Night Live` (key 4230): S52E1/E3/E4 present; **S52E2 absent** (and S52E5 also reported absent by metadata check).
  - `Ted Lasso` (4242): up to S4E9 present in checked context; **S4E10 absent**.
  - `Dexter: Resurrection` (3970): S1E1–S1E9 present, **no S1E10 library entry**, **S2E1 “Risky Business” present** on `D:\SǸries\Dexter Resurrection\Season 2\...` (exists). This may indicate a numbering/metadata/import mismatch in addition to/ instead of simple file loss; verify separately.
- `playlist-data/notifications.json` / watch logs reported `tv-missing-*` “aired/released episodes absent locally” for these shows/episodes (metadata says aired/released; not present in local Plex library). This is **not** proof of balancer deletion.
- No retirement records for these unwatched episodes: no matching `playlist-data/retirement-*.json`/`before-retirement-*.json`/`state.Retired` entries deleting S52E02, S04E10, or S01E10. Only unrelated watched retirement found in that check: `Ted Lasso S4E2` (`watched=True, deleted=True, Complete`).

## What the balancer code does (relevant paths)

### `balance.ps1` move failure — **does not delete source**
- `balance.ps1:612-626`: on move/copy failure it catches, logs `move_failed` (`:614`) with `path`/`dest`/`sizeGB`/`error`, warns, removes **only a partial destination** if present (`:617-624`, `Remove-Item -LiteralPath $DestPath`), logs `partial_removed`/`partial_remove_failed` as applicable, then `return $false` (`:625`). **It does not delete `$Unit.Path` (source).**
- `balance.ps1:651-654`: source deletion (`Remove-Item -LiteralPath $Unit.Path`) occurs only on the **success** path after copy/verify. Unreachable after failure `return`.

**Interpretation:** For these 2026-11-07 events, the recorded behavior is “attempted move, access denied on K: source, failure path taken”. That specific handler does not prove source deletion by balancer.

### Watched retirement — **watched-only, audited separately**
- `playlist-manager.ps1:82+` `Invoke-AutomaticRetirement`: selects candidates in the frozen watched window where item is episode/movie **and `Watched`** (`:91-93`), enforces path/root/safeguards, checks active Plex sessions, uses durable retirement transactions (`retirement-<key>.json`, `before-retirement-<key>.json`), deletes file via `Remove-PlaylistRetirementFile`.
- `playlist-lib.ps1:895-906` `Get-PlaylistRetirementCandidate`: throws `"Episode is not watched in Plex."` if `-not $item.Watched` (`:903`).
- `playlist-lib.ps1:785-808` `Remove-PlaylistRetirementFile`: actual file deletion (DeleteOnClose/exclusive handle) used by retirement flow.

Retirement is **not** implicated by the 2026-11-07 `move_failed` records for these unwatched/absent-locally episodes.

### Other deletion paths (audit targets for future “not first time” cases)
When investigating recurrence, review every deletion path, not just retirement/move-success:
- `balance.ps1`: source delete after verified move (`:651-654`), partial-dest cleanup (`:619-620`), recycle-bin payload/meta destruction/reclaim (`:681+`, `:941-942,950`), other `Remove-Item -Force` uses — confirm each precondition.
- `reconcile.ps1`: duplicate/smaller-copy cleanup (`Remove-Item` on duplicate paths) — confirm it cannot target a sole unwatched library copy incorrectly.
- `watch.ps1`: backup pruning and log pruning (`:293`, `:353`) scoped to backup/log dirs, age, and log filename patterns — should not touch media library roots.
- Playlist/retirement scripts: `Remove-PlaylistRetirementFile` and retirement transactions only.

A **full deletion-path audit** should be performed/documented if incidents recur.

## Proven vs unproven (2026-11-07)

### Proven
- Balancer attempted to move these 3 files from `K:` to `D:` and logged `move_failed` with **access denied on K: source** at the times above.
- The `move_failed` handler in `balance.ps1` cleans partial destination and returns; it does **not** delete the source in that path. Source deletion is in the success path only.
- Files were not present at the recorded source/dest paths during investigation; Plex/library state showed them absent locally (with Dexter S1E10/S2E1 nuance).
- No retirement records showed balancer watched-retirement deletion of these specific unwatched episodes.

### Not proven
- That `balance.ps1` deleted these source files as part of the `move_failed` events. (Code/log evidence contradicts that specific mechanism.)
- The exact actor/process that removed or made the files inaccessible after they existed on K: (could be external deletion/move, Sonarr/Radarr/qBittorrent, AV quarantine/removal, filesystem corruption/recovery, permission/ACL changes, manual action outside observed context, or another code path not yet identified).

### Strong clues
- **Access denied on K: source** at move time is highly relevant. Investigate K: permissions/ACLs, file locks, drive health/remount, AV, and any process touching those exact paths.
- **Correlation is real** (all 3 missing-in-library episodes in that report correspond to move-failed occurrences). Correlation requires explanation, but is not by itself proof of deletion by the `move_failed` handler.

## Investigation checklist for future occurrences
Record before re-downloading/replacing files when possible:

1. **Preserve logs/artifacts**
   - Copy relevant `logs/moves-*.jsonl`, `logs/watch-*.log`, `logs/reconcile-*.jsonl`, `logs/status-*.jsonl` lines.
   - Copy `playlist-data/notifications.json`, `playlist-data/state.json` (or relevant diffs), any `retirement-*.json` / `before-retirement-*.json` around the time.
   - Note balancer version/commit and local uncommitted diffs (`git status`, `git diff --stat`).
2. **Exact event data**
   - `event` (`move_failed`/`moved`/`skip_in_use`/`source_delete_failed`/etc.), `path`/`source`, `dest`, `error`, size, timestamp.
3. **File presence (run with sufficient permissions)**
   - Check source, dest, partial dest, same filename elsewhere on all roots/drives: `Get-ChildItem <roots> -Recurse -Force -Include '*<pattern>*' -ErrorAction SilentlyContinue`.
   - Check `$Recycle.Bin` on every drive (K:, D:, etc.) for the exact filename/release.
   - Check download/staging/import folders and Sonarr/Radarr category paths.
4. **K:/drive & access (especially for access-denied failures)**
   - Drive online/health: SMART, `chkdsk <drive>: /scan` (read-only), filesystem errors.
   - ACL/ownership/Effective Access on the file and parent folders.
   - Whether another process had the file open (handle/lock tools, AV, Plex, torrent client).
5. **External actors**
   - Sonarr/Radarr history/activity for the exact release/episode (grab, import, rename, move, delete, upgrade, failed import).
   - qBittorrent/other download client history and category/save-path behavior.
   - Antivirus/EDR quarantine, remediation, or blocked-access history for the exact path.
6. **Plex/library state**
   - Whether Plex ever had the episode entry/file; current library entries; season/episode numbering (e.g. Dexter S1E10 vs S2E1 mapping).
   - `tv-missing-*` notifications mean “aired/released per metadata, absent from local Plex library”, not proof of balancer deletion.
7. **Code audit (if mechanism suspected)**
   - Trace the exact event type to handler code; confirm whether source/dest/media can be deleted on that path.
   - Search all `Remove-Item`, `[IO.File]::Delete`, `Move-Item`-overwrites, and any external process calls that delete files.

## Future incident template
Append entries here:

```md
### YYYY-MM-DD occurrence
- **Episodes/files:**
- **moves/log entries:** (paste JSON lines)
- **Failure/error:**
- **Source present at failure? Dest/partial present? Current locations:**
- **Plex library state:**
- **Retirement records:**
- **Sonarr/Radarr/qBittorrent history:**
- **AV/quarantine/Recycle Bin:**
- **K:/drive permissions/health:**
- **Conclusion (proven):**
- **Open questions:**
```
