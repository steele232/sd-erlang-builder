%% P15 duplicate s_group names at launch (S7, D3.3 ch. 3.1):
%%  "In case all s_groups that have the same name are identical we create a
%%   single s_group; otherwise we check whether any of these s_groups contain
%%   the current node. In case the s_groups that have the same name are remote
%%   we keep a record of no s_group with that name. In case the current node
%%   is a member of at least one s_group an error is returned and the node
%%   terminates."
%%
%%   sd_pbt_dupnames:run()
-module(sd_pbt_dupnames).

-include("sd_compat.hrl").

-export([run/0]).

-define(DIR, "/tmp/dn").
-define(HOST, "pbt.sd.lab").

run() ->
    D = fun(X) -> list_to_atom(X ++ "@" ++ ?HOST) end,
    Cases =
        [{identical_duplicates_merge,
          [{g1, normal, [D("d1"), D("d2")]}, {g1, normal, [D("d1"), D("d2")]}],
          {member, [{g1, [D("d1"), D("d2")]}]}},
         {conflicting_duplicates_with_self_terminate,
          [{g1, normal, [D("d1"), D("d2")]}, {g1, normal, [D("d1"), D("d3")]}],
          terminated},
         {conflicting_remote_duplicates_ignored,
          [{g2, normal, [D("d1"), D("d2")]},
           {g1, normal, [D("d3"), D("d4")]}, {g1, normal, [D("d3"), D("d5")]}],
          {member_no_remote_record, [{g2, [D("d1"), D("d2")]}], g1}}],
    Results = [{Name, Want, run_case(Name, Groups)} || {Name, Groups, Want} <- Cases],
    [io:format("P15 ~p:~n    D3.3 expects ~p~n    19.3 gives   ~p~n    ~s~n",
               [Name, Want, Got, verdict(Want, Got)])
     || {Name, Want, Got} <- Results],
    ok.

run_case(Name, Groups) ->
    D1 = list_to_atom("d1@" ++ ?HOST),
    rpc:cast(D1, erlang, halt, []),
    _ = wait(fun() -> net_adm:ping(D1) =:= pang end, 10000),
    _ = os:cmd("rm -rf " ++ ?DIR ++ " && mkdir -p " ++ ?DIR),
    Cfg = ?DIR ++ "/" ++ atom_to_list(Name),
    ok = file:write_file(Cfg ++ ".config",
                         io_lib:format("~p.~n", [[{kernel, [{s_groups, Groups}]}]])),
    _ = os:cmd("cd " ++ ?DIR ++ " && erl -detached -noshell -name d1@" ++ ?HOST ++
               " -pa /pbt/ebin -config " ++ Cfg),
    Up = wait(fun() -> net_adm:ping(D1) =:= pong end, 8000),
    timer:sleep(1500),
    Result = case {Up, net_adm:ping(D1)} of
                 {ok, pong} ->
                     Own = lists:sort([{G, lists:sort(Ns)} || {G, Ns} <- rpc:call(D1, s_group, own_s_groups, [])]),
                     {_OwnNames, Other} = rpc:call(D1, s_group, s_groups, []),
                     {member, Own, {other_groups, lists:sort(Other)}};
                 _ ->
                     terminated
             end,
    rpc:cast(D1, erlang, halt, []),
    Result.

verdict(terminated, terminated) -> "CONFORMS";
verdict({member, Own}, {member, Own, _}) -> "CONFORMS";
verdict({member_no_remote_record, Own, G}, {member, Own, {other_groups, Other}}) ->
    case lists:member(G, Other) of
        false -> "CONFORMS";
        true -> "DIVERGES (remote duplicate kept)"
    end;
verdict(_, _) -> "DIVERGES".

wait(Fun, Ms) when Ms =< 0 -> case ?CATCH(Fun()) of true -> ok; _ -> timeout end;
wait(Fun, Ms) -> case ?CATCH(Fun()) of true -> ok; _ -> timer:sleep(200), wait(Fun, Ms - 200) end.
