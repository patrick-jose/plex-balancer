# Playlist manager

## Critical continuation rule (user correction)

LATEST STOP RULE: 25 is the rotation size, NOT an all-or-nothing admission gate.
Add available next episodes in order and stop EXACTLY at the first show without
its next episode/replacement. Keep the partial cycle already added. Add one movie
per five newly queued TV episodes, not five movies for every attempted cycle.
Persist which shows have contributed to the partial cycle and the trailing
episode/movie phase, so a retry resumes at the missing show rather than starting
the alphabet over or skipping past it. Preserve existing RELATIVE order, not a
rule that new episodes must be appended after the entire movie-only tail.

The manual queue is an EXISTING VIEWING POSITION, not a template to rebuild from
the alphabetically first show. Preserve every imported item's order, including a
mid-cycle head, already-queued incomplete cycles, and the existing movie tail.
The queue originally starts with Spider-Noir because that is where viewing had
reached. Alphabetical/25-show/five-episode rules constrain NEW extensions only;
they never authorize retroactive sorting or removal of existing selections.

The first implementation violated this rule by rebuilding two full rounds,
moving the head to The Bear and dropping four existing episodes. Those four
actually belonged to complete manual cycles: the rebuild had ignored the viewing
head's mid-cycle offset. That was
incorrect, NOT intended behavior. `playlist-restore-order.ps1 -Apply` restored
the 135-item original order from the protected snapshot and rebased state to
version 2 with an immutable `BaseQueue`. A read-only continuation preview then
proposed zero additions/removals. Local automatic maintenance is paused pending
review; no file or watch-state deletion was performed.

After the separately confirmed watched-head retirement below, the live queue has
three remaining episodes of the already-started cycle, then two complete
25-distinct-show cycles. Fewer than 25 episodes remaining at the HEAD does not
mean that cycle was built incorrectly or needs replacement episodes inserted.

The user explicitly clarified the insertion point: AFTER "Next Goal Wins", add
The Bear S04E10 and continue the TV cycle. The movie-only tail is a reserve of
already selected films: reuse its next movie after every five TV episodes, in
unchanged movie order. Do not draw extra random films while this reserve can fill
the slots. Keep the existing viewing head and all old items' relative order.
On resuming a partial five-episode block, insert the remaining episodes BEFORE
the next unused reserve movie, not after it. A shortage stops NEW
additions only; keep all already-queued episodes. Watching an episode does not
by itself enable automatic removal while the deletion/removal policy is disabled.

This feature is separate from drive balancing. `playlist-manager.ps1` previews
by default and maintains only the configured managed copy with `-Apply`. It never
changes the original playlist, watch state or media files. Watched-file deletion
is deliberately disabled until the user identity and deletion policy are agreed.

An explicit, narrowly scoped watched retirement is now available separately:

```powershell
# Only after confirming this exact episode was watched from the managed queue:
.\playlist-retire-watched.ps1 -Show 'Show title' -Season 1 -Episode 4 -ConfirmedPlaylistViewing
# Add -Apply to permanently delete that ONE confirmed watched head episode file.
```

This is not an automatic sweep of Plex's watched flags. It requires a matching
verified queue/head, Plex watched state, one exact media file inside configured
roots, no active Plex session for that item/file, and exclusive access. Per the
user's policy, confirmed watched-playlist retirement does NOT query, launch or
close qBittorrent. This exception does not change storage-balancing or recycle-bin
torrent protections. A durable retirement transaction is saved before permanent deletion;
state and BaseQueue then exclude the item without reordering the remaining queue.
Recovery honors completed retirement records and pauses for incomplete ones.
Old snapshot restoration refuses to overwrite intentional retirements.

The user explicitly confirmed Spider-Noir S01E04 was finished while Clone Wars
S02E06 was playing. That one file was deleted and the managed entry removed.
The remaining original order was verified, Clone Wars remained playing, and no
watch flags were altered. Deleting shared media naturally makes it unavailable
from any other playlist referencing it; no original-playlist API edit is made.
Global automatic watched-file deletion still remains disabled.

