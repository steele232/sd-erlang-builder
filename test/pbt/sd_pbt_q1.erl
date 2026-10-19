%% Q1 mechanism test: creating (or adding to) a group whose prospective
%% members already share another group with the caller. Hypothesis: the
%% logical disconnect in new_s_group/add_nodes (disconnect_nodes -> global
%% nodedown) wipes global's knowledge in the EXISTING shared group, and only
%% the new group is re-synced (same class as Q2).
-module(sd_pbt_q1).
%% exit/2 is deprecated from OTP 30 (exit_signal/2), which OTP 20-29 lack.
-compile({nowarn_deprecated_function, [{erlang, exit, 2}]}).

-include("sd_compat.hrl").

-export([run/1, trace_replay/2, msg_tracer_start/0, msg_tracer_dump/0]).

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
    [rpc:call(N, gen_server, call, [global_name_server, high_level_trace_start, 5000], 8000) || N <- Sut],
    [rpc:call(N, ?MODULE, msg_tracer_start, [], 8000) || N <- Sut],
    Calls = [C || {set, _, C} <- CE],
    M0 = sd_model:initial_state(sd_pbt_cluster:node_types()),
    case run_calls(Calls, M0, Maps, 1) of
        ok -> trace_replay(File, Tries - 1);
        {conformance_failed, K} ->
            io:format("conformance failure at step ~p (not Q1); retrying~n", [K]),
            trace_replay(File, Tries - 1);
        {quiescence_failed, K, Call, Lag} ->
            Traces = [{N, rpc:call(N, gen_server, call, [global_name_server, high_level_trace_get, 5000], 8000)} || N <- Sut],
            States = [{N, rpc:call(N, sys, get_state, [global_name_server, 5000], 8000)} || N <- Sut],
            %% Q4: what is each lagging node's locker doing (stack, queued messages)?
            Lockers = [{N, rpc:call(N, erlang, apply, [fun locker_info/0, []], 5000)}
                       || {N, _, Ms} <- Lag, length(Ms) >= 2],
            MsgOrder = [{N, rpc:call(N, ?MODULE, msg_tracer_dump, [], 5000)} || N <- Sut],
            %% Q4: are the stuck node's links to its group peers visible or hidden?
            Links = [{N, #{visible => rpc:call(N, erlang, nodes, [visible], 5000),
                           hidden => rpc:call(N, erlang, nodes, [hidden], 5000)}} || N <- Sut],
            %% Q4 prediction 1: stuck peers sit in s_group's sync_error list.
            SgInfo = [{N, rpc:call(N, s_group, info, [], 5000)} || N <- Sut],
            %% Q4 prediction 2: an explicit s_group:sync() on every member repairs it.
            [rpc:call(N, s_group, sync, [], 10000) || N <- Sut],
            Repaired = sd_pbt_obs:await_quiescent(sd_pbt_impl_model(), 15000),
            io:format("after s_group:sync() on all members: ~p~n", [element(1, Repaired)]),
            ok = file:write_file("/pbt/out/q1-trace.bin",
                                 term_to_binary(#{step => K, call => Call, lagging => Lag,
                                                  traces => Traces, states => States,
                                                  states_before => get(before_states),
                                                  lockers => Lockers,
                                                  msg_order => MsgOrder,
                                                  links => Links,
                                                  s_group_info => SgInfo,
                                                  sync_repaired => element(1, Repaired)})),
            io:format("captured Q1 at step ~p ~P; lagging ~p~n",
                      [K, Call, 8, [{Nd, length(Ms)} || {Nd, _, Ms} <- Lag]]),
            ok
    end.

run_calls([], _M, _Maps, _K) -> ok;
run_calls([{call, sd_pbt_statem, F, Args} = Call | Rest], M, Maps, K) ->
    %% Snapshot every node's global state before each command (kept only for
    %% the failing step): did knowledge exist before and get lost, or never form?
    put(before_states, [{N, rpc:call(N, sys, get_state, [global_name_server, 5000], 8000)}
                        || N <- sd_pbt_cluster:sut_nodes()]),
    _ = apply(sd_pbt_statem, F, Args),
    {M1, _} = sd_pbt_impl:step(M, F, Args),
    case sd_pbt_obs:await_conformance(M1, Maps, 10000) of
        {ok, _} ->
            put(last_model, M1),
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

