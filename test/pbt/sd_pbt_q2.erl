%% Deterministic reproducer for deviation Q2: removing a node from one group
%% breaks global's knowledge of it in another, overlapping group.
%%
%% g1 = {A, B, C}, g2 = {B, C}. A runs remove_nodes(g1, [C]). B runs
%% remove_nodes_check, whose disconnect_nodes([C]) is unconditional, so B's
%% global forgets C, including for g2, which B and C still share.
-module(sd_pbt_q2).

-export([run/1]).

run(Trials) ->
    R = [trial() || _ <- lists:seq(1, Trials)],
    io:format("~nQ2: ~p/~p trials lost g2 knowledge after remove_nodes(g1)~n",
              [length([x || {lost, _} <- R]), Trials]),
    [io:format("  ~p~n", [X]) || X <- lists:usort(R)],
    ok.

trial() ->
    ok = sd_pbt_cluster:reset(),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    {A, B, C} = {N("n1"), N("n2"), N("n3")},
    {ok, g1, _} = rpc:call(A, s_group, new_s_group, [g1, [A, B, C]]),
    {ok, g2, _} = rpc:call(B, s_group, new_s_group, [g2, [B, C]]),
    ok = settle(fun() -> known(B, g2) =:= [C] andalso known(C, g2) =:= [B]
                             andalso length(known(A, g1)) =:= 2 end, 10000),
    ok = rpc:call(A, s_group, remove_nodes, [g1, [C]]),
    timer:sleep(3000),
    G2 = {known(B, g2), known(C, g2)},
    case G2 of
        {[C], [B]} -> {kept, G2};
        _ -> {lost, #{b_knows_in_g2 => element(1, G2), c_knows_in_g2 => element(2, G2),
                      b_groups => rpc:call(B, s_group, own_s_groups, []),
                      b_c_connected => lists:member(C, rpc:call(B, erlang, nodes, [connected]))}}
    end.

known(N, G) -> lists:sort(rpc:call(N, global, get_known_s_group, [G])).

settle(Fun, Ms) when Ms =< 0 -> case Fun() of true -> ok; false -> timeout end;
settle(Fun, Ms) -> case Fun() of true -> ok; false -> timer:sleep(100), settle(Fun, Ms - 100) end.