```powershell
# First copy playlist.config.example.json to playlist.config.json and edit it.
.\playlist-manager.ps1                      # preview + local notifications
.\playlist-manager.ps1 -Apply               # extend/recover/reorder the copy
.\playlist-manager.ps1 -Apply -RecoverOnly  # repair saved intent, no new rounds
```

Personal configuration is Git-ignored. `playlist-data\` holds durable intended
queue, atomic state/previous-state backup, initial and latest apply snapshots,
metadata cache, `queue.md`, `last-result.json` and deduplicated notifications.
It is also Git-ignored and is NOT subject to dated audit-log pruning: losing
this state would lose the information needed to detect disappearing entries.

With `maintenanceEnabled: true` and an initialized state, the existing hourly
watcher runs playlist maintenance after balancing/reconcile, regardless of drive
slack. It uses the same mutex and a 900-second child timeout. No schedule or Plex
startup setting is changed. Notices appear in `status.ps1`, the watcher log, and
`playlist-data\notifications.json`; no external notification account is configured.

TMDb checks accept `tmdbReadToken` OR `tmdbApiKey` in the private, Git-ignored
`playlist.config.json` (either one is enough). Local settings take precedence;
`TMDB_READ_TOKEN`/`TMDB_API_KEY` environment variables remain fallback options.
Run `.\Test-Tmdb.ps1` to validate the credential without displaying it or changing
Plex. Never put real credentials in the committed example configuration. Without
it the manager explicitly reports that TV completion/released-episode checks and
TMDb franchise discovery are unavailable; it does not claim they succeeded.
Manual replacement overrides, user-confirmed thematic groups and conservative
numbered/shared-prefix title grouping still work. TMDb collection order uses
release/installment order, not an inferred fictional-universe timeline.

The older read-only discovery tool remains available independently:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\playlist-preview.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\playlist-preview.ps1 -Offline
```

It connects to the local Plex server using `PLEX_TOKEN` from the environment or
the current Windows user's Plex registry preferences. The token is never written
to a report. No new provider account is created. XML responses are decoded as
UTF-8, and library and playlist responses are paginated.

Reports go to `logs\playlist-preview\preview.md` and `preview.json` inside this
project. They contain personal viewing/library metadata and are Git-ignored by
the existing `logs/*` rule. Re-running replaces these two generated reports.
Personal conversation context, live Plex playlist IDs, observations and pending
decisions are saved in `PLAYLIST-CONTEXT.local.md` (also Git-ignored). All code,
rules, reports and handoff context are therefore available in this project.

## Confirmed scheduling rules

- Each round has 25 distinct shows, alphabetically ordered, one next episode from
  each. The preview currently uses Plex sort titles (ignoring a leading "The");
  this matches the observed manual order but is an implementation interpretation.
- Episodes advance numerically by season and episode, not alphabetically by title.
- One movie goes after every five episodes: five movie slots per complete round.
- Queue episodes up to the first missing next episode/replacement, preserving the
  partial cycle before that point. Name the shortage so the user can download
  replacement or newly released media. Do not skip the blocked show or require
  the entire cycle to be ready before adding its first episode.
  The rotation is 25 active shows, not a 25-show library limit: additional shows
  may wait as replacements. After a show's final queued episode, a replacement
   can occupy its slot in the next cycle without rewriting already queued items.
- Ordinary movie selection is random, without duplicates. Do not queue the entire
  movie library simply because it is available.
- Selecting a member of a related group brings in the group's available entries,
  ordered by installment for story franchises and by release date for documentary
  groups such as Louis Theroux. Separate related entries by two unrelated movies.
- Movie-only extension ends when the selected related group finishes. No extra
  random tail. Downloading remains manual.
