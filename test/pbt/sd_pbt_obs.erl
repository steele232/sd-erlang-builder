%% Observe the implementation's state and compare it with the model.
%%
%% Conformance relation  I ~ M  (D3.3 5.2 / AST'14 4.5: "the actual state
%% information is collected from each node ..., merged and normalised to the
%% same format as the abstract state"):
%%
%%   C1 membership   for every node, own_s_groups() == M's groups containing it
%%                   (this also makes every member agree on each group's node list)
%%   C2 namespace    for every group G and every member N, N's global table for
%%                   G == M's namespace of G  (replication on all members)
%%   C3 connections  M's connections of N  ⊆  nodes(connected) on N
%%                   (I may hold extra links: O2/O4 in spec/deviations.yml)
%%   C4 visibility   (default on; SD_PBT_VISIBILITY=0 disables; P1 + S2;
%%                   clean on 19.3 and fixed6, 2026-10-17) every VISIBLE link
%%                   on N (nodes() on N) joins two nodes that share a group in
%%                   M, or two free nodes, or is a connection M itself holds
%%                   (links kept by remove_nodes/2, O1 must_match). C3 counts
%%                   hidden links too, so without C4 a fully meshed cluster
%%                   passes L1.
%%   C5 co-member    (ports only; decision D-1, spec/deviations.yml O3) two
%%      visibility   members of a common group that are connected are VISIBLY
%%                   connected. 19.3 keeps such links hidden by design (O3).
%%
%% Not compared (M constructs with no stable observable in I): free normal
%% group partitions and their namespaces, node visibility (hidden vs normal).
%%
%% Because I converges asynchronously (R3), conformance is checked as
%% eventual equality: poll until I ~ M or the deadline passes.
-module(sd_pbt_obs).

-export([observe/1, diff/3, await_conformance/3, await_quiescent/2, known_on/2]).

-define(POLL_MS, 100).

%% Returns #{Node => #{groups => [{G, Nodes}], names => [{G, [{Name, PidRef}]}],
%%                     conns => [Node]}}
observe(PidMaps) ->
    Driverless = fun(Ns) -> [N || N <- Ns, lists:member(N, sd_pbt_cluster:sut_nodes())] end,
    maps:from_list(
      [{N, observe_node(N, PidMaps, Driverless)} || N <- sd_pbt_cluster:sut_nodes()]).

observe_node(N, PidMaps, Driverless) ->
    Groups = case rpc:call(N, s_group, own_s_groups, []) of
                 L when is_list(L) -> lists:sort([{G, lists:sort(Ns)} || {G, Ns} <- L]);
                 Other -> {error, Other}
             end,
    Names = case Groups of
                {error, _} -> [];
                _ -> [{G, group_names(N, G, PidMaps)} || {G, _} <- Groups]
            end,
    Conns = case rpc:call(N, erlang, nodes, [connected]) of
                Cs when is_list(Cs) -> lists:sort(Driverless(Cs));
                _ -> []
            end,
    Vis = case rpc:call(N, erlang, nodes, [visible]) of
              Vs when is_list(Vs) -> lists:sort(Driverless(Vs));
              _ -> []
          end,
    Hid = case rpc:call(N, erlang, nodes, [hidden]) of
              Hs when is_list(Hs) -> lists:sort(Driverless(Hs));
              _ -> []
          end,
    #{groups => Groups, names => Names, conns => Conns, vis => Vis, hidden_conns => Hid}.

group_names(N, G, PidMaps) ->
    case is_port_runtime(N) of
        true ->
            %% Ports: observe through the public s_group API only.
            Names = case rpc:call(N, s_group, registered_names, [{s_group, G}]) of
                        L when is_list(L) -> [Nm || {G1, Nm} <- L, G1 =:= G];
                        _ -> []
                    end,
            lists:sort([{Name, sd_pbt_cluster:to_ref(rpc:call(N, s_group, whereis_name, [G, Name]), PidMaps)}
                        || Name <- Names]);
        false ->
            %% 19.3 reference: unchanged observation (baselines stay valid).
            All = case rpc:call(N, global, registered_names, [all_names]) of
                      L when is_list(L) -> L;
                      _ -> []
                  end,
            lists:sort([{Name, sd_pbt_cluster:to_ref(rpc:call(N, global, whereis_name, [G, Name]), PidMaps)}
                        || {G1, Name} <- All, G1 =:= G])
    end.

%% A port candidate exports s_group:known_peers/1 (its quiescence probe).
is_port_runtime(N) ->
    rpc:call(N, erlang, function_exported, [s_group, known_peers, 1]) =:= true.

%% [] when I ~ M, otherwise a list of human-readable differences.
diff(Model, Obs, Nodes) ->
    lists:append([node_diff(N, Model, maps:get(N, Obs)) || N <- Nodes]).

