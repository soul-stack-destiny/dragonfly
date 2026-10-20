# dragonfly

A Soul Stack unit that sets up [Dragonfly](https://www.dragonflydb.io/) on one host: it installs
the binary from an official release tarball, renders the flagfile, the ACL file, the TLS material
and a root-only environment file for the passwords, runs it as a hardened systemd service under
its own system account, and waits until it answers.

It brings **one host** to the desired state. Deciding who is master, promoting a replica, running
an upgrade across a cluster — that is orchestration, and it belongs to whatever calls this.

```yaml
- name: Set up the cache
  apply:
    destiny: dragonfly
    input:
      version: "2.0.2"
      # the x86_64 tarball of that release — the hash is per (version, architecture)
      sha256: "sha256:eb9dfe654c69ab190cb3aa329ed3599ebe19c5e9a3a437bb7bc38ef52f665c88"
      password: "${ vault('secret/team-a/cache-prod#password') }"
      maxmemory: "8GiB"
      snapshot_cron: "0 * * * *"
```

## What you get

| | |
|---|---|
| **Install** | the `dragonfly` binary from the official release tarball, pinned by version, optionally checksum-verified, from GitHub releases or your own mirror |
| **Service** | a systemd unit under a stable system account, with a sandbox: read-only filesystem apart from the two directories it owns, no privilege escalation, one capability |
| **Config** | a flagfile with the settings this unit manages, plus a passthrough map for everything else |
| **Authentication** | an ACL file with two system accounts — `default` for applications, `default_admin` for the operator — plus any extra users you declare; passwords stored as hashes, the plaintext one only in a 0600 root-only environment file |
| **TLS** | server certificate and key read from Vault by path, written 0600 to the service account |
| **Replication** | this instance can start as a replica of a given master, with its own credentials |
| **Metrics** | Prometheus metrics on a console port, loopback by default — no exporter needed |
| **Snapshots** | a schedule, locally or straight to S3-compatible object storage, and a daily timer that prunes old local snapshots when you keep more than one |
| **Host tuning** | huge pages off, log rotation, kernel parameters |
| **Teardown** | `ensure: absent` reverses all of it, keeping the snapshots unless you ask otherwise |

Every input is documented in [`destiny.yml`](destiny.yml); the task list is
[`tasks/main.yml`](tasks/main.yml).

## The defaults are stricter than Dragonfly's

Three of them differ from what you get by running the binary yourself, deliberately:

- **the bind address.** Dragonfly binds every interface when told nothing. This unit binds this
  host's primary IP unless `host` says otherwise, and falls back to loopback if the host reports
  no primary IP — a local-only service is a safe failure, an open one is not.
- **the HTTP console on the data port** is off (`http_console`). That console answers WITHOUT
  authentication even when the data port demands a password, so leaving Dragonfly's default in
  place publishes your keyspace statistics to anyone who can reach the port. Metrics come from the
  console port instead (below).
- **the release check** is off (`version_check`). An installed service should not talk to its
  vendor daily unless you ask it to.

And one refusal: without `password`, the unit will not render at all unless you set
`allow_unauthenticated: true`. An open datastore is a decision, not an oversight.

## Accounts

Two system accounts, the same split the `redis` unit uses:

| Account | For | Permissions |
|---|---|---|
| `default` | applications — this is what a client gets when it just sends `AUTH <password>` | `default_perms`: every key and channel, every ordinary command, but **not** the administrative and dangerous ones |
| `default_admin` | the operator | everything (`~* &* +@all`) |

```yaml
password:       "${ vault('secret/team-a/cache-prod#password') }"        # default
admin_password: "${ vault('secret/team-a/cache-prod#admin') }"           # default_admin
users:
  reporting:
    perms: "~report:* +@read"
    state: "on"
    password: "${ vault('secret/team-a/cache-prod#reporting') }"
```

Live, that comes out as:

```
default        SET k v          → OK
default        CONFIG SET …     → NOPERM
default_admin  CONFIG SET …     → OK
reporting      GET report:x     → OK
reporting      GET other:x      → NOPERM
```

`admin_user` renames the administrative account; `admin_password` is what creates it at all —
leave it empty and there is no administrative account, and with the default `default_perms`
nobody can then run `CONFIG SET`, `FLUSHALL` or `ACL` over the wire. That is usually what you
want on a host managed by this unit: configuration changes by re-running it, not over the wire.
If you would rather have one account that does everything, set `default_perms: "~* &* +@all"`.

Passwords are written into the ACL file as SHA-256 hashes. The `default` one additionally goes
into the environment file, in plaintext but 0600 root-only, because Dragonfly needs it there to
accept a TLS configuration at all. Neither is ever written into the flagfile.

### The ACL file is all-or-nothing, and it fails quietly

**With an ACL file configured, Dragonfly takes its entire user list from that file.** On 1.39, if
`default` is not named in it, `default` stays the built-in passwordless account with full access —
and no password configured anywhere else changes that.

Worse, three different mistakes make Dragonfly reject the **whole file**, log one line and start
anyway: a `default` entry that is disabled (`off`), a line the parser does not understand, and —
because the hash marker is a hash — a comment line. Every user the file declares is then gone, the
administrative account included. On 1.39 that left the open `default` behind. On 2.0.2, for the two
cases re-checked (a comment line, an unknown permission), `default` instead answered `NOAUTH`
under the password in the environment file.

"A line the parser does not understand" includes a permission it does not know. Dragonfly has no
`PSYNC` and no `@replication` category, so the Redis-style replication rule `+psync +replconf`
voids the file. A replication account here is `-@all +replconf +ping +dfly`.

So this unit writes the file itself, without comments, always with `default` in it, and refuses to
render if you try to declare `default` or the admin name in `users`.

## Metrics: no exporter

Dragonfly exposes Prometheus metrics itself — around a hundred `dragonfly_*` families covering
memory, keyspace, connections, replication, evictions and snapshots. There is no separate
exporter to deploy, and pointing `redis_exporter` at it would only re-derive a subset.

They live at `/metrics` on the **console port** (`admin_port`, 6380 by default), which binds
loopback unless `admin_bind` says otherwise, and stays plain HTTP even when the data port speaks
TLS — so a local scraping agent needs no certificate. That endpoint needs no password either,
which is exactly why it defaults to loopback: opening it to the network is a decision you make
with `admin_bind`.

Setting `admin_port: 0` disables the console. The unit's readiness check polls that same endpoint,
so with the console off there is nothing to poll and the check is skipped.

## Backups

Dragonfly holds its dataset in memory. The only thing on the host worth copying anywhere is the
snapshot set under `data_dir` — so a backup is: snapshots on a schedule, plus whatever you already
use to get files off a host (or write them straight to a bucket, below).

**There is no point-in-time recovery.** Dragonfly has no append-only log and no write-ahead log —
the flags with "journal" in the name belong to replication, not to durability. Recovery therefore
lands on whole snapshots: the worst case you can lose is everything written since the last one, so
`snapshot_cron` is what sets your recovery point, and a `{timestamp}` filename plus retention is
what gives you older ones to fall back to. If you need to replay to an arbitrary moment, this is
not the engine for it — a replica narrows the window for a lost host, but it follows a `DEL` just
as faithfully as a write.

**Snapshots are off unless you schedule them.** With no `snapshot_cron`, Dragonfly writes one only
when something asks for it over the wire, and a restart loses everything since then.

```yaml
snapshot_cron: "0 * * * *"     # hourly
dbfilename: "dump"             # one snapshot, replaced in place (the default here)
```

`dbfilename` decides whether you keep one snapshot or all of them:

- **`dump` (this unit's default)** — every snapshot overwrites the previous one. The directory
  stays at one summary file plus one file per shard, and "copy `data_dir`" is a complete backup.
- **`dump-{timestamp}` (Dragonfly's own default)** — every snapshot is a new set of files, kept
  forever. Point-in-time history, and a directory that grows until the volume is full, because
  **Dragonfly never removes an old snapshot**.

For the second shape, set `snapshot_retention_days`. The unit then installs a daily timer that
deletes snapshot files older than that, running as the service account with the snapshot directory
as its only writable path:

```yaml
snapshot_cron: "*/15 * * * *"
dbfilename: "dump-{timestamp}"
snapshot_retention_days: 7
data_dir: /srv/dragonfly     # its own volume, off the root filesystem
```

### Straight to S3 (or any S3-compatible store)

`snapshot_uri` replaces the local directory with a bucket:

```yaml
snapshot_cron: "*/15 * * * *"
snapshot_uri:  "s3://backups/dragonfly/prod"
snapshot_s3:
  region:     "eu-central-1"
  access_key: "${ vault('secret/team-a/cache-prod#s3_access_key') }"
  secret_key: "${ vault('secret/team-a/cache-prod#s3_secret_key') }"
```

On a host whose instance role already grants access, drop the keys and set
`snapshot_s3: { ec2_metadata: true }`. For MinIO, Ceph or an internal gateway, add
`endpoint: "minio.internal:9000"` and, if it is plain HTTP, `use_https: false`; a gateway that
dislikes signed payloads takes `sign_payload: false`.

Dragonfly has **no flags for S3 credentials**, so they can only come from the environment — which
here means the same 0600 root-only file the password uses, never a command line. The rendered
flagfile carries the bucket and the endpoint; the keys do not appear in it.

Two things worth knowing before you point production at a bucket:

- **the bucket is not just a backup target, it is also the source.** Dragonfly loads its snapshot
  through the same setting at startup, so the instance now depends on the store being reachable.
  If it cannot list the bucket, **it refuses to start** (exit code 1, port never opens) rather
  than coming up empty or silently skipping backups. That is the safe direction, and the unit's
  readiness check turns it into a failed run instead of a surprise. Bad credentials, a wrong
  endpoint and a typo in the bucket name all look like this.
- **retention is the bucket's job.** `snapshot_retention_days` runs `find` over a local
  directory and cannot reach an object store, so the two are refused together — use the bucket's
  own lifecycle rules.

The local data directory is still created and still holds the process's working directory; it
just holds no snapshot.

One more option through `extra_flags`: `{df_snapshot_format: "false"}` writes RDB instead of
Dragonfly's own format, if something downstream needs to read the snapshots as Redis dumps.

## TLS

Pass Vault paths; the unit reads them and writes the PEM files under `<conf_dir>/tls`, private key
0600, owned by the service account:

```yaml
tls:
  enable: true
  cert_ref: "secret/team-a/cache-prod#cert"
  key_ref: "secret/team-a/cache-prod#key"
```

Two things follow from how Dragonfly implements TLS:

- **there is no separate TLS port.** TLS runs on the data port, so turning it on closes the
  plaintext one. Every client has to speak TLS from that moment.
- **`ca_ref` is not "trust this CA", it is "require client certificates".** Dragonfly has no
  verify-if-offered mode, so a CA makes mutual TLS mandatory for every connection. Leave it out
  for ordinary server-side TLS.

Dragonfly also refuses to start with TLS enabled and no way to authenticate a client — and an ACL
file does not count for that check. The unit turns that into a render-time refusal rather than a
service that installs cleanly and then fails to come up.

## Replication

`replica_of` makes this instance start as a replica of the given master. This is the state as of
startup: a later `REPLICAOF` over the wire wins until the process restarts.

`master_user` and `master_auth` are the credentials it authenticates with, and they do not need
`replica_of`. Give them to every node of a replicated set, the master included: a Sentinel
failover demotes the old master with a bare `REPLICAOF` and sends no credentials, so a node
without its own cannot reach the new master.

```yaml
replica_of: "10.0.0.5:6379"   # omit on the master
master_user: "replication"     # declared in users with "-@all +replconf +ping +dfly"
master_auth: "${ vault('secret/team-a/cache-prod#replication') }"
tls_replication: true      # only with tls.enable
```

## Sentinel

Not here — Dragonfly ships no sentinel daemon of its own. It speaks the Redis wire protocol, so a
Redis Sentinel watching a Dragonfly master works: deploy it from the `redis` unit with its data
plane switched off (`deploy_redis: false`, `sentinel_enabled: true`), pointed at this instance.

## Memory: the one setting that stops the service from starting

Dragonfly requires **at least 256 MiB of `maxmemory` per io thread** and refuses to start
otherwise. On a 24-core host that is a 6 GiB floor, so a modest-looking `maxmemory: 512MB` fails
outright. Either leave `maxmemory` empty and let Dragonfly size itself from the machine, or set
`proactor_threads` to match the limit you want.

The readiness check is what surfaces this: the service starts, exits, and the check fails on the
run rather than a week later.

## Tests

`_trial/` holds a render-only suite: it builds the plan the unit expands into and asserts it,
without a host and without downloading anything. Fourteen cases cover the default install, the
two system accounts, an acknowledged open instance, TLS with replication, replication credentials
on a master, scheduled snapshots with retention, snapshots written to object storage, an upgrade
from a mirror on arm64, the teardown, and the five refusals.

```bash
make check    # soul-lint (destiny, wrapper service, wrapper scenario) + soul-trial run _trial
```

## Licence

Apache 2.0 — see [LICENSE](LICENSE).
