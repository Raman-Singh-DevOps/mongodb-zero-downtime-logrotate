# Fixing a Silent Cron Failure That Broke MongoDB Log Rotation Across a Fleet

> A real production incident, sanitized. A one-character shell typo made
> scheduled log rotation **silently do nothing** on most of a MongoDB fleet —
> risking disk-full outages because logs and database files shared the same
> volume. This repo walks through the problem, the diagnosis, the fix, and the
> reusable tooling that came out of it.

---

## Step 1 — Why this setup exists in the first place

MongoDB's `mongod.log` grows continuously — on a busy node, **tens of GB per
week**. Left alone it becomes a single, ever-growing file. Rotating it (splitting
into dated files, keeping the last 7, and compressing the old ones) buys three
concrete wins:

- **Disk saved.** On these servers the **database data files and the logs lived
  on the same disk volume**. An unrotated log isn't untidy — it's a path to a
  **disk-full outage that takes the database down**. `compress` also shrinks old
  logs dramatically (a 25 GB log compresses to ~3 GB gzip — roughly **8×**),
  so the retained history costs a fraction of the space.
- **Faster, cheaper log analysis.** Grepping or parsing a **multi-GB monolith**
  means the system reads every byte off disk into memory — slow, and heavy on
  CPU and page cache. With rotation, each file is a manageable **MB-to-low-GB
  slice for a single day**. To investigate an incident you `grep` (or `zgrep`)
  just the relevant day's file instead of scanning the entire history — the
  query returns in seconds instead of minutes, using far less CPU and memory.
- **Bounded, predictable footprint.** Retention (`rotate 7`) caps how much log
  is ever on disk, so growth can't creep up on you.

## Step 2 — The problem: rotation was "green" but dead

Log rotation was supposedly handled by a weekly `cron` job on every server.
Every dashboard said healthy. But the rotated log files on disk told a different
story: their dates didn't line up with the cron schedule at all — they were
leftovers from **manual** runs. The scheduled rotation hadn't actually run in
who-knows-how-long.

## Step 3 — The investigation: "fired" is not the same as "ran"

`cron`'s own log showed the job firing every week, right on schedule. So why no
rotation?

The command was written to redirect its output to a known file:

```
... /usr/sbin/logrotate ... > /tmp/mongo_rotate_error.log 2>&1
```

A clean run should leave that file **existing but empty**. Instead, the file
**didn't exist at all**. That absence was the clue: if the command had run and
redirected its output, the file would be there. A *missing* output file means
the command died **before it ever executed**.

Inspecting the crontab exactly as stored — with invisible characters made
visible — revealed the culprit:

```bash
crontab -l | cat -A      # $ marks the true end of each line
```

The line ended in **`2>&$`** instead of **`2>&1$`**.

## Step 4 — The root cause: one missing character

```
... > /tmp/mongo_rotate_error.log 2>&      # BROKEN — missing the 1
... > /tmp/mongo_rotate_error.log 2>&1     # CORRECT
```

`2>&` on its own is a **shell syntax error**. The shell rejected the whole line
and aborted it *before* running `logrotate`. That's why:

- `cron` logged that it "fired" → looked healthy on every check.
- `logrotate` **never ran** → logs never rotated.
- The error-log file **never got created** → the tell that exposed it.

It had been **copy-pasted across most of the fleet** from a template whose
`2>&1` got truncated to `2>&` somewhere along the way. One server was healthy;
the rest inherited the broken line.

## Step 5 — The fix

The fix itself was **one character** — restore the `1`:

```
2>&   →   2>&1
```

Then sweep every other server for the same copy-paste bug in one shot:

```bash
crontab -l | grep '2>&$'     # flags any redirect ending right after 2>&
```

Before touching any live crontab, back it up:

```bash
crontab -l > /root/crontab.backup-$(date +%F-%H%M)
```

And critically — **verify the effect, not the scheduler.** Each fix was
confirmed by an actual rotation happening: a fresh log created, the old one
compressed (e.g. a 25 GB log → ~3 GB gzip), and the database still serving with
no restart.

## Step 6 — Doing rotation right: zero downtime, no restart

Rotating a *database* log naively (rename/delete the file) doesn't work —
`mongod` keeps writing to the old file handle and the disk never frees. The
correct approach reopens the log via a signal, with **no restart and no
downtime**:

1. **`logRotate: reopen`** in `mongod.conf` — MongoDB reopens (not recreates)
   its log when signaled.
2. **`SIGUSR1`** sent from the logrotate `postrotate` hook — tells `mongod` to
   pick up the fresh file the moment the old one is rotated away.
3. **`delaycompress`** — compresses the *previous* rotation on the next run, so
   the newest rotated file stays readable for a beat before it's gzipped.

## Step 7 — Files created (in this repo)

| File | What it does |
|---|---|
| [`SETUP.md`](SETUP.md) | **step-by-step setup guide** — every command explained, for setting this up on your own server |
| [`config/mongod`](config/mongod) | logrotate config — zero-downtime rotation via `SIGUSR1`, `delaycompress`, 7-file retention |
| [`config/crontab.example`](config/crontab.example) | the correct cron entry, with the `2>&1` redirect that actually works |
| [`scripts/check-logrotate.sh`](scripts/check-logrotate.sh) | one-command health check — see Step 8 |

> **Want to set this up yourself?** Follow [`SETUP.md`](SETUP.md) — it walks
> through every step (isolate the config, signal MongoDB, schedule it safely)
> and explains exactly what each command does.

## Step 8 — Turning the diagnosis into a reusable health check

Rather than repeat the manual checks by hand, they're bundled into
[`scripts/check-logrotate.sh`](scripts/check-logrotate.sh). Run it on any node:

```bash
./scripts/check-logrotate.sh
```

It reports, in one pass:

1. Is the crontab redirect correct? (catches the `2>&` bug)
2. Did cron actually fire the command recently?
3. Was the last run clean? (error log exists **and** is empty)
4. What do the rotated log files look like now?
5. Is a rotation/gzip still in progress? (don't judge state mid-run)

## Step 9 — Lessons worth keeping

- **A job that "fired" is not a job that "ran."** Verify the *effect*, never
  just the scheduler's log line.
- **Design for a tell.** Redirecting to a known file means a *missing* file
  becomes evidence. Absence is a signal — if you set it up to be one.
- **`cat -A` makes invisible bugs visible.** A trailing `2>&` looks almost
  identical to `2>&1` until you render line endings.
- **Copy-paste propagates bugs across a fleet** — when you find one, sweep every
  host immediately.
- **Back up before you edit**, and **rotate DB logs with a signal, not a
  restart.**

---

*Sanitized from a real production incident. Hostnames, IPs, uptimes, schedules,
and other environment-specific details have been removed.*
