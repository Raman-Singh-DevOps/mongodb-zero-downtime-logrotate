# Setup Guide — Zero-Downtime MongoDB Log Rotation

A step-by-step guide to set this up on your own server. Every step tells you
**what to run, why, and exactly what the command does.** Tested on AWS EC2
(Linux) with a self-managed MongoDB, but it applies to any Linux host running
`mongod`.

> New here? Read the [README](README.md) first for *why* this matters (disk,
> faster log search, and the silent cron bug that motivated it). This file is
> the practical how-to.

---

## What you need before you start

| Requirement | Why |
|---|---|
| A Linux server running a self-managed `mongod` | This rotates `mongod`'s own log file |
| `root` / `sudo` access | Log dirs, `mongod.conf`, and the root crontab are all privileged |
| `logrotate` installed | The rotation engine (`logrotate --version` to check; `apt install logrotate` / `yum install logrotate` if missing) |
| Your MongoDB log path | This guide assumes `/data/log/mongodb/mongod.log` — change it everywhere if yours differs |

**Check your actual log path first** (don't assume): 

```bash
grep -A5 systemLog /etc/mongod.conf
```

Look at the `path:` line — that's the file you'll be rotating. If it's not
`/data/log/mongodb/mongod.log`, substitute your path in every step below.

---

## The key design decision: isolate the config

The default logrotate directory `/etc/logrotate.d/` is scanned **automatically
by the OS every day** (via `/etc/cron.daily/logrotate`). If you drop your config
there, the OS engine can rotate your MongoDB log **prematurely and on its own
schedule** — fighting your intended timing.

By putting the config in a **custom directory** (`/etc/logrotate.custom/`) that
the OS does *not* auto-scan, and leaving out time keywords like `weekly`, you
make **your own crontab the single source of truth** for when rotation happens.
No surprise double-rotations, full control.

---

## Step 1 — Create the isolated logrotate config

**Run:**

```bash
sudo mkdir -p /etc/logrotate.custom
sudo vi /etc/logrotate.custom/mongod
```

- `mkdir -p /etc/logrotate.custom` — creates the custom directory outside the
  OS auto-scan path (`-p` = don't error if it already exists).
- `vi /etc/logrotate.custom/mongod` — opens the new config file for editing.

**Paste this content** (also in this repo at [`config/mongod`](config/mongod)):

```
/data/log/mongodb/mongod.log {
    rotate 7
    dateext
    compress
    delaycompress
    missingok
    notifempty
    create 640 mongod mongod
    sharedscripts
    postrotate
        /bin/kill -SIGUSR1 $(/usr/bin/pgrep mongod) 2>/dev/null || true
        sleep 1
        # Delete 0-byte Mongo timestamp logs
        /usr/bin/find /data/log/mongodb/ -name "mongod.log.*T*" -size 0 -delete
    endscript
}
```

**What each line does:**

| Directive | What it does |
|---|---|
| `rotate 7` | Keep 7 rotated files, then delete the oldest |
| `dateext` | Name rotated files with a date suffix (`mongod.log-YYYYMMDD`) |
| `compress` | gzip rotated files to save disk |
| `delaycompress` | Compress on the *next* run, so the newest rotation stays readable for a beat |
| `missingok` | Don't error if the log is temporarily absent |
| `notifempty` | Skip rotation if the log is empty |
| `create 640 mongod mongod` | Recreate the fresh log owned by `mongod:mongod` with `640` perms |
| `sharedscripts` | Run the `postrotate` block once, not once per matched file |
| `postrotate … endscript` | Commands to run right after the file is rotated (see below) |

**The `postrotate` block is the zero-downtime magic:**

- `/bin/kill -SIGUSR1 $(/usr/bin/pgrep mongod)` — sends signal **SIGUSR1** to
  the running `mongod`. MongoDB responds by closing its current log handle and
  reopening the path from `mongod.conf`. This is what lets logrotate move the
  old file **without the database losing track of where to write** — no restart,
  no downtime. `2>/dev/null || true` keeps the hook from failing if `mongod`
  isn't running.
- `sleep 1` — gives `mongod` a moment to finish reopening.
- `find ... -size 0 -delete` — cleans up empty 0-byte timestamped logs MongoDB
  can leave behind.

---

## Step 2 — Tell MongoDB to reopen (not recreate) its log

Edit `/etc/mongod.conf` and make sure the `systemLog` section has
`logRotate: reopen`:

```yaml
systemLog:
  destination: file
  logAppend: true
  path: /data/log/mongodb/mongod.log
  logRotate: reopen
```

- `logRotate: reopen` — on SIGUSR1, MongoDB **reopens the existing path**
  instead of renaming its own file. This is the setting that pairs with the
  SIGUSR1 signal from Step 1. Without it, rotation won't behave cleanly.
- `logAppend: true` — append to the log on startup rather than overwriting.

> If you change `mongod.conf`, the `logRotate` setting takes effect for
> rotations going forward — you do **not** need to restart to rotate, because
> SIGUSR1 drives it.

---

## Step 3 — Test it manually first

Never trust a rotation you haven't watched run. Force one by hand:

```bash
sudo logrotate -v -f /etc/logrotate.custom/mongod
```

- `sudo` — needs root to touch protected log files.
- `-v` (verbose) — prints every action, so you can see the rotation happen and
  catch permission or syntax errors immediately.
- `-f` (force) — ignore timing rules and rotate **right now** (otherwise
  logrotate may decide "not time yet" and do nothing).
- `/etc/logrotate.custom/mongod` — targets your isolated config.

---

## Step 4 — Confirm the result

```bash
ls -lh /data/log/mongodb/
```

- `ls -lh` — long listing with **human-readable** sizes (`h`).

**Expected:** a fresh `mongod.log` plus rotated files with date suffixes, e.g.
`mongod.log-20260710` (and older ones as `.gz`). Confirm the fresh log is owned
by `mongod:mongod`. If you see that, the zero-downtime rotation worked.

---

## Step 5 — Automate it with cron

Schedule it in the **root** crontab (root, because it writes to protected paths):

```bash
sudo crontab -e
```

Add this line (also in this repo at [`config/crontab.example`](config/crontab.example)):

```
# Runs every Tuesday at 18:00 UTC
0 18 * * 2 /usr/sbin/logrotate -f /etc/logrotate.custom/mongod > /tmp/mongo_rotate_error.log 2>&1
```

- `0 18 * * 2` — cron schedule: minute 0, hour 18, any day, any month,
  weekday 2 (Tuesday). **Pick your own low-traffic window.**
- `/usr/sbin/logrotate -f /etc/logrotate.custom/mongod` — force-run your
  isolated config.
- `> /tmp/mongo_rotate_error.log 2>&1` — redirect **both** stdout and stderr to
  a known file. A clean run leaves this file **empty**; a *missing* file is your
  tell that the command never ran.

> ⚠️ **The most important character on this line is the `1` in `2>&1`.**
> Writing `2>&` (missing the `1`) is a shell **syntax error** — cron will log
> that it "fired" but the command dies before `logrotate` runs, and rotation
> **silently never happens.** This exact typo is the incident the
> [README](README.md) is about. Always verify with:
>
> ```bash
> crontab -l | cat -A     # a correct line ends in  2>&1$
> ```

---

## Step 6 — Verify the automation (don't just trust it)

Before you walk away, and after the first scheduled run, sanity-check it with the
included script:

```bash
./scripts/check-logrotate.sh
```

It confirms the crontab redirect is correct, that cron actually fired, that the
last run was clean (error log exists **and** is empty), and shows the current
rotated files. See the [README](README.md) for what each check means.

---

## Quick reference

```bash
# 1. Create isolated config
sudo mkdir -p /etc/logrotate.custom
sudo vi /etc/logrotate.custom/mongod          # paste config/mongod

# 2. Ensure  logRotate: reopen  in /etc/mongod.conf

# 3. Test by hand
sudo logrotate -v -f /etc/logrotate.custom/mongod

# 4. Confirm
ls -lh /data/log/mongodb/

# 5. Schedule (root crontab) — mind the 2>&1 !
sudo crontab -e
# 0 18 * * 2 /usr/sbin/logrotate -f /etc/logrotate.custom/mongod > /tmp/mongo_rotate_error.log 2>&1

# 6. Verify
crontab -l | cat -A
./scripts/check-logrotate.sh
```
