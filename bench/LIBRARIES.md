# Libraries to test with SD Erlang

Compiled 2026-10-26 for the chat reference app (`bench/chat/SPEC.md`) and
track B of `NEXT_ROUNDS.md`. Versions and dates come from the Hex API on
that day.

The "on an SD member" column is a **prediction**. It comes from grepping
each package's published source for `global`, node discovery
(`nodes()` / `Node.list`, `monitor_nodes`, `nodeup`) and `pg`. Checking the
predictions is the first hands-on task (P0, below).

Two SD Erlang facts decide almost every prediction:
1. **On a member, `nodes()`, `net_kernel:monitor_nodes/1` and `pg` see
   group-mates only.** A library that discovers peers that way scopes itself
   to the node's groups, without any change. On a node in two groups (a
   gateway), the scope is the union of both groups.
2. **On a member, `global`'s registry is closed.** `register_name/2` returns
   `{no, the_node_is_not_free}` and `whereis_name/1` returns `undefined`. A
   library that names itself `{global, _}` fails on members unless it is
   adapted to `{via, s_group, {G, Name}}`.

## 1. Process groups, registries and distributed supervisors

Tier 1 libraries get tested in the chat app. Tier 2 libraries get a
conformance probe. Tier 3 is for reference only.

| tier | library | version (date) | what it is | discovery / naming in source | prediction on an SD member |
|---|---|---|---|---|---|
| 1 | **`pg`** (OTP kernel) | OTP 29.1.2 | process groups with scopes, strong eventual consistency; WhatsApp's `spg` work, upstreamed in OTP 23 | visible nodes | **scoped to the node's groups.** Like `s_group`, its views are not transitive (stock pg says so for nodes that aren't directly connected). This is the baseline |
| 1 | **`Group`** (`phoenixframework/group`, Chris McCord) | 0.3.1 (2026-10-11) | registry, process groups, lifecycle monitoring (`Group.monitor/2`) and **named subclusters**; sharded writes; anti-entropy; pluggable `replica_transport` | `Node.list()`, `nodeup`; no `global` | works, scoped to groups. Its named subclusters are a second partition *above* s_groups. Measure whether the two overlap or complement each other. Upstream CI covers OTP 26–28, so OTP 29 is untested there |
| 1 | **Phoenix.PubSub** (+ Presence) | 2.4.1 (2026-10-08) | pub/sub, with the pg adapter by default | `pg` | scoped to groups; a broadcast reaches group-mates only. The chat app's fan-out path |
| 1 | **Syn** (Ostinelli) | 3.4.2 (2026-06-22) | registry and groups with **scopes**: "nodes in the same scope synchronize data between themselves, and themselves only"; conflict resolution with no global lock | `nodes()`, `monitor_nodes` | works, scoped to groups. Scopes over s_groups map most closely to SD Erlang's concepts |
| 1 | **Horde** (Kraan) | 0.10.0 (2025-11-03) | delta-CRDT registry and DynamicSupervisor | `members: :auto` uses visible nodes; `global` only to unwrap a name | works, scoped to groups. CRDT gossip volume is a control-plane metric |
| 2 | **ProcessHub** (alfetahe) | 0.7.0 (2026-08-30) | process distribution and registry, consistent hashing, partition handling | `nodeup`; **its dependency `elector` uses `{global, elector_commission}`** | **likely breaks on members** in any mode that uses `elector`. Test it; the fix is an adapter or a free coordinator node |
| 2 | **DistributedSupervisor** | 0.5.5 (2025-05-01) | DynamicSupervisor spread with `pg` + libring | `pg`, `monitor_nodes` | works, scoped to groups |
| 2 | **Highlander** (Kraan) | 0.2.1 (2020-07-27) | one process per cluster | **`:global.register_name`** | **breaks on members.** A one-line `{via, s_group, ...}` change fixes it. Use it as the migration-guide example |
| 2 | **DurableServer** (`phoenixframework/durable_server`) | 0.1.6 (2026-10-13) | durable GenServers backed by object storage (the ElixirConf EU 2026 keynote) | built on `group ~> 0.2.0` and `ekv` | inherits Group's behaviour. Pinned to group 0.2, not 0.3 |
| 2 | **ekv** (McCord) | 0.4.8 (2026-10-02) | eventually consistent durable KV store with member replication | `pg`, `monitor_nodes` | scoped to groups. Candidate message store (spec, section 7) |
| 2 | **gproc** (Wiger) | 1.3.0 (2026-07-29) | extended local registry; global mode through `gproc_dist` (gen_leader) | own leader election | local mode unaffected. Global mode elects across visible nodes, so one leader per group mesh. Low priority |
| 3 | **Swarm** (bitwalker) | 3.4.0 (2019-01-16) | registry plus automatic distribution with libring | `monitor_nodes` | probably works, but it is unmaintained. Run a smoke test only |
| 3 | **`spg`** (max-au) | 1.1.1 (2019-10-28) | WhatsApp's Scalable Process Groups, the precursor of `pg` | | historical. `pg` replaces it |
| 3 | **SuperWorker** (ohhi.vn) | 0.11.0 (2026-10-11) | supervisor and background-job toolkit (groups, chains, partitions) | no node discovery found | **looks node-local.** Its docs show no cross-node features, so it is not a distribution library. Check with the authors before ruling it out |
| 3 | **lasp_pg** | 0.1.0 (2017) | process groups on Partisan | | stale. Partisan's own groups replace it |
| — | `global` (OTP) | | | | closed on members (by design) |
| — | **Riak Core** | | ownership ring, vnodes, handoff | | orthogonal; see handoff guide A5. Not in the first round |

Cluster formation, which isn't a group library but is needed:
- **libcluster 3.5.0** (2025-01-09): set `connect: {:s_group, :connect_node, []}`;
- **dns_cluster 0.3.1** (2026-10-01): dials with `Node.connect`. Wrap it, or
  it will try to dial every host.

### P0, the conformance probe (hands-on, about an hour per library)

1. On the SD Elixir image, start 4 nodes: g1 = {a, b, gw}, g2 = {gw, c}.
2. Run each library's quick-start on every node.
3. Record:
   - what `a` sees of `c`'s registrations and members (expected: nothing);
   - what `gw` sees (expected: both groups);
   - behaviour under `cut a b` / `heal a b`;
   - connection count before and after (no full mesh should appear).
4. Log each result as pass, scoped or breaks in `bench/results/p0.md`.

## 2. Getting past the single connection between two nodes

The problem: native distribution uses **one TCP connection per node pair**,
so a large or bursty stream delays everything else on it.

What OTP already does about this:
- **Since OTP 22**, large messages are split into fragments, so one
  gigabyte-sized message no longer blocks all other traffic. The common
  symptom of that was a missed net tick.
- **`+zdbbl`** (`dist_buf_busy_limit`) sets when senders are suspended.
- **`erlang:send_nosuspend/2,3`** lets a sender drop instead of block. Group
  uses it.

It's still one ordered byte stream per pair, so head-of-line blocking
remains. Ticks only matter on an idle link, but a suspended sender or a
heavily queued buffer still delays latency-critical control messages.

| tier | library | version (date) | approach | layer, relative to SD Erlang | notes |
|---|---|---|---|---|---|
| 1 | **gen_rpc, EMQX's fork** (`github.com/emqx/gen_rpc`) | tag 4.0.0, pushed 2026-09-23; **not on Hex** (git dependency) | own TCP/TLS sockets, **N channels per node pair** (`{Node, Key}` hashes to a channel); a mailbox per node | **beside** disterl: it bypasses `s_group` visibility | the production precedent: EMQX routes cross-node traffic over it, with `rpc.tcp_client_num` (default 10, range 1–256). Its README calls the repo "temporarily maintained for legacy support". Only restricting it to group-mates (`s_group:own_nodes/0`) keeps the connection count bounded. Upstream `gen_rpc` 2.1.0 (2016) and `mc_gen_rpc` 3.0.1 (2022) are older forks |
| 1 | **Partisan** (`lasp-lang/partisan`) | 6.3.1 (2026-10-15), OTP 27+ (tested 27/28/29) | a whole replacement distribution layer: **named channels with configurable parallelism**, monotonic channels, HyParView / client-server / static overlays, `partisan_gen_server` | **replaces** disterl for application traffic | the comparison's column B, and track C's "Partisan channels for bulk data" |
| 1 | **erlang_quic `quic_dist`** (benoitc) | `quic` 2.1.3 (2026-10-26) | **disterl over QUIC** (`-proto_dist quic`): multiple streams per connection, which removes head-of-line blocking at the transport; TLS 1.3, 0-RTT reconnect, connection migration; OTP 26+ | **below** disterl, **under** `s_group` | probably the best fit for SD Erlang: native semantics and group visibility stay as they are, and only the carrier changes. Needs a check that the kernel patches don't assume `inet_tcp_dist`. Young, pure-Erlang project |
| 2 | **Group's sideband `replica_transport`** | `Group` 0.3.1 | pluggable transport for Group's replication (`Group.Transport` plus `Outbox` batching). Only `DistErl` ships; a TCP adapter exists in its tests | beside disterl, for Group's data only; membership stays on disterl | this matches what you remember from McCord's keynote: control on disterl, data on a separate channel. **No public adapter over a Phoenix endpoint was found.** Writing one, a WebSocket or TCP adapter, is a candidate hands-on task |
| 2 | **quicer** (EMQX, msquic NIF) | 0.4.12 (2026-10-06) | a QUIC library, not a dist carrier | beside | the transport for a custom sideband (Group or the app's own) |
| 2 | **Manifold** (Discord) | 1.7.0 (2026-07-07) | **fewer sends**: one send per remote node, fan-out on arrival; Discord saw packets per second halve | on disterl | not more connections, but it relieves the same pipe. Essential for large chat-group fan-out |
| 2 | **ZenMonitor** (Discord) | 2.1.0 (2023-07-12) | batched remote monitoring | on disterl | cuts control-plane traffic from many cross-node monitors (session monitors) |
| 2 | **aten** (RabbitMQ) | 0.6.0 (2024-01-03) | a failure detector separate from `net_ticktime` | its own probes | addresses "the pipe was clogged, so the node looked dead" directly. Ra uses it |
| 3 | `-proto_dist` alternative carriers (`inet_tls_dist`, custom `gen_tcp_dist`) | OTP | one connection per pair, different carrier | below `s_group` | TLS is on the MVP list anyway; it doesn't help with head-of-line blocking |

How these compose with SD Erlang, and what to measure:
- **Below `s_group`** (quic_dist): the topology bound and native semantics
  are kept automatically. Measure head-of-line p99 and CPU per message.
- **Beside it** (gen_rpc, Group's sideband, quicer): it scales throughput,
  but the extra sockets live outside `s_group`. The application must open
  them only to group-mates, or SD Erlang's connection-count advantage is lost
  quietly. Count sockets with `ss`, not just `nodes(connected)`.
- **Instead of it** (Partisan): this is the comparison, not a composition,
  except in track C.

## 3. Suggested order

1. P0 probes for pg, Group, Syn, Horde and Phoenix.PubSub. These are the
   chat app's candidates.
2. Highlander and ProcessHub, for the expected breakages. Write each fix into
   `docs/MIGRATION.md`.
3. quic_dist on the SD image: the one-line `-proto_dist quic` experiment.
4. gen_rpc (EMQX fork), restricted to group-mates. Then run the head-of-line
   test from `NEXT_ROUNDS.md` B on disterl, quic_dist, gen_rpc and Partisan.

## Sources

- Hex package API (`hex.pm/api/packages/<name>`), 2026-10-26: versions,
  dates and dependencies.
- Source greps of each Hex tarball (`repo.hex.pm/tarballs`).
- READMEs: phoenixframework/group, lasp-lang/partisan, emqx/gen_rpc,
  benoitc/erlang_quic (`quic_dist` docs).
- Syn v3 announcement (erlang-questions, 2021-10); OTP 22 distribution
  fragmentation (OTP 22 highlights; rabbitmq/ra#135); EMQX configuration
  manual (`rpc.tcp_client_num`); Discord's Manifold write-up.