node_diff(N, Model, #{groups := IGroups, names := INames, conns := IConns} = Obs) ->
    MGroups = [{G, Nis} || {G, Nis, _} <- sd_model:groups(Model), lists:member(N, Nis)],
    MNames = [{G, Ns} || {G, Nis, Ns} <- sd_model:groups(Model), lists:member(N, Nis)],
    {N, _, MConns, _} = sd_model:node_record(N, Model),
    [{N, c1_membership, {model, MGroups}, {impl, IGroups}} || MGroups =/= IGroups] ++
    [{N, c2_namespace, {model, MNames}, {impl, INames}}
     || is_list(IGroups), MGroups =:= IGroups, MNames =/= INames] ++
    [{N, c3_connections_missing, MConns -- IConns} || (MConns -- IConns) =/= []] ++
    [{N, c5_comember_link_hidden, Hid}
     || is_port_runtime(N) orelse os:getenv("SD_PBT_C5_ALL") =:= "1",   % override: validate C5 on 19.3
        Hid <- [[M || M <- maps:get(hidden_conns, Obs, []), lists:member(M, comembers(N, Model))]],
        Hid =/= []] ++
    [{N, c4_visible_outside_group, Bad}
     || os:getenv("SD_PBT_VISIBILITY", "1") =/= "0",
        Bad <- [[M || M <- maps:get(vis, Obs, []),
                      not lists:member(M, MConns), not visible_ok(N, M, Model)]],
        Bad =/= []].

visible_ok(N, M, Model) ->
    Free = fun(X) -> element(4, sd_model:node_record(X, Model)) =:= no_group end,
    lists:any(fun({_G, Nis, _}) -> lists:member(N, Nis) andalso lists:member(M, Nis) end,
              sd_model:groups(Model))
        orelse (Free(N) andalso Free(M)).

%% Quiescence: global on every member knows every other member of each of
%% its groups. Not part of the conformance relation (M has no such notion);
%% it is the harness's "system at rest" condition before the next command,
%% so that the O5 race cannot fire (spec/deviations.yml). The probe is
%% 19.3-specific (global:get_known_s_group/1); a port must supply an
%% equivalent or the harness falls back to eager mode.
%% {ok, LatencyMs} | {error, NotQuiescent}
await_quiescent(Model, TimeoutMs) ->
    T0 = erlang:monotonic_time(millisecond),
    quiescent_loop(Model, T0, T0 + TimeoutMs).

quiescent_loop(Model, T0, Deadline) ->
    Lagging = [{N, G, Missing}
               || {G, Nis, _} <- sd_model:groups(Model), N <- Nis,
                  Missing <- [(Nis -- [N]) -- known(N, G)], Missing =/= []],
    case Lagging of
        [] -> {ok, erlang:monotonic_time(millisecond) - T0};
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {error, {not_quiescent, Lagging, lock_evidence(Lagging)}};
                false -> timer:sleep(?POLL_MS), quiescent_loop(Model, T0, Deadline)
            end
    end.

%% Q1 evidence: global's lock table (and locker/registrar message queues) on
%% the nodes that never completed a sync. Hypothesis: a lock left held by an
%% aborted sync blocks all later syncs involving that node.
lock_evidence(Lagging) ->
    %% The most-lagging nodes (fewest peers known) are the stuck ones.
    Ranked = lists:reverse(lists:keysort(2, [{N, length(Ms)} || {N, _G, Ms} <- Lagging])),
    Nodes = lists:usort([N || {N, _} <- lists:sublist(Ranked, 2)]),
    %% Formatted on the SUT side as text: raw pids would make the report
    %% unreadable by file:consult/1.
    [{N, rpc:call(N, erlang, apply, [fun evidence_text/0, []], 5000)} || N <- Nodes].

evidence_text() ->
    Gns = whereis(global_name_server),
    St = (try sys:get_state(Gns, 2000) catch _:_ -> unavailable end),
    Locker = case St of
                 T when is_tuple(T) -> [P || P <- tuple_to_list(T), is_pid(P)];
                 _ -> []
             end,
    LockerInfo = [erlang:process_info(P, [current_function, current_stacktrace, message_queue_len])
                  || P <- Locker, is_process_alive(P)],
    iolist_to_binary(io_lib:format("~P", [#{locks => ets:tab2list(global_locks),
                                            gns_state => St,
                                            pid_fields => LockerInfo}, 200])).

known(N, G) ->
    Probe = case is_port_runtime(N) of
                true -> {s_group, known_peers};
                false -> {global, get_known_s_group}
            end,
    case rpc:call(N, element(1, Probe), element(2, Probe), [G]) of
        L when is_list(L) -> L;
        _ -> []
    end.

%% {ok, LatencyMs} | {error, Diff}
await_conformance(Model, PidMaps, TimeoutMs) ->
    T0 = erlang:monotonic_time(millisecond),
    await_loop(Model, PidMaps, T0, T0 + TimeoutMs).

await_loop(Model, PidMaps, T0, Deadline) ->
    Obs = observe(PidMaps),
    case diff(Model, Obs, sd_pbt_cluster:sut_nodes()) of
        [] ->
            {ok, erlang:monotonic_time(millisecond) - T0};
        Diff ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {error, Diff};
                false -> timer:sleep(?POLL_MS), await_loop(Model, PidMaps, T0, Deadline)
            end
    end.

%% Group knowledge of N for G: 19.3's global:get_known_s_group/1, or a port's
%% s_group:known_peers/1 (its in-sync set).
known_on(N, G) ->
    case is_port_runtime(N) of
        true -> rpc:call(N, s_group, known_peers, [G]);
        false -> rpc:call(N, global, get_known_s_group, [G])
    end.

comembers(N, Model) ->
    lists:usort(lists:append([Nis || {_G, Nis, _} <- sd_model:groups(Model), lists:member(N, Nis)]))
        -- [N].

