# Migrating an OTP application to SD Erlang

This guide is for applications written for stock Erlang/OTP (or Elixir) that
want to run on the SD Erlang kernel (`docs/USAGE.md`). It also lists what
changes for code written for RELEASE's SD Erlang 19.3.

## Step 0: nothing changes until a node joins a group

A node with no `s_groups` configuration that never calls `new_s_group` or
`add_nodes` is a **free node**, and it behaves like stock OTP 29.1.2. That
includes `global`, `nodes()`, `pg`, `global_group`, partition prevention
and distribution. The gate compares free nodes against stock OTP on a fixed
corpus of operation sequences (layer L5). So swapping the runtime is safe
on its own, and grouping can be adopted one node set at a time.

## Step 1: decide the groups

Group by who needs to talk to whom, not by machine. Typical shapes:
- per-tier groups, such as `web`, `db` and `cache`, with a few gateway
  nodes in two groups;
- per-shard groups plus an overlapping coordination group;
- a hierarchy, such as racks inside regions.

A node in groups g1 and g2 is the bridge between them. Traffic between g1
and g2 goes through such nodes, or over explicit hidden connections. It
doesn't go over a full mesh.

## Step 2: replace `global` names with group names

On a member, `global`'s registry is closed: `register_name/2` returns
`{no, the_node_is_not_free}`, `whereis_name/1` returns `undefined`, and
`send/2` exits `badarg`. Every `{global, Name}` that a member uses must
become a group name.

| stock | SD Erlang |
|---|---|
| `{global, Name}` in `gen_server:start_link/4`, `gen_statem`, `supervisor` ... | `{via, s_group, {Group, Name}}` |
| `global:register_name(Name, Pid)` | `s_group:register_name(Group, Name, Pid)` |
| `global:whereis_name(Name)` | `s_group:whereis_name(Group, Name)` |
| `global:send(Name, Msg)` | `s_group:send(Group, Name, Msg)` |
| `global:registered_names()` | `s_group:registered_names({s_group, Group})` |
| Elixir `name: {:global, name}` | `name: {:via, :s_group, {group, name}}` |

The via tuple is the least intrusive change. Code that already takes a
`name` option needs only a configuration change:

```erlang
%% before
{ok, _} = my_server:start_link(#{name => {global, orders}}).
%% after
{ok, _} = my_server:start_link(#{name => {via, s_group, {shop, orders}}}).
```

A name is resolved only by the group's members. A caller outside the
group gets `undefined` (and `gen_server:call` exits `noproc`). Callers must
be members, forward through one, or look the name up on a member with
`s_group:whereis_name(MemberNode, Group, Name)`.

## Step 3: check what assumes a full mesh

On a member, `nodes()` lists **its group-mates only**. Links to other nodes
exist but are hidden. Review code that:
- iterates `nodes()` (broadcasts, `rpc:multicall/4` with the default node
  list, `global:trans/2` default lock nodes), which now covers the groups
  only. That is usually what you want; use `s_group:own_nodes(G)` to be
  explicit;
- relies on `net_kernel:monitor_nodes/1`, which sees visible connections,
  meaning group-mates. `s_group:monitor_nodes(true)` reports group-mates
  explicitly;
- uses `pg`, Phoenix.PubSub (pg adapter), Horde, Swarm or `:syn`. These
  discover peers from visible connections, so their scope becomes the
  node's groups. Check whether a group-crossing broadcast is needed;
- uses `global_group`: the two can't be combined. A node configured with
  both `global_groups` and `s_groups` refuses to boot. Move `global_groups`
  definitions to `s_groups`. The shapes are close: `{G, normal, Nodes}`.

## Step 4: cluster management

The kernel doesn't re-dial a lost link, just as stock OTP doesn't. Use your
cluster manager, but connect through `s_group:connect_node/1`, which dials
only nodes this node shares a group with and returns `ignored` for the rest.
That keeps a manager that knows every host from rebuilding a full mesh. For
libcluster, set `connect: {:s_group, :connect_node, []}` (`docs/USAGE.md`).
Initial group formation uses static `s_groups` config or `new_s_group/2`;
both dial the members themselves.

## Step 5: persistence and restarts

For dynamic groups, start nodes with `-rsconfig` and restart with
`-config <node>` (`docs/USAGE.md`). The record is a claim that the current
members resolve. A node that was removed or whose group was deleted while it
was down accepts that on return.

## Step 6: partitions

Inside a group, a partition splits the namespace: each side keeps working
with the members it can reach. At the heal, the sides merge. A name
registered on both sides keeps one process, and the other is killed, as in
`global`. If killing the loser is wrong for a name, register it from a
single owner, or make the process robust to being killed and restarted by
its supervisor. Unregistrations made during a partition can come back at the
heal (the merge is a union).

## Coming from SD Erlang 19.3

The API and the documented semantics are kept; `spec/deviations.yml` lists
every difference with its reason. The ones visible to applications:

| | 19.3 | this port |
|---|---|---|
| via module | none | `{via, s_group, {G, Name}}` (additive) |
| `connect_node/1` | none | dials group-mates only (RC1) |
| a link made before two nodes share a group | stays hidden (O3) | becomes visible (re-dialled, D-1) |
| partition inside a group | permanent divergence possible | per-group logical partition prevention, merge at heal (POP1) |
| two names for one pid after a merge | possible (U1) | one name per pid |
| `-rsconfig` | skips changes within a second (RS1); the record is trusted on restart | every change written atomically; the record is a claim (MR1); extra keys `s_group_state`, `s_group_tombstones` (MS1) |
| conflicting static definitions | union | refuse to start (own group) / drop (remote group) (DN1, DN2) |
| `global:register_name/2` failing on a free node | `{no, name_or_pid_already_registered}` | `no`, as stock OTP (F1) |
| anti-entropy | none | periodic repair (AE1) |
| `*_external` functions | separate cleanup semantics | aliases of the normal functions |

19.3 tooling that reads `-rsconfig` files still finds `s_groups` in 19.3's
format. It must ignore the two new keys.
