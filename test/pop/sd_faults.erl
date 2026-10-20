%% Fault-injection steps for bin/sd-faults (hardening phase: flapping links,
%% simultaneous partitions, restarts during merges, cold start, soak).
%% Nodes a, r, x, y run with -rsconfig; groups g1 = {a, r, x}, g2 = {x, y}.
%% The script cuts and heals links with iptables and restarts containers
%% between the steps.
-module(sd_faults).
-export([setup/0, reg/3, check_all/0, redial/1, wait_up/1, wait_cut/1, groups_ok/0]).

-define(N(X), list_to_atom(atom_to_list(X) ++ "@" ++ atom_to_list(X) ++ ".pop.lab")).
-define(WAIT_MS, 40000).
-define(G1, [a, r, x]).
-define(G2, [x, y]).

setup() ->
    [A, R, X, Y] = [?N(a), ?N(r), ?N(x), ?N(y)],
    {ok, g1, _} = rpc:call(A, s_group, new_s_group, [g1, [A, R, X]]),
    {ok, g2, _} = rpc:call(X, s_group, new_s_group, [g2, [X, Y]]),
    await("groups formed", fun() -> groups_ok() =:= ok end).

%% Register Name in G for a fresh process on node At (from At).
reg(At, G, Name) ->
    N = ?N(At),
    P = rpc:call(N, erlang, spawn, [timer, sleep, [infinity]]),
    R = rpc:call(N, s_group, register_name, [G, Name, P]),
    io:format("reg ~p ~p ~p on ~p: ~p~n", [G, Name, P, At, R]),
    ok.

%% Re-dial after a heal, as an application or libcluster would (RC1).
redial(Pairs) ->
    [true = rpc:call(?N(P), s_group, connect_node, [?N(Q)]) || {P, Q} <- Pairs],
    ok.

wait_cut(Pairs) ->
    await("cuts seen", fun() ->
              lists:all(fun({P, Q}) -> not lists:member(?N(Q), rpc:call(?N(P), erlang, nodes, [])) end, Pairs)
          end).

wait_up(Node) ->
    await("node up", fun() -> net_adm:ping(?N(Node)) =:= pong end).

%% Memberships as created, on every member.
groups_ok() ->
    Want = #{a => [g1], r => [g1], x => [g1, g2], y => [g2]},
    Ok = lists:all(fun({Nd, Gs}) ->
                           Own = rpc:call(?N(Nd), s_group, own_s_groups, []),
                           is_list(Own) andalso lists:sort([G || {G, _} <- Own]) =:= Gs andalso
                               lists:all(fun({G, Ms}) -> lists:sort(Ms) =:= members(G) end, Own)
                   end, maps:to_list(Want)),
    case Ok of true -> ok; false -> not_yet end.

members(g1) -> lists:sort([?N(X) || X <- ?G1]);
members(g2) -> lists:sort([?N(X) || X <- ?G2]).

%% Convergence after faults: memberships as created; per group, every member
%% holds the same table; every registered pid is alive; one name per pid.
check_all() ->
    R = await("converged", fun() -> converged() =:= ok end),
    io:format("state: ~p~n", [state()]),
    R.

converged() ->
    case groups_ok() of
        ok ->
            Ok = lists:all(fun(G) ->
                                   Tables = [lists:sort([{Nm, rpc:call(M, s_group, whereis_name, [G, Nm])}
                                                         || {_, Nm} <- rpc:call(M, s_group, registered_names, [{s_group, G}])])
                                             || M <- members(G)],
                                   case lists:usort(Tables) of
                                       [T] ->
                                           Pids = [P || {_, P} <- T],
                                           lists:all(fun(P) -> is_pid(P) andalso
                                                                   rpc:call(node(P), erlang, is_process_alive, [P]) =:= true
                                                     end, Pids)
                                               andalso length(Pids) =:= length(lists:usort(Pids));
                                       _ -> false
                                   end
                           end, [g1, g2]),
            case Ok of true -> ok; false -> not_yet end;
        Other -> Other
    end.

state() ->
    [{G, [{M, lists:sort(rpc:call(M, s_group, registered_names, [{s_group, G}]))} || M <- members(G)]}
     || G <- [g1, g2]].

await(What, F) ->
    Deadline = erlang:monotonic_time(millisecond) + ?WAIT_MS,
    await(What, F, Deadline).
await(What, F, Deadline) ->
    case (try F() catch _:_ -> error end) of
        R when R =:= true; R =:= ok -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> io:format("TIMEOUT: ~s~n", [What]), {timeout, What};
                false -> timer:sleep(250), await(What, F, Deadline)
            end
    end.