%% Receive-trace global_name_server on this node, keeping only the message
%% types that decide sync ordering, as {MonotonicMs, Tag, Peer/Group}.
msg_tracer_start() ->
    case whereis(sd_q1_msg_tracer) of
        undefined -> ok;
        Old -> exit(Old, kill)
    end,
    Gns = whereis(global_name_server),
    Sg = whereis(s_group),
    T0 = erlang:monotonic_time(millisecond),
    P = spawn(fun() ->
                      erlang:trace(Gns, true, ['receive']),
                      %% Q4: also s_group's receives, to see whether a synthetic
                      %% {nodeup, Peer} overtakes {disconnect_node, Peer}.
                      erlang:trace(Sg, true, ['receive']),
                      %% Q4: decisions between nodeup_s and lock_is_set.
                      erlang:trace(Gns, true, [call]),
                      Ret = [{'_', [], [{return_trace}]}],
                      _ = erlang:trace_pattern({global, handle_node_up_s, '_'}, Ret, [local]),
                      _ = erlang:trace_pattern({global, isknown_nodeup, '_'}, Ret, [local]),
                      _ = erlang:trace_pattern({global, cancel_locker, '_'}, true, [local]),
                      msg_loop(T0, [])
              end),
    register(sd_q1_msg_tracer, P),
    ok.

msg_tracer_dump() ->
    sd_q1_msg_tracer ! {dump, self()},
    receive {msg_dump, L} -> L after 3000 -> timeout end.

msg_loop(T0, Acc) ->
    receive
        {dump, From} ->
            From ! {msg_dump, lists:reverse(Acc)},
            msg_loop(T0, Acc);
        {trace, _, call, {global, F, Args}} ->
            T = erlang:monotonic_time(millisecond) - T0,
            msg_loop(T0, lists:sublist([{T, {call, F, call_peer(F, Args)}} | Acc], 2000));
        {trace, _, return_from, {global, F, _Ar}, R} when F =/= handle_node_up_s ->
            T = erlang:monotonic_time(millisecond) - T0,
            msg_loop(T0, lists:sublist([{T, {return, F, R}} | Acc], 2000));
        {trace, _, return_from, _, _} ->
            msg_loop(T0, Acc);
        {trace, Who, 'receive', Msg} ->
            T = erlang:monotonic_time(millisecond) - T0,
            Acc1 = case classify_for(Who, Msg) of
                       skip -> Acc;
                       C -> lists:sublist([{T, C} | Acc], 2000)
                   end,
            msg_loop(T0, Acc1);
        _ ->
            msg_loop(T0, Acc)
    end.

%% s_group's mailbox: only the two messages whose order matters.
classify_for(Who, Msg) ->
    case Who =:= whereis(s_group) of
        true ->
            case Msg of
                {nodeup, N} -> {sg_nodeup, N};
                {disconnect_node, N} -> {sg_disconnect_node, N};
                _ -> skip
            end;
        false ->
            classify(Msg)
    end.

classify({nodeup_s, Groups, N}) -> {nodeup_s, N, Groups};   %% s_group -> global forwarding
classify({nodeup, N}) -> {nodeup, N};
classify({nodeup, G, N}) -> {nodeup, G, N};
classify({nodedown, N}) -> {nodedown, N};
classify({own_s_group_update, G, _}) -> {own_s_group_update, G};
classify({own_s_group_remove, G, _, _}) -> {own_s_group_remove, G};
classify({own_s_group_delete, G}) -> {own_s_group_delete, G};
classify({init_own_s_groups, Gs}) -> {init_own_s_groups, [G || {G, _} <- Gs]};
classify({'$gen_cast', Cast}) when is_tuple(Cast) ->
    Tag = element(1, Cast),
    case lists:member(Tag, [init_connect, init_connect_s, exchange, exchange_s, exchange_ops,
                            exchange_ops_s, resolved, resolved_s, lock_is_set, new_nodes,
                            new_nodes_s, in_sync, async_disconnect]) of
        true -> {Tag, peer_of(Cast)};
        false -> skip
    end;
classify(_) -> skip.

peer_of(Cast) ->
    case [X || X <- tuple_to_list(Cast), is_atom(X), lists:member($@, atom_to_list(X))] of
        [P | _] -> P;
        [] -> none
    end.

sd_pbt_impl_model() -> get(last_model).

call_peer(isknown_nodeup, [Groups, Node | _]) -> {Node, Groups};
call_peer(cancel_locker, [Node | _]) -> Node;
call_peer(handle_node_up_s, Args) ->
    case [A || A <- Args, is_atom(A), lists:member($@, atom_to_list(A))] of
        [N | _] -> N;
        [] -> none
    end;
call_peer(_, _) -> none.
