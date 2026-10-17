%% Q4 hypothesis: global starts a group sync only on nodeup. If members were
%% already connected (as free nodes) before global learns they share a new
%% group, no new nodeup occurs and they may never sync for that group.
-module(sd_pbt_q4).

-include("sd_compat.hrl").

-export([run/1]).

run(Trials) ->
    [report(V, [trial(V) || _ <- lists:seq(1, Trials)])
     || V <- [preconnected_normal_initiator, preconnected_hidden_initiator, unconnected_hidden_initiator]],
    ok.

report(V, R) ->
    io:format("Q4 ~p: ~p/~p trials left a member without group knowledge~n",
              [V, length([x || {stuck, _} <- R]), length(R)]),
    [io:format("    ~p~n", [X]) || X <- lists:usort([D || {stuck, D} <- R])].

trial(Variant) ->
    _ = ?CATCH(ets:new(sd_pbt, [named_table, public, set])),
    ok = sd_pbt_cluster:reset(),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    Members = lists:sort([N("n1"), N("n2"), N("n3"), N("h1")]),
    Pre = [N("n1"), N("n2"), N("n3")],
    case Variant of
        unconnected_hidden_initiator -> ok;
        _ -> [pong = rpc:call(A, net_adm, ping, [B]) || A <- Pre, B <- Pre, A < B],
             timer:sleep(2500)
    end,
    Init = case Variant of preconnected_normal_initiator -> N("n1"); _ -> N("h1") end,
    {ok, g3, _} = rpc:call(Init, s_group, new_s_group, [g3, Members]),
    ok = settle(fun() -> all_know(Members) end, 15000),
    case all_know(Members) of
        true -> ok;
        false -> {stuck, maps:from_list([{M, known(M)} || M <- Members])}
    end.

all_know(Members) ->
    lists:all(fun(M) -> known(M) =:= lists:sort(Members -- [M]) end, Members).

known(M) ->
    case rpc:call(M, global, get_known_s_group, [g3]) of
        L when is_list(L) -> lists:sort(L);
        O -> O
    end.

settle(Fun, Ms) when Ms =< 0 -> case Fun() of true -> ok; false -> ok end;
settle(Fun, Ms) -> case Fun() of true -> ok; false -> timer:sleep(200), settle(Fun, Ms - 200) end.
