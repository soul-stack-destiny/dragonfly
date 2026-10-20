# Notes for editing this repo

This is a Soul Stack destiny — a single, reusable unit that sets up Dragonfly on one host and can
be tested on its own. Keep it that way: it installs the binary, writes its flagfile / ACL / TLS /
environment file / systemd unit, tunes the host, prunes old snapshots and starts the service. It
does not do failover, cluster membership or rolling upgrades — that's up to whatever drives it.

Dragonfly speaks the Redis protocol, and this unit deliberately mirrors the `redis` one where it
can: the same two system accounts (`default` for applications, `default_admin` for the operator),
the same ACL file shape with sha256 hashes, the same `ensure`/`purge_data` lifecycle, the same
host-tuning extras. Where it diverges, it is because Dragonfly differs — flags instead of a config
file, one port for TLS and plaintext, no sentinel daemon, built-in metrics.

## Ground rules

- **English only** in code, comments, YAML, tests and docs.
- **No secrets in the repo.** Passwords are passed in and written as sha256 hashes in the ACL
  file, plaintext only into a 0600 root-only environment file. TLS material is read from Vault by
  path — the unit gets paths, not the secrets.
- **Comments are few and short.** One line on what a step does when its name does not say it;
  the reasons behind the design live in this file and the README, not in the code.
- **This unit sees only its own input** plus this host's own facts (its IP, its architecture). It
  doesn't know about other hosts. That's what makes it reusable and testable on its own.

## The pieces

