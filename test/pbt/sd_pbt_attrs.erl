%% P17 attribute-based selection (JPDC'16 sec. 3, semi-explicit placement):
%% s_group:choose_nodes([{attribute, A}]) should return the connected nodes
%% that carry attribute A.
%%
%% Prediction from the 19.3 source: s_group:add_attributes/1 stores attributes
%% in s_group's state, but choose_nodes/1 reads global:registered_attributes/0
%% (global keeps a separate store, written by global:add_attribute/1). So
%% attributes added through the documented s_group API are invisible to
%% selection.
%%
%%   sd_pbt_attrs:run()
-module(sd_pbt_attrs).

-export([run/0]).

run() ->
    _ = (try ets:new(sd_pbt, [named_table, public, set]) catch _:_ -> ok end),
    ok = sd_pbt_cluster:reset(),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    {N1, N2, N3} = {N("n1"), N("n2"), N("n3")},
    {ok, g1, _} = rpc:call(N1, s_group, new_s_group, [g1, [N1, N2, N3]]),
    timer:sleep(1500),
    R1 = rpc:call(N2, s_group, add_attributes, [[gpu]]),
    timer:sleep(500),
    ViaSGroup = rpc:call(N1, s_group, choose_nodes, [[{attribute, gpu}]]),
    SGroupStore = rpc:call(N2, s_group, registered_attributes, []),
    GlobalStore = rpc:call(N2, global, registered_attributes, []),
    R2 = rpc:call(N3, global, add_attribute, [[gpu]]),
    timer:sleep(500),
    ViaGlobal = rpc:call(N1, s_group, choose_nodes, [[{attribute, gpu}]]),
    io:format("P17 s_group:add_attributes([gpu]) on n2 -> ~p~n"
              "    n2 s_group store ~p, n2 global store ~p~n"
              "    choose_nodes([{attribute,gpu}]) from n1 -> ~p~n"
              "    after global:add_attribute([gpu]) on n3 (~p): choose_nodes -> ~p~n"
              "    ~s~n",
              [R1, SGroupStore, GlobalStore, ViaSGroup, R2, ViaGlobal,
               case lists:member(N2, flat(ViaSGroup)) of
                   true -> "CONFORMS (s_group attributes visible to selection)";
                   false -> "DIVERGES: attributes added via s_group:add_attributes/1 are invisible to choose_nodes/1"
               end]),
    ok.

flat(L) when is_list(L) -> lists:flatten(L);
flat(_) -> [].
