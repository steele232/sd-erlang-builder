%% Reproducer for the 19.3 boot-registration name divergence.
%%
%% Expects the 15 nodes booted with {sd_demo, registration, boot}, so every
%% service registers its group-scoped name before its node has joined the
%% group. Waits for membership and links to converge, then gives names a
%% further settle window and reports, per name, the group members that never
%% learned it. Observational: returns {consistent, _} or {diverged, Missing}.
-module(sd15_repro).

-export([boot_registration/0]).

-define(N(Short), list_to_atom(Short ++ "@" ++ Short ++ ".sd.lab")).
-define(SETTLE_MS, 20000).

boot_registration() ->
    Names = [{local_ai, worker_pool}, {edge_ai, worker_pool},
             {external_ai, worker_pool}, {control, router_a}, {control, router_b}],
    {ok, [Config]} = file:consult("/demo/config/sd15.config"),
    Groups = proplists:get_value(s_groups, proplists:get_value(kernel, Config)),
    Members = fun(G) -> hd([Ns || {G1, normal, Ns} <- Groups, G1 =:= G]) end,
    All = lists:usort(lists:append([Ns || {_, normal, Ns} <- Groups])),
    sd_demo_check:await("all nodes up and every service registered on its own node",
          fun() ->
                  [N || N <- All, net_adm:ping(N) =/= pong] =:= [] andalso
                      lists:all(fun({G, Name}) ->
                                        lists:any(fun(N) -> is_pid(rpc:call(N, s_group, whereis_name, [G, Name])) end,
                                                  Members(G))
                                end, Names)
          end, 60000),
    timer:sleep(?SETTLE_MS),
    Missing = [{G, Name, Ns}
               || {G, Name} <- Names,
                  Ns <- [[N || N <- Members(G),
                               not is_pid(rpc:call(N, s_group, whereis_name, [G, Name]))]],
                  Ns =/= []],
    Result = case Missing of
                 [] -> {consistent, ?SETTLE_MS};
                 _ -> {diverged, Missing}
             end,
    io:format("boot-registration result after ~p ms settle: ~p~n", [?SETTLE_MS, Result]),
    Result.
