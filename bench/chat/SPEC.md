# SD Chat: specification (v0, draft)

A WhatsApp-style mobile messaging service. It is the reference application
for SD Erlang. It is meant to be useful on its own, and it is the workload for
the three-way comparison in `NEXT_ROUNDS.md` track B:
- stock OTP with libcluster and pg;
- Partisan;
- SD Erlang.

Drafted 2026-10-26. Status: **draft. The open questions in section 12 must be
answered before M1.**

## 1. Why this app

- **Proven on the BEAM.** WhatsApp ran on Erlang (ejabberd lineage), and
  EMQX is an Erlang MQTT broker at a similar scale.
- **Benchmarks are intuitive.** Messages sent, delivered and read, latency,
  and connected devices all have obvious meanings.
- **It plays to SD Erlang's strengths.** It is global, so one group per
  region gives a sparse topology. It is liveness-critical: sessions,
  presence and delivery must survive node failure and partitions. It also
  has a natural role for representative nodes: gateways, metrics roll-up,
  admin ingress.
- **It needs exactly the two things SD Erlang lacks** (`bench/LIBRARIES.md`):
  - a scalable process-group and directory layer, for millions of sessions;
  - a way past the single connection between two nodes, for group fan-out
    and bulk traffic.

## 2. Scope

**v0 product:**
1. **Accounts and devices.** A user has 1–4 devices. Sign-up uses demo
   tokens: no phone verification.
2. **1:1 chats and chat-groups of up to 256 members.** These are called
   *chat-groups* to avoid confusion with s_groups.
3. **Text messages up to 64 KiB.** Media is out-of-band: upload to object
   storage, then send a message carrying a reference (section 7).
4. **Receipts:** *sent* (the server accepted it), *delivered* (on a
   recipient device) and *read*. In a chat-group, the receipts are
   aggregated per message.
5. **Offline delivery.** Messages are stored and forwarded to each device on
   reconnect, kept for 30 days.
6. **Presence:** online, last seen, typing.
7. **Push notification** for offline devices, through a stub APNs/FCM
   service (a counter, no real push).

**Non-goals for v0:**
- end-to-end encryption (a Signal-protocol layer is a later, separate
  track; the server design must not prevent it, so it treats bodies as
  opaque);
- voice and video, statuses or stories, and phone-number verification;
- spam and abuse handling, and compliance;
- multi-tenant use.

## 3. Domain model

| entity | key | notes |
|---|---|---|
| user | `user_id` (UUIDv7) | has a **home region** (section 6.3) |
| device | `{user_id, device_id}` | one live **session** process while connected |
| conversation | `conv_id` | `direct` (two users) or `chat_group` (members, admins) |
| message | `{conv_id, seq}` | `client_msg_id` (UUIDv7, for deduplication), sender, body (opaque binary), `sent_at` |
| receipt | `{conv_id, seq, device}` | delivered or read, monotonic |

## 4. Delivery semantics

- **Ordering:** total order *per conversation*. One **sequencer** process per
  active conversation assigns `seq`. There is no order across conversations.
- **At-least-once on the wire, exactly-once to the user.**
  - The client retries until it gets *sent*, and the server deduplicates on
    `{sender_device, client_msg_id}`.
  - Devices acknowledge by `seq`, and redelivery after a reconnect starts
    from the last acknowledged `seq`.
- **Durability:** *sent* is acknowledged only after the message is in the
  conversation's store (section 7). A *sent* message must never be lost,
  whatever node fails. This is checked in every failure test (section 10).
- **Receipts** are monotonic (`read` implies `delivered`) and best-effort
  ordered.
- **Presence** is eventually consistent and never blocks messaging.

## 5. Client protocol

Phase 1 uses **WebSocket + JSON (Phoenix Channels)**. Phase 2 adds an
**MQTT 5** front end on the same core: the "EMQ clone". Facebook Messenger
used MQTT on mobile, and existing load tools such as `emqtt-bench` and MQTT
client libraries then work unchanged.

The core is protocol-agnostic: a front end turns frames into the core
operations below.

