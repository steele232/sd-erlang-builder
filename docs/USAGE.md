# SD Erlang on OTP 29.1.2: usage

SD Erlang adds **s_groups** to the Erlang kernel: named, possibly
overlapping groups of nodes. Inside a group, connections are transitive and
there is a group-wide name registry. Across groups, connections are not
transitive, so a large cluster does not become one full mesh. This
distribution is the RELEASE project's SD Erlang (19.3), ported to OTP 29.1.2
as a set of kernel patches (`patches/otp29/`). Design and history:
`port/KERNEL_PORT.md`.

## Getting it

| form | how | result |
|---|---|---|
| container image | `podman load -i sd-erlang-29.1.2-sd-<ver>.oci.tar` (from the release), or `bin/sd-build-port` | `localhost/sd-erlang:29.1.2-sd-kernel` (official `erlang:29.1.2` + patched kernel) |
| from source on a host | `bin/sd-host-build PREFIX` | official `otp_src_29.1.2.tar.gz` (SHA-256 checked) + `patch -p1`, configured, built and installed into `PREFIX`; `PREFIX/lib/erlang/SD_PATCHES` lists the patches |
| from source by hand | `tar xzf otp_src_29.1.2.tar.gz && cd otp_src_29.1.2 && for p in .../patches/otp29/*.patch; do patch -p1 < $p; done`, then the usual `./configure && make && make install` | same |
| Elixir | `bin/sd-build-elixir` | `localhost/sd-elixir:1.20.4-otp29.1.2-sd` (Elixir 1.20.4 built from source on the SD runtime) |
| a newer OTP | `bin/sd-port-release-check OTP-29.x` or `master` | builds stock OTP at that commit, applies the series, runs the full gate |

Only `lib/kernel` changes: `global_group.erl`, `global.erl`, `kernel.erl`,
`kernel.app.src` and the new `s_group.erl`. Nothing else in OTP is
modified, and a node that never joins a group behaves like stock OTP 29.1.2
(checked against stock on a fixed corpus, gate layer L5).

## Concepts

- A **free node** belongs to no group. Free normal nodes form one ordinary
  Erlang cluster among themselves, with `global` as its registry, exactly as
  in stock OTP.
- A **member** belongs to one or more groups. Its visible connections
  (`nodes()`) are to the members of its groups only. Links to anyone else
  are hidden. Its names live in the groups' namespaces, not in `global`.
- On a member, `global:register_name/2,3` and `re_register_name/2,3`
  return `{no, the_node_is_not_free}`, `global:whereis_name/1` returns
  `undefined`, and `global:send/2` exits `badarg`, as in 19.3.

## Forming groups

Statically, in `sys.config`:

```erlang
[{kernel, [{s_groups, [{g1, normal, ['a@h1', 'b@h2', 'c@h3']},
                       {g2, normal, ['c@h3', 'd@h4']}]}]}].
```

- `s_groups` and `global_groups` can't both be set: a node configured with
  both refuses to boot.
- Conflicting definitions of a group that contains the node stop the boot.
- Conflicting definitions of a group that doesn't contain the node are
  dropped.
- The second element is 19.3's group type. It is read but not used; write
  `normal`.

At run time:

```erlang
{ok, g1, Nodes} = s_group:new_s_group(g1, ['a@h1', 'b@h2']),  %% the caller is included
{ok, G, Nodes}  = s_group:new_s_group(['a@h1', 'b@h2']),       %% generated name
{ok, g1, Added} = s_group:add_nodes(g1, ['c@h3']),
ok              = s_group:remove_nodes(g1, ['c@h3']),          %% logical: links stay up
ok              = s_group:delete_s_group(g1),
s_group:own_s_groups(),   %% [{G, Members}] for this node's groups
s_group:own_nodes(),      %% this node and all its group-mates
s_group:own_nodes(g1),
s_group:s_groups().       %% {OwnGroupNames, []} or undefined when free
```

## Names

```erlang
yes = s_group:register_name(g1, svc, Pid),
yes = s_group:re_register_name(g1, svc, Pid2),
Pid = s_group:whereis_name(g1, svc),            %% undefined if not registered
Pid = s_group:whereis_name('b@h2', g1, svc),    %% read b's replica
s_group:send(g1, svc, Msg),                     %% {badarg, {g1, svc, Msg}} if unknown
s_group:registered_names({s_group, g1}),        %% [{g1, Name}]
_   = s_group:unregister_name(g1, svc).
```

