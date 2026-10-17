%% P14 restart recovery (S8, D3.3 ch. 2): with -rsconfig, every membership
%% change makes a node write <node>.config to its cwd; restarting the node with
%% -config <that file> restores its memberships.
%%
%% Prediction from s_group.erl record_state/0: the file is only rewritten if
%% its mtime is strictly older than the change time, both with 1 s resolution,
%% so a second change within the same second is NOT persisted.
%%
%%   sd_pbt_rsconfig:run(Trials)
-module(sd_pbt_rsconfig).

-include("sd_compat.hrl").

-export([run/1]).

-define(DIR, "/tmp/rs").
-define(HOST, "pbt.sd.lab").

run(Trials) ->
    [report(Spacing, [trial(Spacing) || _ <- lists:seq(1, Trials)]) || Spacing <- [0, 2000]],
    ok.

report(Spacing, Results) ->
    Ok = length([x || {recovered, _} <- Results]),
    io:format("rsconfig, ~p ms between the two changes: ~p/~p restarts recovered the latest membership~n",
              [Spacing, Ok, length(Results)]),
    [io:format("    ~p~n", [R]) || R <- lists:usort([R || R <- Results, element(1, R) =/= recovered])].

trial(SpacingMs) ->
    [R1, R2, R3] = Nodes = [node_name(X) || X <- ["r1", "r2", "r3"]],
    stop_all(Nodes),
    _ = os:cmd("rm -rf " ++ ?DIR ++ " && mkdir -p " ++ ?DIR),
    [launch(N, "-rsconfig") || N <- Nodes],
    ok = wait(fun() -> [N || N <- Nodes, net_adm:ping(N) =/= pong] =:= [] end, 20000),
    {ok, ga, _} = rpc:call(R1, s_group, new_s_group, [ga, [R1, R2]]),
    timer:sleep(SpacingMs),
    {ok, ga, _} = rpc:call(R1, s_group, add_nodes, [ga, [R3]]),
    Want = lists:sort([R1, R2, R3]),
    ok = wait(fun() -> own(R2) =:= [{ga, Want}] end, 10000),
    timer:sleep(1500),
    File = ?DIR ++ "/" ++ atom_to_list(R2) ++ ".config",
    Persisted = case file:consult(File) of
                    {ok, [[{kernel, [{s_groups, G}]}]]} -> lists:sort([{Gn, lists:sort(Ns)} || {Gn, _, Ns} <- G]);
                    Other -> {unreadable, Other}
                end,
    %% Restart r2 from its persisted file.
    rpc:cast(R2, erlang, halt, []),
    ok = wait(fun() -> net_adm:ping(R2) =:= pang end, 10000),
    launch(R2, "-rsconfig -config " ++ filename:rootname(File)),
    ok = wait(fun() -> net_adm:ping(R2) =:= pong end, 20000),
    timer:sleep(1000),
    After = own(R2),
    stop_all(Nodes),
    case After of
        [{ga, Want}] -> {recovered, Persisted};
        _ -> {stale, #{persisted => short(Persisted), after_restart => short(After)}}
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

short(T) -> T.

wait(Fun, Ms) when Ms =< 0 -> case ?CATCH(Fun()) of true -> ok; _ -> timeout end;
wait(Fun, Ms) -> case ?CATCH(Fun()) of true -> ok; _ -> timer:sleep(100), wait(Fun, Ms - 100) end.
