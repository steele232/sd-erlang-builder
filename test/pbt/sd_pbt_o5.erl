%% Characterise deviation O5 (group-name replication race) on a runtime.
%%
%% Each trial: fresh cluster, new_s_group over 7 nodes, wait until the
%% harness's membership/connection conformance holds (exactly what the
%% PropEr harness does before its next command), register one name, then
%% measure how long until every member resolves it (cap: CapMs).
%% Distinguishes R3-style slow convergence from permanent divergence.
-module(sd_pbt_o5).

-include("sd_compat.hrl").

-export([run/2, trace_failure/1]).

%% Hypothesis under test (spec/deviations.yml O5/O6): global's own-group
%% view (global:own_s_groups/0, fed asynchronously by s_group) lags s_group's,
%% and unregister_foreign_names/1, run after every sync, deletes the new
%% group's names on lagging nodes. Each trial snapshots, just before the
%% registration, which members' global view already contains g3.

-define(TAB, sd_pbt).

run(Trials, CapMs) ->
    _ = ?CATCH(ets:new(?TAB, [named_table, public, set])),
    Results = [trial(I, CapMs) || I <- lists:seq(1, Trials)],
    Lat = [Ms || {converged, Ms, _, _} <- Results],
    Never = length([x || {never, _, _, _} <- Results]),
    io:format("~nO5 characterisation: ~p trials, cap ~p ms~n", [Trials, CapMs]),
    io:format("  converged immediately (<=50 ms): ~p~n", [length([M || M <- Lat, M =< 50])]),
    io:format("  converged late (>50 ms):        ~p ~w~n", [length([M || M <- Lat, M > 50]), lists:sort([M || M <- Lat, M > 50])]),
    io:format("  never within cap:               ~p ~w~n", [Never, [H || {never, H, _, _} <- Results]]),
    io:format("  per trial: {outcome, members whose global view lacked g3 at registration, members finally missing the name}~n"),
    [io:format("    ~p~n", [{element(1, R), Lag, Miss}]) || R = {_, _, {Lag, Miss}, _} <- Results],
    Never2 = [{Lag, Miss} || {never, _, {Lag, Miss}, _} <- Results],
    Explained = [x || {Lag, Miss} <- Never2, Miss -- Lag =:= []],
    io:format("  foreign-GC hypothesis: in ~p/~p never-converged trials every missing member was lagging~n",
              [length(Explained), length(Never2)]),
    Kn = [{Miss, Unknown} || {never, _, {_, Miss}, Unknown} <- [extend(R) || R <- Results]],
    KnExplained = [x || {Miss, Unknown} <- Kn, Miss -- Unknown =:= []],
    io:format("  O5=Q1 hypothesis: in ~p/~p never-converged trials every missing member is still absent "
              "from the registrant's global known(g3) at the end~n", [length(KnExplained), length(Kn)]),
    [io:format("    missing ~p, registrant-unknown ~p~n", [M, U]) || {M, U} <- Kn],
    ok.

extend({O, X, LM, Unknown}) -> {O, X, LM, Unknown};
extend({O, X, LM}) -> {O, X, LM, []}.