Only members can register in a group. A name is unique within its group,
and the same name in two groups means two different processes. When a
registered process dies, its name goes away.

**Via tuples.** Any OTP behaviour accepts `{via, s_group, {Group, Name}}`.
This is new in this port (19.3 had no via module):

```erlang
gen_server:start_link({via, s_group, {g1, svc}}, my_server, Args, []),
gen_server:call({via, s_group, {g1, svc}}, ping).
```

```elixir
GenServer.start_link(MyServer, args, name: {:via, :s_group, {:g1, :svc}})
GenServer.call({:via, :s_group, {:g1, :svc}}, :ping)
```

## Attributes and node choice

```erlang
ok = s_group:add_attributes([gpu]),                    %% this node
[N] = s_group:add_attributes(['b@h2'], [gpu]),         %% returns the nodes where it worked
s_group:choose_nodes([{attribute, gpu}]),            %% visible nodes having every listed attribute
s_group:remove_attributes([gpu]), s_group:remove_attributes(Nodes, [gpu]).
```

## Monitoring

`s_group:monitor_nodes(true)` delivers `{nodeup, N}` and `{nodedown, N}` for
this node's group-mates. `net_kernel:monitor_nodes/1` still works and sees
visible connections, which on a member means its group-mates.

## Partitions, failures and repair

- **Partitions inside a group** are handled per group, and logically. When
  a link between two members drops, each side keeps serving names with the
  members it can still reach. No links are cut, and other groups are not
  affected.
- **Healing.** When the link comes back, a background merge (every 2 s)
  joins the two sides under one lock. A name registered on both sides to
  different processes is resolved as `global` resolves it: one process
  keeps the name and the other is killed.
- **No automatic re-dial of lost links**, as in stock OTP and 19.3. A
  cluster manager should re-dial. `s_group:connect_node/1` dials only nodes
  this node shares a group with; for any other node it returns `ignored`.
  With libcluster:

  ```elixir
  config :libcluster, topologies: [sd: [strategy: Cluster.Strategy.Epmd,
                                        config: [hosts: [:"a@h1", :"b@h2"]],
                                        connect: {:s_group, :connect_node, []}]]
  ```

- **Node failure.** A crashed member stays a member, and the names of its
  processes are removed. When it comes back, it re-meshes with its
  group-mates. There is no "down" member status.
- **Anti-entropy.** Every few seconds, each member compares a hash of its
  name table and membership with a random in-sync group-mate. A mismatch
  triggers a merge, so replicas that drifted apart are repaired.

## Persistence across restarts

Start nodes with `-rsconfig`. Every membership change is then written,
atomically and before it is acknowledged, to `<node>.config` in the working
directory. To restore it, restart with `-config <node>`:

```sh
erl -name a@h1 -rsconfig -config a@h1
```

The record holds the groups (in 19.3's `s_groups` format) plus
`s_group_state` (membership as an observed-remove set) and
`s_group_tombstones` (deleted groups). On restart the record is a **claim**,
not the truth: the node contacts the recorded members, and their current
state wins. If the node was removed from a group while it was down, it
learns that and doesn't re-add itself. A group deleted while it was down
stays deleted.

## Knobs

| setting | default | effect |
|---|---|---|
| `-kernel s_group_anti_entropy_ms N` | 5000 | anti-entropy period; 0 turns it off |
| `-rsconfig` | off | persist memberships (above) |
| `-s_group_trace` | off | bounded in-memory event trace (debugging and trace validation) |
| `-kernel net_ticktime N` | 60 | how fast a dead link is noticed, and hence how fast a partition is handled |

## Known limitations

- Repair (merge and anti-entropy) takes a **union**, as `global`'s partition
  merge does. A name unregistered on one side of a partition, or lost to a
  crash during the unregister, can come back at the heal.
- `register_name_external/3` and `unregister_name_external/2` are aliases
  of the normal functions. 19.3's separate external-cleanup semantics are
  not reproduced.
- 19.3 had no hooks for membership changes, and neither does this port.
  Poll `own_s_groups/0`, or use `monitor_nodes/1`.
- Measured at up to 15 nodes (demos and property tests). Performance at
  larger scale has not been measured yet.
