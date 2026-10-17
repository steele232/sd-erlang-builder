%% Q1 mechanism test: creating (or adding to) a group whose prospective
%% members already share another group with the caller. Hypothesis: the
%% logical disconnect in new_s_group/add_nodes (disconnect_nodes -> global
%% nodedown) wipes global's knowledge in the EXISTING shared group, and only
%% the new group is re-synced (same class as Q2).
-module(sd_pbt_q1).

-include("sd_compat.hrl").

-export([run/1, trace_replay/2]).

run(Trials) ->
    [report(V, [trial(V) || _ <- lists:seq(1, Trials)]) || V <- [new_s_group, add_nodes]],
    ok.

report(V, R) ->
    io:format("Q1 via ~p: ~p/~p trials lost g6 knowledge~n", [V, length([x || {lost, _} <- R]), length(R)]),
    [io:format("    ~p~n", [X]) || X <- lists:usort([D || {lost, D} <- R])].

trial(Variant) ->
    _ = ?CATCH(ets:new(sd_pbt, [named_table, public, set])),
    ok = sd_pbt_cluster:reset(),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    %% g6 = {A, B, D}: B and D are connected, non-initiator new members of g3,
    %% so new_s_group_check on B logically disconnects D (and vice versa).
    {A, B, C, D} = {N("n1"), N("n2"), N("n3"), N("n4")},
    G6Members = lists:sort([A, B, D]),
    {ok, g6, _} = rpc:call(A, s_group, new_s_group, [g6, G6Members]),
    ok = settle(fun() -> all_know(G6Members, g6) end, 15000),
    case Variant of
        new_s_group -> {ok, g3, _} = rpc:call(A, s_group, new_s_group, [g3, [A, B, C, D]]);
        add_nodes ->
            {ok, g3, _} = rpc:call(A, s_group, new_s_group, [g3, [A, C]]),
            timer:sleep(1500),
            {ok, g3, _} = rpc:call(A, s_group, add_nodes, [g3, [B, D]])
    end,
    timer:sleep(5000),
    case all_know(G6Members, g6) of
        true -> {kept, ok};
        false -> {lost, maps:from_list([{M, known(M, g6)} || M <- G6Members])}
    end.

all_know(Members, G) ->
    lists:all(fun(M) -> known(M, G) =:= lists:sort(Members -- [M]) end, Members).

known(N, G) ->
    case rpc:call(N, global, get_known_s_group, [G]) of
        L when is_list(L) -> lists:sort(L);
        O -> O
    end.

settle(Fun, Ms) when Ms =< 0 -> case Fun() of true -> ok; false -> timeout end;
settle(Fun, Ms) -> case Fun() of true -> ok; false -> timer:sleep(100), settle(Fun, Ms - 100) end.

%% Replay a stored failing case the way sd_pbt_statem runs it (model-driven
%% conformance + quiescence waits after each command) with global's
%% high-level trace on every SUT node from the start. At the FIRST
%% quiescence failure, dump all traces and global states (term_to_binary)
%% to /pbt/out/q1-trace.bin. (An unshrunk counterexample is the whole
%% generated case; the failure can be at any step.)
trace_replay(File, Tries) when Tries =< 0 ->
    io:format("no failing replay captured (~s)~n", [File]), ok;
trace_replay(File, Tries) ->
    {ok, [#{counterexample := [CE]}]} = file:consult(File),
    _ = ?CATCH(ets:new(sd_pbt, [named_table, public, set])),
    ok = sd_pbt_cluster:reset(),
    Maps = sd_pbt_cluster:pid_maps(),
    ets:insert(sd_pbt, {pid_maps, Maps}),
    Sut = sd_pbt_cluster:sut_nodes(),
    [rpc:call(N, gen_server, call, [global_name_server, high_level_trace_start, infinity]) || N <- Sut],
    Calls = [C || {set, _, C} <- CE],
    M0 = sd_model:initial_state(sd_pbt_cluster:node_types()),
    case run_calls(Calls, M0, Maps, 1) of
        ok -> trace_replay(File, Tries - 1);
        {conformance_failed, K} ->
            io:format("conformance failure at step ~p (not Q1); retrying~n", [K]),
            trace_replay(File, Tries - 1);
        {quiescence_failed, K, Call, Lag} ->
            Traces = [{N, rpc:call(N, gen_server, call, [global_name_server, high_level_trace_get, infinity])} || N <- Sut],
            States = [{N, rpc:call(N, sys, get_state, [global_name_server, 5000])} || N <- Sut],
            %% Q4: what is each lagging node's locker doing (stack, queued messages)?
            Lockers = [{N, rpc:call(N, erlang, apply, [fun locker_info/0, []], 5000)}
                       || {N, _, Ms} <- Lag, length(Ms) >= 2],
            ok = file:write_file("/pbt/out/q1-trace.bin",
                                 term_to_binary(#{step => K, call => Call, lagging => Lag,
                                                  traces => Traces, states => States,
                                                  states_before => get(before_states),
                                                  lockers => Lockers})),
            io:format("captured Q1 at step ~p ~P; lagging ~p~n",
                      [K, Call, 8, [{Nd, length(Ms)} || {Nd, _, Ms} <- Lag]]),
            ok
    end.

run_calls([], _M, _Maps, _K) -> ok;
run_calls([{call, sd_pbt_statem, F, Args} = Call | Rest], M, Maps, K) ->
    %% Snapshot every node's global state before each command (kept only for
    %% the failing step): did knowledge exist before and get lost, or never form?
    put(before_states, [{N, rpc:call(N, sys, get_state, [global_name_server, 5000])}
                        || N <- sd_pbt_cluster:sut_nodes()]),
    _ = apply(sd_pbt_statem, F, Args),
    {M1, _} = sd_pbt_impl:step(M, F, Args),
    case sd_pbt_obs:await_conformance(M1, Maps, 10000) of
        {ok, _} ->
            case sd_pbt_obs:await_quiescent(M1, 10000) of
                {ok, _} -> run_calls(Rest, M1, Maps, K + 1);
                {error, {not_quiescent, Lag, _}} -> {quiescence_failed, K, Call, Lag}
            end;
        _ -> {conformance_failed, K}
    end.

%% Runs on a SUT node: the global locker is the pid field of
%% global_name_server's state whose current function is loop_the_locker or
%% one of its receives.
locker_info() ->
    St = sys:get_state(global_name_server, 2000),
    Pids = [P || P <- tuple_to_list(St), is_pid(P), is_process_alive(P)],
    [erlang:process_info(P, [current_function, current_stacktrace, message_queue_len, messages])
     || P <- Pids].