| operation | direction | payload |
|---|---|---|
| `hello` | C→S | token, device, last acked `seq` per conversation |
| `send` | C→S | `conv_id`, `client_msg_id`, body |
| `sent` | S→C | `client_msg_id`, `seq`, `sent_at` |
| `msg` | S→C | the message |
| `ack` | C→S | `conv_id`, `seq` (delivered) |
| `read` | C→S | `conv_id`, `seq` |
| `receipt` | S→C | `conv_id`, `seq`, device or user, state |
| `presence` / `typing` | both | user, state |

## 6. Architecture on SD Erlang

### 6.1 Node roles

| role | holds | count |
|---|---|---|
| **edge** | client connections, one session process per device | most nodes; scales with connected devices |
| **core** | conversation sequencers, store writers, offline queues | scales with message rate |
| **gateway** | cross-region routing; representative roles (6.4) | 2–3 per region |

### 6.2 s_groups

- One group per region, such as `r_us_east`, `r_eu_west` and `r_ap_south`,
  containing that region's edge, core and gateway nodes.
- Group **`wan`** contains every region's gateways, and nothing else.
- Optional, for large regions: one group per availability zone inside the
  region (`r_eu_west_az1`), with the core nodes in both the zone group and
  the region group.
- **Connection budget:**
  - a non-gateway node connects only to its region's nodes;
  - a gateway also connects to the other regions' gateways;
  - no node connects to the whole world.
- Inside a region, all OTP idioms work natively: PIDs, links, monitors,
  `gen_server:call`.

### 6.3 Finding things

