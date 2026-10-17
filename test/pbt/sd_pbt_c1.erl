%% Reproducer attempts for deviation C1: global_name_server crashes in
%% resolved_s/6 (global.erl:3080, lists:unzip on a flat node list) when an
%% s_group node syncs with a free node. Each variant avoids making the hidden
%% driver a global peer (no delete_s_group, so no connect_free_nodes; H2).
-module(sd_pbt_c1).

-export([run/1]).

run(Trials) ->
    Variants = [{group_node_pings_free_pair, fun group_pings_free_pair/1, plain},
                {free_pair_pings_group_node, fun free_pings_group/1, plain},
                {hidden_member_pings_free_pair, fun hidden_pings_free/1, plain},
                {free_pair_pings_hidden_member, fun free_pings_hidden/1, plain},
                {group_node_pings_freed_pair, fun group_pings_free_pair/1, freed},
                {hidden_member_pings_freed_pair, fun hidden_pings_free/1, freed}],
    [begin
         R = [trial(F, How) || _ <- lists:seq(1, Trials)],
         io:format("C1 ~p: ~p/~p trials crashed global_name_server~n",
                   [Name, length([x || {crashed, _} <- R]), Trials]),
         [io:format("    ~p~n", [X]) || X <- lists:usort([D || {crashed, D} <- R])]
     end || {Name, F, How} <- Variants],
    ok.

%% How = plain: {n3,n4} are free from the start (driver not in their known).
%% How = freed: {n3,n4} become free via delete_s_group, so connect_free_nodes
%%              syncs them with every connected node, the hidden driver
%%              included (deviation H2).
trial(F, How) ->
    catch ets:new(sd_pbt, [named_table, public, set]),
    ok = sd_pbt_cluster:reset(),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    {ok, g1, _} = rpc:call(N("n1"), s_group, new_s_group, [g1, [N("n1"), N("n2"), N("h1")]]),
    case How of
        plain ->
            pong = rpc:call(N("n3"), net_adm, ping, [N("n4")]);
        freed ->
            {ok, g0, _} = rpc:call(N("n3"), s_group, new_s_group, [g0, [N("n3"), N("n4")]]),
            timer:sleep(1500),
            ok = rpc:call(N("n3"), s_group, delete_s_group, [g0])
    end,
    timer:sleep(2500),
    Before = gns_pids(N),
    F(N),
    timer:sleep(4000),
    After = gns_pids(N),
    Down = [Nd || Nd <- [N("n1"), N("n2"), N("h1"), N("n3"), N("n4")], net_adm:ping(Nd) =/= pong],
    Restarted = [Nd || {Nd, P} <- Before, lists:keyfind(Nd, 1, After) =/= {Nd, P}],
    case {Down, Restarted} of
        {[], []} -> ok;
        _ -> {crashed, #{down => Down, gns_restarted => Restarted}}
    end.

group_pings_free_pair(N) -> rpc:call(N("n1"), net_adm, ping, [N("n3")]).
free_pings_group(N) -> rpc:call(N("n3"), net_adm, ping, [N("n1")]).
hidden_pings_free(N) -> rpc:call(N("h1"), net_adm, ping, [N("n3")]).
free_pings_hidden(N) -> rpc:call(N("n3"), net_adm, ping, [N("h1")]).

gns_pids(N) ->
    [{Nd, rpc:call(Nd, erlang, whereis, [global_name_server])}
     || Nd <- [N("n1"), N("n2"), N("h1"), N("n3"), N("n4")]].