trial(_I, CapMs) ->
    ok = sd_pbt_cluster:reset(),
    Maps = sd_pbt_cluster:pid_maps(),
    ets:insert(?TAB, {pid_maps, Maps}),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    Members = lists:sort([N(X) || X <- ["n10", "n3", "n4", "n5", "n6", "n7", "n9"]]),
    M0 = sd_model:initial_state(sd_pbt_cluster:node_types()),
    {M1, _} = sd_model:new_s_group(M0, g3, Members, N("n3")),
    {ok, _, _} = rpc:call(N("n3"), s_group, new_s_group, [g3, Members]),
    {ok, _} = sd_pbt_obs:await_conformance(M1, Maps, 10000),
    P = rpc:call(N("n8"), erlang, whereis, [sd_pbt_p3]),
    Lagging = [M || M <- Members,
                    not lists:keymember(g3, 1, global_view(M))],
    yes = rpc:call(N("n4"), s_group, re_register_name, [g3, b, P]),
    T0 = erlang:monotonic_time(millisecond),
    case wait(Members, P, T0, T0 + CapMs) of
        {Outcome, X} ->
            Missing = [M || M <- Members, rpc:call(M, s_group, whereis_name, [g3, b]) =/= P],
            RegKnown = sd_pbt_obs:known_on(N("n4"), g3),
            Outcome =:= never andalso
                io:format("NEVER detail (member, in-sync set, lookup, connected): ~p~n",
                          [[{hd(string:tokens(atom_to_list(M), "@")),
                             short(sd_pbt_obs:known_on(M, g3)),
                             rpc:call(M, s_group, whereis_name, [g3, b]) =:= P,
                             short([C || C <- rpc:call(M, erlang, nodes, [connected]), lists:member(C, Members)])}
                            || M <- Members]]),
            Outcome =:= never andalso
                [io:format("TRACE ~s: ~p~n", [hd(string:tokens(atom_to_list(M), "@")),
                                              [{T, Ev} || {_, T, Ev} <- rpc:call(M, s_group, i_log, []),
                                                          lists:member(b, tuple_to_list(Ev)) orelse element(1, Ev) =:= sync]])
                 || M <- Members, rpc:call(M, s_group, whereis_name, [g3, b]) =/= P],
            Unknown = (Members -- [N("n4")]) -- RegKnown,
            {Outcome, X, {short(Lagging), short(Missing)}, short(Unknown)}
    end.

global_view(M) ->
    case rpc:call(M, global, own_s_groups, []) of
        L when is_list(L) -> L;
        _ -> []
    end.

short(Ns) -> [hd(string:tokens(atom_to_list(Nd), "@")) || Nd <- Ns].

wait(Members, P, T0, Deadline) ->
    Holders = [M || M <- Members, rpc:call(M, s_group, whereis_name, [g3, b]) =:= P],
    Now = erlang:monotonic_time(millisecond),
    case {length(Holders) =:= length(Members), Now > Deadline} of
        {true, _} -> {converged, Now - T0};
        {false, true} -> {never, length(Holders)};
        _ -> timer:sleep(50), wait(Members, P, T0, Deadline)
    end.

%% Repeat trials with global's high-level trace on every member until one
%% never converges (max Tries); dump all members' traces to /pbt/out.
trace_failure(Tries) when Tries =< 0 ->
    io:format("no failing trial captured~n"),
    ok;
trace_failure(Tries) ->
    _ = ?CATCH(ets:new(?TAB, [named_table, public, set])),
    ok = sd_pbt_cluster:reset(),
    Maps = sd_pbt_cluster:pid_maps(),
    ets:insert(?TAB, {pid_maps, Maps}),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    Members = lists:sort([N(X) || X <- ["n10", "n3", "n4", "n5", "n6", "n7", "n9"]]),
    [ok = rpc:call(M, gen_server, call, [global_name_server, high_level_trace_start, infinity]) || M <- Members],
    T0 = os:timestamp(),
    M0 = sd_model:initial_state(sd_pbt_cluster:node_types()),
    {M1, _} = sd_model:new_s_group(M0, g3, Members, N("n3")),
    {ok, _, _} = rpc:call(N("n3"), s_group, new_s_group, [g3, Members]),
    {ok, _} = sd_pbt_obs:await_conformance(M1, Maps, 10000),
    P = rpc:call(N("n8"), erlang, whereis, [sd_pbt_p3]),
    TReg = os:timestamp(),
    yes = rpc:call(N("n4"), s_group, re_register_name, [g3, b, P]),
    T1 = erlang:monotonic_time(millisecond),
    case wait(Members, P, T1, T1 + 15000) of
        {converged, _} ->
            trace_failure(Tries - 1);
        {never, _} ->
            Traces = [{M, rpc:call(M, gen_server, call, [global_name_server, high_level_trace_get, infinity])} || M <- Members],
            Missing = [M || M <- Members, rpc:call(M, s_group, whereis_name, [g3, b]) =/= P],
            %% term_to_binary: traces contain pids, which file:consult/1 cannot read back.
            File = "/pbt/out/o5-trace.bin",
            ok = file:write_file(File, term_to_binary(
                    #{t0 => T0, t_register => TReg, registrant => N("n4"),
                      missing => Missing, traces => Traces})),
            io:format("captured failing trial: missing ~p, traces in ~s~n", [short(Missing), File]),
            ok
    end.
