%% 15-node SD Erlang scenario: four overlapping s_groups, two gateways.
%%
%% Runs on a *hidden* driver node that is not an s_group member, so its own
%% connections never appear in any node's nodes() and never count as topology.
%% The expected topology is derived from the same config file the nodes boot
%% with (demo/config/sd15.config), never restated here.
%%
%% run/0      SD checks (requires the SD runtime on the 15 nodes)
%% control/0  stock-OTP control: same nodes, same seeds, expect a full mesh
-module(sd15_scenario).

-export([run/0, control/0]).

-import(sd_demo_check, [run_steps/1, report/1, check/3, await/2, await/3,
                        never/2, own_groups/1]).

-define(CONFIG, "/demo/config/sd15.config").
-define(RESTART_MS, 60000).

-define(N(Short), list_to_atom(Short ++ "@" ++ Short ++ ".sd.lab")).

%%--------------------------------------------------------------------
%% SD scenario
%%--------------------------------------------------------------------

run() ->
    T = topology(),
    report(run_steps(
      [{"all 15 nodes reachable from the hidden driver",
        fun() -> step_reachable(T) end},
       {"static membership: every node sees exactly its own groups",
        fun() -> step_membership(T) end},
       {"intra-group links form transitively from gateway-only seeds",
        fun() -> step_mesh_converges(T) end},
       {"no visible link outside a shared group (safety window)",
        fun() -> step_no_cross_group_links(T) end},
       {"`worker_pool` is three different processes in three groups",
        fun() -> step_scoped_names(T) end},
       {"every group-scoped name is known by every member of its group",
        fun() -> step_names_converged(T) end},
       {"control-group clients reach worker groups only via gateways",
        fun() -> step_gateway_routing(T) end},
       {"crash gpu3: only local_ai notices; restart restores the topology",
        fun() -> step_crash_member(T) end},
       {"crash gateway gw1: every group keeps its internal function",
        fun() -> step_crash_gateway(T) end},
       {"move edge4 from edge_ai to local_ai with remove_nodes/add_nodes",
        fun() -> step_move_node(T) end}])).