- **`destiny.yml`** — the input contract (each field's type/pattern/default) and the cross-field
  `validate:` rules. There is no top-level `version:` field (the version is the git ref);
  `version` inside the input is the Dragonfly release to install.
- **`vars.yml`** — fixed values used across the tasks (service names, derived paths, the switches
  the tasks and templates branch on, file modes). Not overridable from the outside.
- **`tasks/`** — `main.yml` picks install or teardown; `present.yml` includes
  `install/account/service/backup/extras` in order; `remove.yml` is the teardown.
- **`templates/`** — the rendered files (`.tmpl`), read with `.input.<field>` and `.vars.<name>`.
- **`_trial/`** — the render-only test suite (see Testing).

## Dragonfly behaviours this unit is built around

All of these were confirmed against a running 1.39.0 and then checked against the sources at that
tag; the file and line references below are from there. The first four fail quietly if ignored.

Re-run against the 2.0.2 release binary with the rendered flagfile, ACL file and environment file:
`PING` without `AUTH` → `NOAUTH`; `default` → `NOPERM` on `CONFIG SET`; the console answers
`/metrics` over HTTP/1.1 on loopback only (an HTTP/1.0 request without `Host` is read as a Redis
command); an
unknown `DFLY_` name aborts; a node started as a master replicates with its own
`masteruser`/`masterauth` after a bare `REPLICAOF`, under a user holding only
`-@all +replconf +ping +dfly`. One difference: a comment line still voids the ACL file
(`Error materializing acl file`, `default_admin` gone), but `default` then answers `NOAUTH` rather
than open, because the password in the environment file applies. An unknown permission voids it
the same way (`Unrecognized parameter +PSYNC`, `+@REPLICATION`): Dragonfly has neither.

1. **A missing `default` in the ACL file is filled in with an OPEN account.** `LoadToRegistryFromFile`
   (`src/server/acl/acl_family.cc`) ends with `if (!registry.contains("default")) { … Update(registry_->DefaultUserUpdateRequest() …) }`,
   and that request is literally nopass + `+@all` + `~*` + all channels (`user_registry.cc`). It
   does not read `requirepass`, which is why no password set elsewhere closes that account. The
   unit therefore always writes `default` into the file. (The file does win on *permissions*: a
   restricted `default` in the file stays restricted with the environment variable set, which is
   what the two-account split relies on.)
2. **ANY failure to load the file falls back to that same open registry.** `AclFamily::Init` is
   `if (!acl_file.empty() && Load()) return;` followed by `registry_->Init(…)` — so an unreadable
   file, an EMPTY file, a line the tokenizer rejects and a line `ParseAclSetUser` rejects all take
   the identical path: one `LOG(WARNING)`, service starts, `default` open. A `#` comment is one
   such line, because the hash marker is a password hash. **Never put comments in
   `users.acl.tmpl`**; blank lines are fine. Hence also the `validate:` rules refusing a
   caller-declared `default` or admin name, and the file only being written when there is a
   password to put in it.
3. **The HTTP console on the data port needs no authentication**, even when the port itself
   demands a password. So `--primary_port_http_enabled` defaults to false here and metrics come
   from the console port, which binds loopback.
4. **TLS needs an authentication method at startup, and an ACL file is not one.**
   `ValidateServerTlsFlags` (`src/server/server_family.cc`) sets `has_auth` from exactly two
   things — a non-empty password, or a non-empty `tls_ca_cert_file`/`tls_ca_cert_dir` — and its
   caller does `exit(1)` when neither is there. The registry is not consulted at all. That is why
   the password also goes into the environment file, and why there is a `validate:` rule for it.
   (Only the `_file` form is exposed here; `tls_ca_cert_dir` would satisfy the same gate and is
   reachable through `extra_flags` if anyone needs a directory of CAs.)

Two more about snapshots, both confirmed the same way:

- **`--dir` is a location, not a path**, and it is used for LOADING as well as writing. Pointing
  it at `s3://…` makes the store a startup dependency: if the bucket cannot be listed, Dragonfly
  logs `Failed list objects in S3 bucket` and — `server_family.cc`, right after that line —
  `exit(1)`. Fail-closed, and the readiness check turns it into a failed run. Do not "improve"
  this into a warning.
- **S3 credentials have no flags.** They come from the environment (`AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`) or from the instance role with `--s3_ec2_metadata`. Only
  the `DFLY_` prefix is policed, so the AWS names pass through the same environment file — the
  log line `aws: loaded credentials; provider=environment` is how you confirm they arrived.

Two more, less dangerous but easy to trip over:

- **Environment variables are `DFLY_<flag>`, spelled exactly as the flag.** `DFLY_requirepass`
  works; `DFLY_REQUIREPASS` and `DFLY_PASSWORD` make the process abort on startup with "unknown
  environment variable" — `dfly_main.cc` strips the `DFLY_` prefix, looks the rest up in the flag
  registry and `LOG(FATAL)`s on a miss, rather than ignoring it. (Dragonfly's own `--requirepass`
  help text names `DFLY_PASSWORD`; that is wrong in 1.39.0.) Only that prefix is policed, which is
  why the AWS variables pass through untouched.
- **A flag in the flagfile BEATS the matching `DFLY_` variable.** The same loop skips any flag
  `WasPresentOnCommandLine`, and flagfile contents count as the command line. So `extra_env` can
  only set flags the unit does not already render — it cannot override one of them.
- **`maxmemory` has a floor of 256 MiB per io thread**: `RunEngine` refuses when
  `maxmemory > 0 && maxmemory < pool->size() * 256_MB` and exits rather than clamping. A small
  limit needs a matching `proactor_threads`; leaving it empty (the default here) skips the check
  entirely.

## Rules to respect when editing

- **Keep a register and the task that reacts to it in the same file.** A `register:` used by an
  `onchanges:` restart must be declared in the same task file — that's why the restart sits in
  `service.yml` next to every render it reacts to.
- **Include conditions must be simple.** A conditional `include:` may only test `input.` or
  `vars.`. When false the whole included file is dropped from the plan — that is how `ensure` and
  the snapshot-retention group work, and the trial suite asserts the absence.
- **Everything must be idempotent** — safe to re-apply. Any imperative step (the teardown's
  `daemon-reload`) is guarded so it only runs when something actually changed.
- **Flagfile order matters.** Dragonfly takes the LAST occurrence of a repeated flag, so the
  `extra_flags` passthrough is rendered after everything else, on purpose.
- **Watch systemd's own escaping in `ExecStart`.** Backslash-escaped shell grouping (`\(`) is
  eaten by systemd before the shell sees it; the snapshot prune uses two plain commands instead.
  `systemd-analyze verify` on the rendered unit catches this class.

## Lifecycle & removal

`ensure` (`present`|`absent`) selects install or teardown. `remove.yml` reverses the install:
stop/disable the timer and the service → remove the units (and daemon-reload) → remove the binary,
environment file, flagfile, ACL file and TLS material → host tuning → the account. Every step is a
safe no-op when the target is already gone.

`purge_data` (default false) guards the destructive part: with it off, `ensure: absent` keeps the
snapshots and logs so a re-install resumes the same dataset; with it on, both directories are
deleted. The `disable-thp` unit is deliberately left behind — it is not Dragonfly's, and other
services on the host may rely on it.

## Testing

`_trial/` is a render-only suite (no Docker). Run it with the `soul-trial` tool:

```
soul-trial run _trial
```

Cases live in `_trial/scenario/apply/tests/<case>/`: `render-defaults`, `admin-account`,
`open-instance`, `tls-replica`, `master-credentials`, `snapshot-retention`, `snapshot-to-s3`,
`version-upgrade-from-mirror`, `remove-purge`, and the five refusals — `password-required`,
`default-user-reserved`, `admin-user-reserved`, `tls-needs-authentication`,
`s3-retention-refused`.

Adding a case:

- Each case has `name`, `fixtures`, and either `assert` or `expect_render_error` (a substring of
  the message a `validate:` rule produces).
- Use `assert.task_present` / `task_absent` with `params_subset` (a partial match on a task's
  params). `task_present` must match exactly one task, so disambiguate a repeated module by a
  distinct `path` or `name`. `<present>` just checks a key exists and is a non-empty string.
- `render_context` in an assertion is compared **in full**, not as a subset. `tls-replica`,
  `master-credentials` and `snapshot-to-s3` (the flagfile) and `admin-account` (the ACL file) pin
  it, so adding an input field means updating all four blocks, and a new `vars` key that a
  template reads means updating the three flagfile blocks. They are also the only place the suite can see that a value reaches a template at
  all, since it never executes one.
- `fixtures.soulprint` provides the host facts the unit reads: `os.arch` (which release artifact)
  and `network.primary_ip` (the bind address).
- `fixtures.vault` provides the TLS material, so a TLS case stays hermetic.
- `_trial/scenario/apply/main.yml` mirrors the input contract with the same defaults. A new input
  field has to be added there too, or cases drift from what the unit actually receives.
- The repo directory must be named `dragonfly` for the suite to find the destiny (clone it as
  `dragonfly`).

The suite never executes a `.tmpl`, so it cannot catch a broken config file. When you change a
template, render it and start the real binary against the output, then assert an **effect** — the
bind address, `PING` refused without `AUTH`, the console reachable, plaintext refused with TLS on.
"The process is up" is true even when the configuration was ignored entirely.

There is no released `soul-trial` binary yet; it is built from the
[soul-stack](https://github.com/souls-guild/soul-stack) core, which is what
`.github/workflows/trial.yml` does on every push: build `soul-trial` and `soul-lint` from the
core, validate the manifests, run the suite.

## What not to do

- Don't add a `.serena/project.yml` or activate Serena here.
- Don't add a top-level `version:` field.
- Don't write `default` into the ACL file as anything other than an enabled user with a password
  hash, and don't let a caller declare it or the admin name (see the behaviours above).
- Don't put comment lines in the ACL file — they void it.
- Don't give the administrative account narrowed permissions (`vars.admin_perms`) — an admin with
  a partial set is a contradiction. Narrow `default_perms` instead, or add a third user.
- Don't put a secret in the flagfile or the systemd unit — both are readable beyond root. Secrets
  go in the environment file (0600 root) or the ACL file as a hash (0640).
- Don't turn the data-port HTTP console on by default, and don't bind the console port to
  anything but loopback by default.
- Don't add a Sentinel daemon here — Dragonfly ships none. Sentinel comes from the `redis` unit
  with its data plane switched off.
- Don't add a Prometheus exporter — Dragonfly serves its own metrics.