- Discover related groups from Plex metadata or public internet sources, with
  title matching only as a fallback; do not require manual group designation as
  the only supported method. Terminator 1, 2, 3 is the reference franchise example.
- A film's library presence is not itself a reason to add it. Generate ordinary
  movie slots only after each five queued TV episodes, or fillers necessary to finish a related
  group that has entered the queue. The copied manual movie tail is not a rule to
  reproduce automatically.

## Roster, persistence and remaining limits

The older `playlist-preview.ps1` still requires exactly 25 selected IDs. The new
manager supports 25 ACTIVE shows plus standby replacements. It anchors initial
episode positions to the manual queue and persists cursors/active roster thereafter.
Manual replacement pairs (currently Beef -> From locally) are explicit overrides,
recorded as such, not invented TMDb completion results. With provider-confirmed
completion and the final episode queued, an available standby can be selected in
alphabetical order. Unknown or continuing exhausted shows pause the next round.
Specials (season zero) remain excluded provisionally; duplicate media versions of
the same episode count once. Ambiguous edition matches block recovery.

The initial live library had 26 shows: From is configured as standby for Beef.
The manager preserves the existing movie queue exactly, not merely as draw
preferences. New movie selection stops at five-episode slot demand or a selected
group's final entry. These bounds do not retrospectively trim the imported tail.
Later random choices are persisted; retries do not reshuffle the queue.
Fillers are unrelated singletons to avoid recursive expansion of every franchise.

In the discovery report, Wikidata groups are **candidates**, not accepted rules.
The optional Wikidata P179 lookup needs no API key, but P179
also includes universes and lists unrelated to franchises; it is not safe to use
blindly. Title fallback discovers Louis Theroux titles, but misses documentaries
whose titles do not include his name. Release dates shown for candidates are not
assumed to be story installment order. An online failure is reported without
pretending unrelatedness has been established.

The manager implements bounded movie scheduling and managed-copy synchronization.
The locally confirmed Louis Theroux group includes My Scientology Movie and
Altered States: Love Without Limits explicitly, so title fallback cannot omit them.
Group detection without provider credentials is necessarily incomplete. Complex
story chronology and alternate cuts need explicit order/edition policy; do not
pretend generic release-date sorting solves those cases. No automatic download
or watched-file deletion is implemented or enabled.

## TV status, missing episodes and notifications

Use TMDb TV metadata and episode air dates, matched to Plex using external IDs,
to distinguish a completed series from a continuing series with missing local
content. Downloading stays manual; notify the user when a show needs updating.

- **Ended/canceled, final released episode consumed:** the show can give way to
  a standby replacement. Ended/canceled status alone is insufficient: final
  episodes may still be missing locally or have future air dates.
- **Released episodes missing locally:** report the show and missing season/episode
  numbers, whether the show is continuing or ended; do not call it finished merely
  because its local queue is empty.
- **Continuing, caught up, future episode announced:** report waiting for release,
  not a download shortage. Do not automatically retire a continuing show just
  because it has no local next episode. If no full round is possible, pause it.
- **Continuing, no next date known:** status is awaiting new information, not ended.
- **Provider unavailable, ambiguous match/order, or incomplete data:** report
  unknown rather than authorizing retirement. Match numbering carefully; specials
  and alternate episode orders require an explicit policy.

An air date signals broadcast/release metadata, not guaranteed downloadable
availability. Notifications should say "aired/released episode missing locally,"
not promise that a file is available. Do not re-alert unchanged shortages every
poll; persist/deduplicate alerts. Notification destination (local status/log,
desktop, email, etc.) still needs selection; do not configure one unasked.

TMDb requires an API credential. Local authentication and live metadata checks
have now succeeded using the private configuration. Never embed credentials in
source, reports, logs or committed config. Use Test-Tmdb.ps1 for uncached validation.

## Missing playlist items and recovery