step_reachable(#{nodes := Nodes}) ->
    await("driver pings all nodes",
          fun() -> [N || N <- Nodes, net_adm:ping(N) =/= pong] =:= [] end),
    {ok, [{nodes, length(Nodes)}]}.

step_membership(#{nodes := Nodes} = T) ->
    [await(io_lib:format("own_s_groups on ~s", [N]),
           fun() -> own_groups(N) =:= expected_groups(N, T) end)
     || N <- Nodes],
    {ok, [{gw1, own_groups(?N("gw1"))}, {gpu2, own_groups(?N("gpu2"))}]}.

step_mesh_converges(#{allowed := Allowed, seeded := Seeded} = T) ->
    await("visible links == union of group cliques",
          fun() -> visible_links(T) =:= Allowed end),
    {ok, [{seeded_links, length(Seeded)},
          {links_formed_by_sd_global, length(Allowed -- Seeded)},
          {visible_links, length(Allowed)}]}.

step_no_cross_group_links(#{allowed := Allowed, nodes := Nodes} = T) ->
    never("a visible link outside the allowed set",
          fun() ->
                  case visible_links(T) -- Allowed of
                      [] -> false;
                      Extra -> Extra
                  end
          end),
    N = length(Nodes),
    %% Hidden links are permitted (not published, no shared namespace).
    {ok, [{hidden_links_observed, hidden_links(T)},
          {visible_links, length(Allowed)},
          {stock_full_mesh_would_be, N * (N - 1) div 2},
          {max_links_per_node,
           lists:max([length(rpc:call(X, erlang, nodes, [])) || X <- Nodes])}]}.

step_scoped_names(_T) ->
    Local = await_name(?N("gpu3"), local_ai, worker_pool, ?N("gpu1")),
    Edge = await_name(?N("edge3"), edge_ai, worker_pool, ?N("edge1")),
    External = await_name(?N("saas2"), external_ai, worker_pool, ?N("saas1")),
    RouterA = await_name(?N("core2"), control, router_a, ?N("gw1")),
    RouterB = await_name(?N("core3"), control, router_b, ?N("gw2")),
    check("three distinct worker_pool pids", 3,
          length(lists:usort([Local, Edge, External]))),
    check("worker_pool absent from plain global on gpu3", undefined,
          rpc:call(?N("gpu3"), global, whereis_name, [worker_pool])),
    {ok, [{local_ai, Local}, {edge_ai, Edge}, {external_ai, External},
          {router_a, RouterA}, {router_b, RouterB}]}.

step_names_converged(#{groups := Groups}) ->
    Names = [{local_ai, worker_pool}, {edge_ai, worker_pool}, {external_ai, worker_pool},
             {control, router_a}, {control, router_b}],
    [await(io_lib:format("~p ~p known on all of ~p", [Name, G, G]),
           fun() ->
                   Pids = [rpc:call(N, s_group, whereis_name, [G, Name])
                           || N <- proplists:get_value(G, Groups)],
                   length(lists:usort(Pids)) =:= 1 andalso is_pid(hd(Pids))
           end)
     || {G, Name} <- Names],
    {ok, [{names_checked, length(Names)}]}.

step_gateway_routing(#{allowed := Allowed} = T) ->
    HiddenBefore = hidden_links(T),
    Jobs =
        [{?N("core2"), router_a, local_ai,    {ok, ?N("gpu1"), local_ai, ?N("gw1")}},
         {?N("core3"), router_b, edge_ai,     {ok, ?N("edge1"), edge_ai, ?N("gw2")}},
         {?N("core1"), router_a, external_ai, {ok, ?N("saas1"), external_ai, ?N("gw1")}},
         {?N("core1"), router_b, external_ai, {ok, ?N("saas1"), external_ai, ?N("gw2")}},
         {?N("core1"), router_a, edge_ai,     {error, {not_a_member_of, edge_ai}}}],
    Results = [begin
                   Got = submit(Client, Router, Pool),
                   check(io_lib:format("~s via ~p to ~p", [Client, Router, Pool]), Want, Got),
                   {Client, Router, Pool, Got}
               end || {Client, Router, Pool, Want} <- Jobs],
    check("routing created no new visible links", Allowed, visible_links(T)),
    check("routing created no new hidden links", HiddenBefore, hidden_links(T)),
    {ok, Results}.

step_crash_member(#{allowed := Allowed, groups := Groups} = T) ->
    Gpu3 = ?N("gpu3"),
    LocalAi = proplists:get_value(local_ai, Groups),
    Outsiders = (nodes_of(T) -- LocalAi),
    Before = [{N, rpc:call(N, erlang, nodes, [])} || N <- Outsiders],
    crash_and_wait_down(Gpu3, LocalAi -- [Gpu3]),
    check("non-local_ai nodes' links unchanged by gpu3 crash", Before,
          [{N, rpc:call(N, erlang, nodes, [])} || N <- Outsiders]),
    check("local_ai still serves during the outage",
          {ok, ?N("gpu1"), local_ai, ?N("gw1")}, submit(?N("core1"), router_a, local_ai)),
    await_restarted(Gpu3),
    await("topology restored after gpu3 restart",
          fun() -> visible_links(T) =:= Allowed end),
    %% gpu1 registered worker_pool long before gpu3 rejoined.
    Pool = await_name(Gpu3, local_ai, worker_pool, ?N("gpu1")),
    {ok, [{outsiders_unaffected, length(Outsiders)}, {gpu3_relearned_worker_pool, Pool}]}.

step_crash_gateway(#{allowed := Allowed, groups := Groups} = T) ->
    Gw1 = ?N("gw1"),
    crash_and_wait_down(Gw1, [?N("gw2"), ?N("core1"), ?N("gpu1")]),
    Without = [L || {A, B} = L <- Allowed, A =/= Gw1, B =/= Gw1],
    check("all links not involving gw1 survive", Without, visible_links(T)),
    Gpus = proplists:get_value(local_ai, Groups) -- [Gw1],
    check("gpu nodes still fully meshed", length(Gpus) * (length(Gpus) - 1) div 2,
          length([L || {A, B} = L <- visible_links(T),
                       lists:member(A, Gpus), lists:member(B, Gpus)])),
    check("local_ai names still resolve inside the group", ?N("gpu1"),
          node(rpc:call(?N("gpu2"), s_group, whereis_name, [local_ai, worker_pool]))),
    check("control clients still reach external_ai via gw2",
          {ok, ?N("saas1"), external_ai, ?N("gw2")},
          submit(?N("core1"), router_b, external_ai)),
    await_restarted(Gw1),
    await("topology restored after gw1 restart",
          fun() -> visible_links(T) =:= Allowed end),
    await("router_a serves local_ai again",
          fun() ->
                  submit(?N("core2"), router_a, local_ai)
                      =:= {ok, ?N("gpu1"), local_ai, ?N("gw1")}
          end),
    {ok, [{links_during_gateway_outage, length(Without)}]}.

step_move_node(#{groups := Groups}) ->
    Edge4 = ?N("edge4"),
    check("gw2 removes edge4 from edge_ai", ok,
          rpc:call(?N("gw2"), s_group, remove_nodes, [edge_ai, [Edge4]])),
    check("gw1 adds edge4 to local_ai", {ok, local_ai, [Edge4]},
          rpc:call(?N("gw1"), s_group, add_nodes, [local_ai, [Edge4]])),
    NewLocal = lists:sort([Edge4 | proplists:get_value(local_ai, Groups)]),
    NewEdge = lists:sort(proplists:get_value(edge_ai, Groups) -- [Edge4]),
    await("edge4 is only in local_ai",
          fun() -> own_groups(Edge4) =:= [{local_ai, NewLocal}] end),
    [await(io_lib:format("~s sees edge4 in local_ai", [N]),
           fun() -> lists:member({local_ai, NewLocal}, own_groups(N)) end)
     || N <- NewLocal -- [Edge4]],
    [await(io_lib:format("~s sees edge4 gone from edge_ai", [N]),
           fun() -> lists:member({edge_ai, NewEdge}, own_groups(N)) end)
     || N <- NewEdge],
    await("edge4 resolves local_ai worker_pool on gpu1",
          fun() ->
                  case rpc:call(Edge4, s_group, whereis_name, [local_ai, worker_pool]) of
                      P when is_pid(P) -> node(P) =:= ?N("gpu1");
                      _ -> false
                  end
          end),
    %% add_nodes/2 RPCs edge4 before the two share a group, so gw1<->edge4 is
    %% created hidden and (historically) stays hidden after the join.
    await("edge4 linked (visible or hidden) to every local_ai member",
          fun() ->
                  Links = rpc:call(Edge4, erlang, nodes, [connected]),
                  (NewLocal -- [Edge4]) -- Links =:= []
          end),
    check("edge4 can no longer register in edge_ai",
          {no, cannot_register_in_remote_group},
          rpc:call(Edge4, s_group, register_name,
                   [edge_ai, intruder, rpc:call(Edge4, erlang, whereis, [init])])),
    %% Historical behaviour (see progress report 01): remove_nodes/2 is a
    %% logical disconnect, so old edge_ai links may survive. Reported only.
    {ok, [{edge4_groups, own_groups(Edge4)},
          {edge4_visible_links, lists:sort(rpc:call(Edge4, erlang, nodes, []))},
          {edge4_hidden_links, lists:sort(rpc:call(Edge4, erlang, nodes, [hidden]) -- [node()])}]}.

%%--------------------------------------------------------------------
%% Stock OTP control
%%--------------------------------------------------------------------

control() ->
    T = topology(),
    report(run_steps(
      [{"all 15 nodes reachable from the hidden driver",
        fun() -> step_reachable(T) end},
       {"stock global turns the same seeds into a full mesh",
        fun() ->
                Nodes = nodes_of(T),
                Full = lists:usort([edge(A, B) || A <- Nodes, B <- Nodes, A < B]),
                await("visible links == full mesh",
                      fun() -> visible_links(T) =:= Full end, 30000),
                {ok, [{visible_links, length(Full)},
                      {sd_allowed_links, length(maps:get(allowed, T))}]}
        end}])).

%%--------------------------------------------------------------------
%% Topology derived from the boot config
%%--------------------------------------------------------------------

topology() ->
    {ok, [Config]} = file:consult(?CONFIG),
    Kernel = proplists:get_value(kernel, Config),
    Groups = [{G, lists:sort(Ns)} || {G, normal, Ns} <- proplists:get_value(s_groups, Kernel)],
    PerNode = proplists:get_value(topology, proplists:get_value(sd_demo, Config)),
    Nodes = [N || {N, _} <- PerNode],
    Allowed = lists:usort([edge(A, B) || {_, Ns} <- Groups, A <- Ns, B <- Ns, A < B]),
    Seeded = lists:usort([edge(N, S) || {N, Spec} <- PerNode,
                                        S <- proplists:get_value(seeds, Spec, []),
                                        lists:member(edge(N, S), Allowed)]),
    #{groups => Groups, nodes => Nodes, allowed => Allowed, seeded => Seeded}.

nodes_of(#{nodes := Nodes}) -> Nodes.

expected_groups(Node, #{groups := Groups}) ->
    lists:sort([{G, Ns} || {G, Ns} <- Groups, lists:member(Node, Ns)]).

edge(A, B) when A < B -> {A, B};
edge(A, B) -> {B, A}.

visible_links(T) -> links(T, visible).
hidden_links(T) -> links(T, hidden).

links(#{nodes := Nodes}, Kind) ->
    lists:usort([edge(A, B) || A <- Nodes,
                               B <- case rpc:call(A, erlang, nodes, [Kind]) of
                                        L when is_list(L) -> L;
                                        _ -> []
                                    end,
                               lists:member(B, Nodes)]).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

submit(Client, Router, Pool) ->
    rpc:call(Client, sd_demo_client, submit, [control, Router, Pool]).

await_name(From, Group, Name, ExpectNode) ->
    await(io_lib:format("~s resolves ~p in ~p", [From, Name, Group]),
          fun() ->
                  case rpc:call(From, s_group, whereis_name, [Group, Name]) of
                      P when is_pid(P) -> node(P) =:= ExpectNode andalso {true, P};
                      _ -> false
                  end
          end).

%% Abrupt BEAM exit; the container restart policy brings the node back.
crash_and_wait_down(Node, Observers) ->
    put({uptime, Node}, element(1, rpc:call(Node, erlang, statistics, [wall_clock]))),
    rpc:cast(Node, erlang, halt, [1]),
    [await(io_lib:format("~s sees ~s down", [O, Node]),
           fun() -> not lists:member(Node, rpc:call(O, erlang, nodes, [])) end)
     || O <- Observers],
    ok.

%% Uptime, not pid inequality: OTP 20's 2-bit creation can recycle pids.
await_restarted(Node) ->
    Before = get({uptime, Node}),
    await(io_lib:format("~s restarted", [Node]),
          fun() ->
                  _ = net_adm:ping(Node),
                  case rpc:call(Node, erlang, statistics, [wall_clock]) of
                      {Up, _} when is_integer(Up), Up < Before -> true;
                      _ -> false
                  end
          end, ?RESTART_MS).
