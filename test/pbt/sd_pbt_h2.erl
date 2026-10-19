%% H2 / R-HID-1: free nodes never global-sync with hidden nodes (stock
%% semantics; JPDC'16: hidden connections are non-transitive).
%% {n1, n2} form g1 and delete it, so both become free; then global's known
%% nodes on n1, n2 and on the hidden driver must not include a hidden node.
%%   sd_pbt_h2:run()
-module(sd_pbt_h2).
-export([run/0]).

run() ->
    _ = (try ets:new(sd_pbt, [named_table, public, set]) catch _:_ -> ok end),
    ok = sd_pbt_cluster:reset(),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    {N1, N2} = {N("n1"), N("n2")},
    {ok, g1, _} = rpc:call(N1, s_group, new_s_group, [g1, [N1, N2]]),
    timer:sleep(1500),
    ok = rpc:call(N1, s_group, delete_s_group, [g1]),
    timer:sleep(4000),
    Known = fun(Node) ->
                    case rpc:call(Node, erlang, function_exported, [global, get_known, 0]) of
                        true -> lists:sort(rpc:call(Node, global, get_known, []));     % 19.3
                        _ -> known(rpc:call(Node, sys, get_state, [global_name_server]))
                    end
            end,
    R = [{node(), Known(node())}, {N1, Known(N1)}, {N2, Known(N2)}],
    Hidden = [node() | [H || H <- sd_pbt_cluster:sut_nodes(), lists:prefix("h", atom_to_list(H))]],
    Bad = [{Nd, K} || {Nd, K} <- R, is_list(K),
                      (lists:member(Nd, Hidden) andalso K =/= []) orelse
                      lists:any(fun(H) -> lists:member(H, K) end, Hidden)],
    io:format("H2 known: ~p~n~s~n", [R, case Bad of [] -> "CONFORMS (no hidden node in a free partition)";
                                                  _ -> io_lib:format("DIVERGES: ~p", [Bad]) end]),
    ok.

%% global's #state{} record: the known map is the field holding
%% {connection_id, Node} keys and plain node keys.
known(State) when is_tuple(State) ->
    Maps = [M || M <- tuple_to_list(State), is_map(M),
                 lists:any(fun({connection_id, _}) -> true; (_) -> false end, maps:keys(M))],
    case Maps of
        [M | _] -> lists:sort([K || K <- maps:keys(M), is_atom(K)]);
        [] -> []
    end;
known(Other) -> Other.