The manager must retain a durable intended queue, not treat Plex's current
playlist as its only source of truth. Drive-to-drive moves, disconnected disks,
disk errors and Plex rescans can remove playlist entries or recreate an item with
a different Plex ratingKey. Persist stable identities, intended positions and
relevant move history locally without storing credentials.

- Compare the intended queue with Patrick Automated. Detect missing entries,
  preserving their positions and the remaining TV/movie/group ordering.
- If the item is still in Plex, restore its playlist reference at the intended
  position. Resolve by stable media identity, not title alone or a stale ratingKey.
- If not indexed, first check whether its known source/destination volume and
  library paths are accessible, including any successful balancer move record.
  A missing or malfunctioning disk is not evidence of a watched/deleted item.
- For accessible media that Plex cannot find, trigger the relevant library's
  "Update Libraries"/scan operation, targeted to the affected folder when
  supported. Wait for scan completion with a bounded retry policy, resolve the
  item again, then restore it in order. Do not assume scan submission is completion.
- If the volume is absent/unhealthy, notify the user and retain the unresolved
  queue slot. Avoid repeatedly scanning an unavailable library root.
- If a completed scan still cannot resolve the media, notify the user with the
  item, expected location, affected drive/library and recovery outcome. Preserve
  the intended queue and retry safely later, without repeated identical alerts.
- Do not run destructive cleanup, empty Plex trash, or mark an item watched as
  part of recovery. Do not change Plex's library/trash settings without approval.
- Multiple missing items must be restored in their original relative positions,
  without duplicates and without reshuffling random movies on every retry.
- Distinguish manager-approved watched-item removal and deliberate user edits
  from accidental disappearance. Persist explicit removal decisions so a future
  recovery pass cannot re-add an item the user intentionally removed. The user
  edit/reconciliation policy needs agreement before enabling write mode.

Recovery edits are limited to the managed copy. The manager shares the balancer
mutex and matches stable provider/Plex GUIDs rather than relying on a stale
ratingKey or path. When an intended item is absent from Plex, or Plex still lists
it with a path that is no longer available, the manager refreshes the affected
Plex library section and waits for the scan with a timeout. It then rereads the
Plex library and resolves the item again by stable identity. If the item reappears,
the managed playlist can be repaired at its intended position. If it does not,
the manager reports the unresolved item, keeps its queue intent, and pauses
playlist writes; it does not search the computer's drives for the old path or
silently remove the entry. The original manual playlist is never written.

Every apply saves intent and snapshots BEFORE any mutation and verifies the full
result afterward. If Plex returns success for an ineffective item move, the
manager can rebuild references inside the SAME managed playlist ID, using the
saved ordered URI. This does not delete media or the playlist itself. A partial
update can be retried from saved intent with `-Apply -RecoverOnly`.

Once initialized, unexplained additional items or reordering is treated as a
possible manual edit and blocks writes. `-AcceptManualOrder` explicitly authorizes
RESTORING the saved intended order, not importing an arbitrary new rule. Missing
entries alone are treated as recoverable; deliberate individual removals are
therefore not inferred automatically. Until an explicit removal/tombstone UI is
implemented, turn maintenance off before manually changing the managed playlist.
Watched removal remains disabled, so recovery cannot resurrect a manager-deleted
media file. The original manual playlist is read-only throughout.

## Tests

`tests\playlist-preview.ps1` tests real round-planning functions against synthetic
metadata: roster size and uniqueness, alphabetical order, numeric episode order,
round advancement, shortage stopping, movie-slot limits, watched episodes,
specials and duplicate media versions. It does not connect to Plex or the internet.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -Suite playlist-preview
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -Suite playlist-manager
```

The manager suite covers roster/standby swaps, missing-episode gating, manual
anchors, numeric/alphabetical ordering, bounded and stable random movies, group
spacing, original/media write guards, atomic persistence and the real sync
algorithm against a fake Plex backend (including missing-item restoration,
idempotency, ineffective moves and server refusal). It does not test a real disk
failure or claim a live TMDb run without credentials.
