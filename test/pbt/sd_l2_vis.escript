#!/usr/bin/env escript
%% L2 visibility triage for a port (O3/D-1 may_differ): at every step and node,
%% classify the candidate's visible links against EVERY reference recording.
%%   ok_d1     candidate visible = reference visible + links between nodes
%%             that share a group at that step (pre-existing links made
%%             visible, decision D-1)
%%   BAD_lost  a link visible in the reference is not visible in the candidate
%%   BAD_cross a candidate visible link joins nodes sharing no group, not both free (P1)
%%   escript test/pbt/sd_l2_vis.escript CANDIDATE GOLDEN...
main([Cand | Golds]) ->
    {ok, [#{traces := C}]} = file:consult(Cand),
    Gs = [begin {ok, [#{traces := T}]} = file:consult(F), T end || F <- Golds],
    Rows = [classify(I, lists:nth(I, C), [lists:nth(I, G) || G <- Gs]) || I <- lists:seq(1, length(C))],
    Tally = lists:foldl(fun({_, K}, A) -> maps:update_with(K, fun(N) -> N + 1 end, 1, A) end, #{}, Rows),
    io:format("per-sequence visibility verdicts: ~p~n", [Tally]),
    [io:format("  seq ~p: ~p~n", [I, K]) || {I, K} <- Rows, K =/= same, K =/= ok_d1].

classify(I, Ct, Refs) ->
    Vs = [verdict(Ct, R) || R <- Refs],
    {I, case lists:member(same, Vs) of
            true -> same;
            false -> case lists:member(ok_d1, Vs) of true -> ok_d1; false -> hd(lists:usort(Vs)) end
        end}.

verdict(Ct, Ref) ->
    Steps = lists:zip(Ct, Ref),
    Ks = [step_verdict(Oc, Or) || {{_, _, Oc}, {_, _, Or}} <- Steps],
    case lists:usort(Ks) of
        [same] -> same;
        L -> case [K || K <- L, K =/= same, K =/= ok_d1] of [] -> ok_d1; [B | _] -> B end
    end.

step_verdict(Oc, Or) ->
    Shares = fun(A, B) ->
                     Ga = groups(maps:get(A, Oc)), Gb = groups(maps:get(B, Oc)),
                     lists:any(fun(G) -> lists:member(G, Gb) end, Ga)
                         orelse (Ga =:= [] andalso Gb =:= [])          % free-free (S2)
             end,
    Ks = [begin
              Vc = maps:get(visible, maps:get(N, Oc)), Vr = maps:get(visible, maps:get(N, Or)),
              Extra = Vc -- Vr, Lost = Vr -- Vc,
              if Vc =:= Vr -> same;
                 Lost =/= [] -> 'BAD_lost';
                 true -> case lists:all(fun(M) -> Shares(N, M) end, Extra) of
                             true -> ok_d1;
                             false -> 'BAD_cross'
                         end
              end
          end || N <- maps:keys(Oc), is_list(maps:get(visible, maps:get(N, Oc))),
                 is_list(maps:get(visible, maps:get(N, Or)))],
    case [K || K <- Ks, K =/= same, K =/= ok_d1] of
        [] -> case lists:member(ok_d1, Ks) of true -> ok_d1; false -> same end;
        [B | _] -> B
    end.

groups(#{own_s_groups := L}) when is_list(L) -> [G || {G, _} <- L];
groups(_) -> [].
