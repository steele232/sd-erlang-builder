#!/usr/bin/env escript
%% L2 triage: first divergence per sequence (return value or which keys).
%%   [L2_KEYS=k1,k2] escript test/pbt/sd_l2_why.escript CANDIDATE GOLDEN...
%% For each sequence: the first step at which the candidate leaves the set of
%% reference prefixes, and what differs there (return value and/or which keys).
main([Cand | Golds]) ->
    Keys = case os:getenv("L2_KEYS") of
               false -> all;
               "" -> all;
               KS -> [list_to_atom(K) || K <- string:tokens(KS, ",")]
           end,
    Proj = fun(all, T) -> T;
              (Ks, T) -> [{Cm, V, maps:map(fun(_, M) -> maps:with(Ks, M) end, O)} || {Cm, V, O} <- T]
           end,
    {ok, [#{traces := C0}]} = file:consult(Cand),
    C = [Proj(Keys, T) || T <- C0],
    Gs = [begin {ok, [#{traces := T}]} = file:consult(F), [Proj(Keys, X) || X <- T] end || F <- Golds],
    Sh = fun(X) -> re:replace(io_lib:format("~0p", [X]), "@pbt.sd.lab", "", [global, {return, list}]) end,
    Rows = [classify(I, Ct, [lists:nth(I, G) || G <- Gs]) || {I, Ct} <- lists:zip(lists:seq(1, length(C)), C)],
    Tally = lists:foldl(fun({_, K, _, _}, A) -> maps:update_with(K, fun(N) -> N + 1 end, 1, A) end, #{}, Rows),
    io:format("first-divergence kinds: ~p~n", [Tally]),
    [io:format("seq ~2w step ~2w ~-40s ~s~n", [I, St, Sh(K), lists:sublist(Sh(D), 230)]) || {I, K, St, D} <- Rows, K =/= inside].

classify(I, Ct, Refs) ->
    case lists:member(Ct, Refs) of
        true -> {I, inside, 0, ""};
        false -> first(I, Ct, Refs, 1)
    end.

first(I, [{Cmd, V, O} | Rest], Refs, St) ->
    Heads = [hd(R) || R <- Refs, R =/= []],
    case lists:member({Cmd, V, O}, Heads) of
        true -> first(I, Rest, [tl(R) || R <- Refs, R =/= [], hd(R) =:= {Cmd, V, O}], St + 1);
        false ->
            {_, RV, RO} = hd(Heads),
            RetDiff = not lists:member(V, [V2 || {_, V2, _} <- Heads]),
            Keys = lists:usort([K || {_, _, O2} <- Heads, N <- maps:keys(O), K <- maps:keys(maps:get(N, O)),
                                     maps:get(K, maps:get(N, O)) =/= maps:get(K, maps:get(N, O2))]),
            AllKeysDiff = [K || K <- Keys, lists:all(fun({_, _, O2}) -> lists:any(fun(N) -> maps:get(K, maps:get(N, O)) =/= maps:get(K, maps:get(N, O2)) end, maps:keys(O)) end, Heads)],
            Kind = {element(1, Cmd), case RetDiff of true -> ret; false -> obs end, AllKeysDiff},
            {I, Kind, St, case RetDiff of true -> {Cmd, {cand, V}, {ref, RV}}; false -> {Cmd, AllKeysDiff, RO =:= RO} end}
    end.

