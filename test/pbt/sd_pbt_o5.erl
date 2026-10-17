%% Characterise deviation O5 (group-name replication race) on a runtime.
%%
%% Each trial: fresh cluster, new_s_group over 7 nodes, wait until the
%% harness's membership/connection conformance holds (exactly what the
%% PropEr harness does before its next command), register one name, then
%% measure how long until every member resolves it (cap: CapMs).
%% Distinguishes R3-style slow convergence from permanent divergence.
-module(sd_pbt_o5).

-export([run/2]).

-define(TAB, sd_pbt).

run(Trials, CapMs) ->
    catch ets:new(?TAB, [named_table, public, set]),
    Results = [trial(I, CapMs) || I <- lists:seq(1, Trials)],
    Lat = [Ms || {converged, Ms} <- Results],
    Never = length([x || {never, _} <- Results]),
    io:format("~nO5 characterisation: ~p trials, cap ~p ms~n", [Trials, CapMs]),
    io:format("  converged immediately (<=50 ms): ~p~n", [length([M || M <- Lat, M =< 50])]),
    io:format("  converged late (>50 ms):        ~p ~w~n", [length([M || M <- Lat, M > 50]), lists:sort([M || M <- Lat, M > 50])]),
    io:format("  never within cap:               ~p ~w~n", [Never, [H || {never, H} <- Results]]),
    ok.

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
    yes = rpc:call(N("n4"), s_group, re_register_name, [g3, b, P]),
    T0 = erlang:monotonic_time(millisecond),
    wait(Members, P, T0, T0 + CapMs).

wait(Members, P, T0, Deadline) ->
    Holders = [M || M <- Members, rpc:call(M, global, whereis_name, [g3, b]) =:= P],
    Now = erlang:monotonic_time(millisecond),
    case {length(Holders) =:= length(Members), Now > Deadline} of
        {true, _} -> {converged, Now - T0};
        {false, true} -> {never, length(Holders)};
        _ -> timer:sleep(50), wait(Members, P, T0, Deadline)
    end.