| question | answer | why not s_group names |
|---|---|---|
| where is device D's session? | the **Directory** (pg, Group, Syn or Horde: the library under test) in the device's current region | sessions register and unregister at connection churn rate. A `s_group:register_name` takes a group lock and multicasts, like `global`. That is right for a few singletons and wrong for millions of sessions. **Hypothesis H1: measure it** |
| where is user U's home region? | deterministic: a hash of `user_id` maps to a region at sign-up, stored with the account | |
| where is conversation C's sequencer? | the **Placement** (libring / Horde / ProcessHub / DistributedSupervisor) over the core nodes of the conversation's home region (the creator's) | |
| who are the gateways? | `s_group` names per region: `{via, s_group, {r_X, gateway_1}}` and so on, plus the attribute `gateway` (`s_group:choose_nodes/1`) | few, long-lived names: what s_group names are for |

Directory, Placement, Transport and Store are **behaviours** with one
module per library. The library matrix in `bench/LIBRARIES.md` swaps
modules, not application code.

### 6.4 Representatives (one elected holder per region, per concern)

Each role is an `s_group` name with standby candidates. When the holder
dies, M1 cleanup frees the name and a standby takes it. During a partition,
each side elects its own; at the heal, one survives:

- `gateway_N`: routes `wan` traffic in and out of the region;
- `metrics_rep`: rolls up the region's counters and histograms;
- `control_rep`: applies drain, feature-flag and rebalance commands to the
  region;
- `admin_ingress`: an HTTP API for the rest of the system. Non-Erlang
  services talk to SD Chat only here, never over disterl.

### 6.5 Message path

1. The device's edge session receives `send`.
2. It forwards to the conversation's sequencer, in-region, or through the
   local gateway, `wan`, and the remote gateway.
3. The sequencer assigns `seq` and writes to the store, then answers `sent`.
4. It fans out to each recipient device: in-region through the Directory,
   other regions through gateways, with **one batch per remote region**
   (Manifold-style).
5. Online sessions deliver. Offline devices get a queue entry and a push
   stub.

## 7. Storage (pluggable, Store behaviour)

The v0 default is **PostgreSQL, one per region**, holding conversations,
messages and offline queues for conversations homed there. The reason is
that storage traffic then stays off Erlang distribution, so the comparison
measures the distribution layers, not three different databases.

BEAM-native alternatives, for later rounds:
- `ekv` (McCord);
- Khepri or Ra;
- Mria (EMQX's Mnesia replication).

Media uses a MinIO container (S3 API), and a message carries only the
object key.

## 8. Mobile client

- **v0: a headless client** (Elixir) speaking the section-5 protocol. It is
  the load generator and the correctness checker: every *sent* message must
  eventually reach every recipient device exactly once, in `seq` order.
- **v1: a minimal reference app** with sign-in, a chat list, a chat view,
  receipts and push. It is a hands-on track. The framework is open (12, Q4).

## 9. Benchmarks

**Topology:**
- 3 simulated regions, each a podman network;
- inter-region delay with `tc netem` on the gateways: 40, 80 and 140 ms
  one-way;
- small: 3 regions × (4 edge + 2 core + 2 gateway) = 24 nodes, about what
  one Mac can run;
- large: phase 4, cloud VMs, deferred.

**Workloads:**

| id | workload | stresses |
|---|---|---|
| W1 | steady 1:1 chat, Poisson senders | baseline latency and throughput |
| W2 | chat-group fan-out (256 members, spread across regions) | fan-out, Manifold, cross-region batching |
| W3 | presence and typing churn | control-plane volume, Directory |
| W4 | reconnect storm (an edge node dies; its devices reconnect with jitter) | Directory churn (H1), offline replay |
| W5 | cross-region conversations only | gateways, `wan` |
| W6 | W1 plus a bulk stream on the same node pairs (history sync, large payloads) | **head-of-line blocking**; disterl vs quic_dist vs gen_rpc vs Partisan channels |

**Failure schedule** (reused from `bin/sd-faults`):
- edge crash;
- core crash during a sequencer write;
- gateway crash (representative failover);
- region cut from `wan` (intra-region chat must continue);
- link flap;
- whole-region cold start.

**Metrics:**
- the table in `NEXT_ROUNDS.md` B;
- end-to-end *send → delivered* latency p50/p95/p99, intra- and
  cross-region;
- time to deliver after a heal;
- duplicate and lost counts (must be 0 lost);
- connected devices and memory per node;
- sockets per node (`ss`, not only `nodes(connected)`).

**Implementations:**
- **A:** stock OTP 29.1.2 with libcluster and pg/Phoenix.PubSub, one full
  mesh, with an equivalent gateway design implemented over the mesh;
- **B:** Partisan 6.3, static or HyParView overlay, `partisan_gen_server`;
- **C:** SD Erlang (this spec).

A is written first and B and C are ports of it, so that "LOC changed"
means something.

## 10. Acceptance (per milestone)

- The headless clients' checker reports **0 lost *sent* messages** and **0
  out-of-order deliveries** under every failure in section 9.
- Under a region cut, intra-region W1 p99 stays within 2× its no-fault value.
- Representative failover completes within 1.25 × `net_ticktime` (the
  worst-case nodedown detection) plus one election retry.

## 11. Milestones

| # | output |
|---|---|
| M0 | single node: core operations, Phoenix Channels front end, headless client and checker, Postgres store |
| M1 | one region on SD Erlang (one s_group), Directory = pg; W1, W4 |
| M2 | three regions plus `wan` gateways and representatives; W2, W5 |
| M3 | failure schedule and acceptance (section 10) |
| M4 | library matrix: Directory × {pg, Group, Syn, Horde}; Transport × {disterl, quic_dist, gen_rpc}; W3, W4, W6 |
| M5 | implementation A (written before C's code freezes) and the B port; the three-way tables |
| M6 | MQTT 5 front end (the EMQ clone); `emqtt-bench` runs |
| M7 | mobile reference app |

## 12. Open questions (decide before M1)

| # | question | recommendation |
|---|---|---|
| Q1 | Phoenix Channels first or MQTT first? | Channels first: fastest hands-on path in Elixir. MQTT in M6 |
| Q2 | Elixir or Erlang for the app? | Elixir; the SD image exists (`localhost/sd-elixir:1.20.4-otp29.1.2-sd`) |
| Q3 | Postgres or a BEAM-native store in v0? | Postgres (section 7, the reason given there) |
| Q4 | mobile framework for M7 | your choice: Flutter, React Native or native. Only the section-5 protocol is fixed |
| Q5 | chat-group home region: the creator's, or rebalanced to where most members are? | the creator's in v0; measure W2 before changing it |
| Q6 | does SD Chat need any new SD Erlang API (for example membership hooks)? | no for v0. Record frictions in `notes/ergonomics.md`, and changes go through `spec/proposals/` |
