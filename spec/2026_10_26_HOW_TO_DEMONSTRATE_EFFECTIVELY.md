# Prompt based on new realizations about the best uses for SD Erlang

okay.. sat on this and stewed for a several days. What if for a demonstration, I created a WhatsApp or EMQ clone? Seems like the perfect 'use case' for the tool and it has legitimate 'usefulness' based on existing products. And it would be intuitive to benchmark I think. Also, half-related: I have been trying to grok the appropriate use of the system and I think it works best with a (1) good 'process group' management system (since it appears that is what WhatsApp decided that they REALLY needed after learning from but not implementing SD Erlang a decade or so ago -- and they even upstreamed a good bit of their 'spg' project and we have the current stock OTP's pg module which has some similar features like 'membership views are non-transitive' similar to s_group behavior) (for our demo/target-app, we'd probably try out using 'all' the available open source process group mgmt libraries including but not limited to Group from Chris McCord, Syn, Swarm, and the super_worker or something library from the vietnamese consultancy, and stock OTP pg as well. // not sure about DurableServer and RiakCore)  and (2) the ability (a library) to have multiple connections between nodes in the cluster (since having only one connection between nodes in the cluster can lead to 'clogged pipes' which then make heartbeat signals delayed and thus make the nodes think that the other nodes are dead etc) and some example libraries for that are .. actually I had a list but lost it for now. But we should be able to find one; there are some good ones out there I think and also Chris McCord talked about in his recent ElixirConf2026 keynote about how they are doing something like this on top of Phoenix endpoint to create these inter-cluster-node multiple-connections thing, but we don't have access to that; I'm just pretty sure that there are erlang libraries out there for htis.     . For our purposes, it also makes sense if the target/demo (business) application requires smaller-latency globally and therefore benefits from multi-region clusters and global reach (which we would use with one s_group per region or availability zone etc).

## Response 1 

I've written the library lineup in bench/LIBRARIES.md and a basic spec for the WhatsApp-style app in bench/chat/SPEC.md, and committed both (9ac6428). The note in NEXT_ROUNDS.md now points the reference-app slot at the chat spec. Versions and dependencies come from Hex as of today. How each library behaves on SD Erlang is so far a prediction from reading its source: I haven't run any of them on our image yet.

The "Group" library you remembered exists. It's phoenixframework/group 0.3.1, released on 2026-10-11, and it's the most interesting find:
- Named subclusters: isolated registries and groups that only connected nodes take part in, which is close to
  what s_groups do.
- Separate data channel: control traffic stays on Erlang distribution, while the replicated data can go over a transport you plug in. That's likely what McCord described. Only the default distribution transport ships; a TCP one exists in its tests, and I found no public version built on a Phoenix endpoint. Writing one could be a hands-on task.
- DurableServer is built on it, together with McCord's new ekv key-value store.

Process-group libraries to test: first pg, Group, Phoenix.PubSub, Syn and Horde. They find peers through the visible node list, so on a group member they should limit themselves to its groups with no changes. Two are predicted to break, which makes them good migration examples:
- Highlander registers through global, which is closed on group members.
- ProcessHub depends on a leader-election library that registers through global.

Two of yours don't fit:
- SuperWorker (the Vietnamese consultancy, ohhi.vn) appears to work on one node only; its docs show no cross-node features.
- Swarm hasn't been updated since 2019, so it gets only a smoke test.

Getting past the single connection between nodes:
- EMQX's fork of gen_rpc: opens several connections per node pair (EMQX defaults to 10). It only ships from GitHub (not on Hex), and its README calls it "temporarily maintained for legacy support".
- Partisan 6.3.1: replaces the distribution layer and has named channels with configurable parallelism. It supports OTP 27–29.
- quic_dist (in the erlang_quic package): carries normal Erlang distribution over QUIC, whose multiple streams avoid head-of-line blocking. It sits below the s_group layer, so SD Erlang's semantics and connection limits should stay intact. This is probably the best fit and a one-flag experiment, though it's a young project.
- Supporting libraries: Manifold sends fewer messages between nodes, ZenMonitor batches remote monitors, and aten detects failures separately from the heartbeat ticks.
- The catch: gen_rpc and similar libraries open their own sockets outside s_groups. Unless the app opens them only to group-mates, SD Erlang's advantage in connection count quietly disappears, so the plan counts sockets per node, not just Erlang connections.

bench/chat/SPEC.md (SD Chat v0):
- Features: 1:1 chats and chat-groups of up to 256 members, sent/delivered/read receipts, offline delivery and presence.
- Delivery: messages are ordered per conversation, and a message acknowledged as sent must never be lost.
- Groups: one s_group per region, plus a wan group containing only the gateways.
- Representative roles: gateway, metrics roll-up, control and admin ingress, each elected per region the way we discussed.
- Benchmarks: six workloads over three simulated regions with added network delay, the existing failure schedule, and the three-way comparison with stock OTP and Partisan.
- Milestones: M0 to M7, with the MQTT front end (the EMQ clone) at M6.

One design point in the spec you should know about: session lookup goes through a process-group library rather than s_group names. Registering an s_group name takes a group lock and messages every member, like global, which is fine for a few long-lived names but probably too slow for millions of device sessions reconnecting. The spec marks this as hypothesis H1 for the benchmarks to test.

Six open questions are at the end of the spec. My recommendations are Phoenix Channels before MQTT, Elixir, and one Postgres per region so storage traffic stays off Erlang distribution and doesn't skew the comparison. The mobile framework is your call.

Sources:
- phoenixframework/group (Hex) (https://hex.pm/packages/group)
- Partisan 6.0.0 changelog (https://repo.hex.pm/preview/partisan/6.0.0/CHANGELOG.md)
- erlang_quic quic_dist docs (https://quic.hexdocs.pm/quic_dist.html)
- gen_rpc README (https://readme.hex.pm/gen_rpc/2.1.0)
- EMQX configuration manual (rpc.tcp_client_num) (https://docs.emqx.com/en/emqx/v5.1/configuration/configuration-manual.html)
- Syn v3 announcement (https://erlang.org/pipermail/erlang-questions/2021-October/101577.html)
- ProcessHub docs (https://hexdocs.pm/process_hub/readme.html)
- Horde README (https://repo.hex.pm/preview/horde/0.10.0/README.md)
- SuperWorker docs (https://hexdocs.pm/super_worker/SuperWorker.html)
- DistributedSupervisor docs (https://distributed-supervisor.hexdocs.pm/readme.html)
- Discord's Manifold (https://readme.hex.pm/manifold/1.7.0) and How Discord scaled Elixir (https://discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users)
- DurableServer keynote (ElixirConf EU 2026) (https://www.elixirconf.eu/keynotes/durableserver-always-running-somewhere/)
- OTP 22 highlights (https://www.erlang.org/blog/OTP-22-Highlights/) and rabbitmq/ra#135 (https://github.com/rabbitmq/ra/issues/135)
- pg manual page (https://manpages.ubuntu.com/manpages/noble/man3/pg.3erl.html)



