%% Decisions D-7/D-8 at runtime: a node that was down while its group changed
%% must not resurrect its stale membership on restart (the current members
%% win). Nodes r1..r3 run in the harness container (like sd_pbt_rsconfig).
%%
%%   removed_rsconfig  r3 down; r1 removes r3; r3 restarts from its -rsconfig record
%%   removed_static    r3 down; r1 removes r3; r3 restarts from the launch config
%%   deleted_rsconfig  r3 down; r1 deletes the group; r3 restarts from its record
%%
%% Pass: after the restart r3 is in no group, and r1/r2 still hold the group
%% they had (or none, after the delete).
%%   sd_pbt_rejoin:run()
-module(sd_pbt_rejoin).

-include("sd_compat.hrl").

-export([run/0]).

-define(DIR, "/tmp/rj").
-define(HOST, "pbt.sd.lab").

run() ->
    Rs = [{C, ?CATCH(trial(C))} || C <- [removed_rsconfig, removed_static, deleted_rsconfig]],
    [io:format("rejoin ~-17s ~p~n", [C, R]) || {C, R} <- Rs],
    Bad = [C || {C, R} <- Rs, R =/= pass],
    io:format("REJOIN RESULT: ~s~n", [case Bad of [] -> "pass"; _ -> io_lib:format("FAIL ~p", [Bad]) end]),
    ok.

trial(Case) ->
    [R1, R2, R3] = Nodes = [node_name(X) || X <- ["r1", "r2", "r3"]],
    stop_all(Nodes),
    _ = os:cmd("rm -rf " ++ ?DIR ++ " && mkdir -p " ++ ?DIR),
    Static = ?DIR ++ "/static",
    ok = file:write_file(Static ++ ".config",
                         io_lib:format("~p.~n", [[{kernel, [{s_groups, [{g, normal, lists:sort(Nodes)}]}]}]])),
    Extra = case Case of
                removed_static -> "-config " ++ Static;
                _ -> "-rsconfig"
            end,
    [launch(N, Extra) || N <- Nodes],
    ok = wait(fun() -> [N || N <- Nodes, net_adm:ping(N) =/= pong] =:= [] end, 20000),
    _ = case Case of
            removed_static -> ok;
            _ -> {ok, g, _} = rpc:call(R1, s_group, new_s_group, [g, Nodes])
        end,
    Want0 = lists:sort(Nodes),
    ok = wait(fun() -> own(R3) =:= [{g, Want0}] andalso own(R1) =:= [{g, Want0}] end, 15000),
    timer:sleep(1000),
    %% r3 goes down; the group changes without it.
    rpc:cast(R3, erlang, halt, []),
    ok = wait(fun() -> net_adm:ping(R3) =:= pang end, 10000),
    ok = wait(fun() -> not lists:member(R3, rpc:call(R1, erlang, nodes, [])) end, 15000),
    Survivors = case Case of
                    deleted_rsconfig ->
                        ok = rpc:call(R1, s_group, delete_s_group, [g]),
                        [];
                    _ ->
                        ok = rpc:call(R1, s_group, remove_nodes, [g, [R3]]),
                        [{g, lists:sort([R1, R2])}]
                end,
    ok = wait(fun() -> own(R1) =:= Survivors andalso own(R2) =:= Survivors end, 10000),
    %% r3 restarts from what it remembers.
    Restart = case Case of
                  removed_static -> "-config " ++ Static;
                  _ -> "-rsconfig -config " ++ ?DIR ++ "/" ++ atom_to_list(R3)
              end,
    launch(R3, Restart),
    ok = wait(fun() -> net_adm:ping(R3) =:= pong end, 20000),
    _ = rpc:call(R3, net_kernel, connect_node, [R1]),
    Result = wait(fun() -> own(R3) =:= [] andalso own(R1) =:= Survivors
                               andalso own(R2) =:= Survivors end, 20000),
    Final = #{r3 => own(R3), r1 => own(R1), r2 => own(R2)},
    stop_all(Nodes),
    case Result of
        ok -> pass;
        timeout -> {stale_membership, Final}
    end.

own(N) ->
    case rpc:call(N, s_group, own_s_groups, []) of
        L when is_list(L) -> lists:sort([{G, lists:sort(Ns)} || {G, Ns} <- L]);
        O -> O
    end.

launch(Node, Extra) ->
    [Name, _] = string:tokens(atom_to_list(Node), "@"),
    _ = os:cmd("cd " ++ ?DIR ++ " && erl -detached -noshell -name " ++ Name ++ "@" ++ ?HOST ++
               " -pa /pbt/ebin " ++ Extra),
    ok.

stop_all(Nodes) ->
    [rpc:cast(N, erlang, halt, []) || N <- Nodes],
    _ = wait(fun() -> [N || N <- Nodes, net_adm:ping(N) =:= pong] =:= [] end, 10000),
    ok.

node_name(X) -> list_to_atom(X ++ "@" ++ ?HOST).

wait(Fun, Ms) when Ms =< 0 -> case ?CATCH(Fun()) of true -> ok; _ -> timeout end;
wait(Fun, Ms) -> case ?CATCH(Fun()) of true -> ok; _ -> timer:sleep(100), wait(Fun, Ms - 100) end.
