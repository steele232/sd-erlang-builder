# Workspace Monorepo for Scalable Distributed Erlang

## Goal: reviving SD Erlang and sustaining its momentum with largely-automated maintenance work

The full plan is in `2026_10_16_sd_erlang_coding_handoff_guide.md.md`. This repo
currently implements the guide's first step: **preserve and reproduce the
historical 19.3 reference, then run a tiny 3-node s_group demo on it.**

> ⚠️ The historical runtime is archival software (2017 code, Ubuntu 14.04, OpenSSL 1.0.1f).
> It runs only inside containers on an `--internal` podman network. Never expose it.

## Quick start (podman)

```bash
bin/sd-archive            # mirror release-project/otp, verify pinned SHAs, write git bundles
bin/sd-build-historical   # build the trusty builder + SD Erlang from the bundle, by SHA
bin/sd-demo               # start 3 nodes, run the s_group scenario, run the stock-OTP control
```

Then explore:

```bash
bin/sd-demo up            # (re)start the 3 SD nodes
bin/sd-demo status        # each node's s_groups and connections
bin/sd-demo scenario      # rerun the executable checks
bin/sd-demo shell gpu1    # hidden remote shell into a node (Ctrl-G q to leave)
bin/sd-demo down          # stop and clean up
```

Inside a shell, try for example:

```erlang
s_group:own_s_groups().
s_group:whereis_name(local_ai, worker_pool).
nodes().
```

## The demo

```text
            local_ai                 external_ai
   gpu1 ───────────────── gateway ───────────────── connector
 worker_pool                                       worker_pool
```

Static topology: `demo/config/sd_groups.config`. Each node runs in its own
container. `gateway` is in both groups, and each worker registers the **same
name** `worker_pool` in its own group. `demo/src/sd_demo_scenario.erl` then checks:

| Step | Property |
|---|---|
| overlapping static s_groups | each node sees only its own groups |
| no transitive connection | `gpu1` and `connector` stay disconnected even though both are connected to `gateway` |
| group-scoped names | `worker_pool` resolves to `gpu1` in `local_ai` and to `connector` in `external_ai`, and is absent from plain `global` |
| routing | `s_group:send/3` reaches the right worker |
| remote registration refused | `{no, cannot_register_in_remote_group}` |
| `add_nodes/2` / `remove_nodes/2` | membership and connections converge both ways |
| `new_s_group/2` / `delete_s_group/1` | group is created and removed; outsiders never see it |
| crash isolation and recovery | killing `connector` leaves `local_ai` working; the restarted node re-registers |

Safety checks ("this must never become visible") are observed over a window.
Liveness checks ("this must converge") poll until a deadline. Membership changes
in SD Erlang propagate asynchronously.

`bin/sd-demo control` runs the same three nodes on **stock OTP built from the SD
commit's exact parent**. There, `gpu1` and `connector` get meshed transitively,
which is the behavior s_groups remove. Observed result: SD `gpu1` sees
`['gateway@gateway.sd.lab']` during the whole safety window. Stock `gpu1` sees
`[gateway, connector]` about 200 ms after the gateway connects to both.

## Provenance

| What | Where |
|---|---|
| Pinned source SHAs + archaeology notes | `manifests/historical-sources.yml` |
| Bundle hashes | `manifests/SHA256SUMS` |
| Builder package lock (arm64) | `manifests/trusty-build-lock-arm64/` |
| Built image IDs | `manifests/*.image-id` |
| Patch inventory | `patchsets/s_group_v1.yml`, `patches/reference/` |
| Oracle status (QuickCheck / PropEr / TLA+) | `manifests/verification-status.yml` |

Notable findings:

* `19.3-rebased` (`0fdfcf28`) is **one commit**, "Add s_group functionality", on
  top of upstream `master` at `5da9e0ab` (`OTP_VERSION` = `20.0-rc0`), *not* on
  the `OTP-19.3` tag. `patches/reference/sd-19.3-s_group-commit.patch` is that exact
  commit. The guide's six-file diff against `OTP-19.3` is kept too, but it includes
  about 25 lines of unrelated upstream drift.
* The commit also touches `lib/kernel/src/Makefile` and the bootstrap
  `kernel.app`, in addition to Glasgow's six files.
* The published D3.3 `eqc_statem` model is not in any branch of the public mirror.
* The guide's Ubuntu 14.04 digest is a manifest list that includes `arm64v8`, so
  this build runs natively on Apple Silicon. The guide's matrix lists amd64 as the
  historical oracle; that variant has not been built yet.
* **Runtime finding:** in 19.3, `remove_nodes/2` disconnects *logically*.
  `s_group:disconnect_nodes/1` notifies `global` and the peer's s_group but never
  calls `erlang:disconnect_node/1`. A distribution link opened while a node was a
  member therefore stays up after removal, although the namespace separation is
  enforced. The demo reports this but does not assert it.
* **Runtime finding:** a restarted node can hand out a pid that compares *equal*
  to the old one. OTP 20's 2-bit node creation restarts at 1 under a fresh epmd.
  So the demo detects restarts by node uptime, not by comparing pids.
* Percept2 is left out of the build: it is RELEASE profiling tooling, not part of
  s_group.

## Not done yet (next milestones from the guide)

17.4 build · PropEr state-machine port · TLA+ model · TLS distribution ·
14-node topology · OTP 29.1.2 manual port · differential harness · Partisan control.
