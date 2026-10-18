%% POP1 acceptance scenario (decision D-5): a real pairwise partition inside
%% one group, then a heal. Driven step by step by bin/sd-pop, which cuts and
%% restores the a<->x link with iptables between the steps.
%%
%%   g1 = {a, r, x}   the partitioned group (r keeps both links)
%%   g2 = {x, y}      must be unaffected (P8 / Collateral)
-module(sd_pop).
-export([setup/0, split_register/0, split_register_rev/0, check_g2/0, heal/0, check_converged/0, state/0]).

-define(N(X), list_to_atom(atom_to_list(X) ++ "@" ++ atom_to_list(X) ++ ".pop.lab")).
-define(WAIT_MS, 30000).

setup() ->
    [A, R, X, Y] = [?N(a), ?N(r), ?N(x), ?N(y)],
    {ok, g1, _} = rpc:call(A, s_group, new_s_group, [g1, [A, R, X]]),
    {ok, g2, _} = rpc:call(X, s_group, new_s_group, [g2, [X, Y]]),
    ok = await("g1 and g2 meshed", fun() ->
                   lists:member(X, rpc:call(A, erlang, nodes, [])) andalso
                   lists:member(Y, rpc:call(X, erlang, nodes, []))
           end),
    ok.

%% Precondition (checked here): a and x no longer see each other.
%% split_register/0 registers on a first, split_register_rev/0 on x first:
%% the last writer is what r ends up with during the partition.
split_register() -> split_register([a, x]).
split_register_rev() -> split_register([x, a]).

split_register(Order) ->
    [A, X] = [?N(a), ?N(x)],
    ok = await("a and x see the cut", fun() ->
                   not lists:member(X, rpc:call(A, erlang, nodes, [])) andalso
                   not lists:member(A, rpc:call(X, erlang, nodes, []))
           end),
    PA = rpc:call(A, erlang, spawn, [timer, sleep, [infinity]]),
    PX = rpc:call(X, erlang, spawn, [timer, sleep, [infinity]]),
    Reg = fun(a) -> rpc:call(A, s_group, register_name, [g1, n, PA]);
             (x) -> rpc:call(X, s_group, register_name, [g1, n, PX])
          end,
    [R1, R2] = [Reg(W) || W <- Order],
    {RA, RX} = case Order of [a, x] -> {R1, R2}; [x, a] -> {R2, R1} end,
    io:format("register on a: ~p (pid on a ~p), on x: ~p (pid on x ~p)~n", [RA, PA, RX, PX]),
    io:format("tables right after: ~p~n", [state()]),
    ok.

check_g2() ->
    [X, Y] = [?N(x), ?N(y)],
    P = rpc:call(Y, erlang, spawn, [timer, sleep, [infinity]]),
    yes = rpc:call(Y, s_group, register_name, [g2, m, P]),
    await("g2 name m on both members", fun() ->
              rpc:call(X, s_group, whereis_name, [g2, m]) =:= P andalso
              rpc:call(Y, s_group, whereis_name, [g2, m]) =:= P
          end).

%% The iptables rules are already gone; re-dial as an application or a
%% libcluster strategy would (decision RC1: no re-dial in the kernel).
heal() ->
    [A, X] = [?N(a), ?N(x)],
    true = rpc:call(A, s_group, connect_node, [X]),
    ok.

check_converged() ->
    Members = [?N(a), ?N(r), ?N(x)],
    Res = await("g1 converged: one pid for n, alive, same on every member, one name per pid",
                fun() ->
                        Views = [rpc:call(M, s_group, whereis_name, [g1, n]) || M <- Members],
                        Tables = [lists:sort(rpc:call(M, s_group, registered_names, [{s_group, g1}]))
                                  || M <- Members],
                        case lists:usort(Views) of
                            [P] when is_pid(P) ->
                                rpc:call(node(P), erlang, is_process_alive, [P]) =:= true
                                    andalso length(lists:usort(Tables)) =:= 1;
                            _ -> false
                        end
                end),
    io:format("~p~n", [state()]),
    Res.

state() ->
    [{M, case rpc:call(M, s_group, whereis_name, [g1, n]) of
             P when is_pid(P) -> {node(P), P};
             Other -> Other
         end,
      rpc:call(M, s_group, registered_names, [{s_group, g1}]),
      lists:sort(rpc:call(M, erlang, nodes, []))}
     || M <- [?N(a), ?N(r), ?N(x)]].

await(What, F) ->
    Deadline = erlang:monotonic_time(millisecond) + ?WAIT_MS,
    await(What, F, Deadline).
await(What, F, Deadline) ->
    case catch F() of
        true -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> io:format("TIMEOUT: ~s~n", [What]), {timeout, What};
                false -> timer:sleep(200), await(What, F, Deadline)
            end
    end.
