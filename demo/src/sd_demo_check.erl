%% Shared step runner and assertion helpers for the demo scenarios.
%%
%%   await/2,3  eventual liveness: Fun must return true | {true, V} by a deadline
%%   never/2,3  immediate safety: Fun must stay false for a whole window
-module(sd_demo_check).

-export([run_steps/1, report/1, check/3,
         await/2, await/3, never/2, never/3, own_groups/1]).

-define(CONVERGE_MS, 15000).
-define(SAFETY_MS, 3000).

run_steps(Steps) ->
    lists:map(
      fun({Name, Fun}) ->
              io:format("~n== ~s~n", [Name]),
              T0 = erlang:monotonic_time(millisecond),
              Result = try Fun() of
                           {ok, Info} -> {pass, Info}
                       catch
                           Class:Reason ->
                               {fail, {Class, Reason, erlang:get_stacktrace()}}
                       end,
              Ms = erlang:monotonic_time(millisecond) - T0,
              case Result of
                  {pass, Inf} ->
                      [io:format("   ~p~n", [I]) || I <- Inf],
                      io:format("   PASS (~p ms)~n", [Ms]);
                  {fail, Why} ->
                      io:format("   FAIL (~p ms): ~p~n", [Ms, Why])
              end,
              {Name, element(1, Result)}
      end, Steps).

report(Results) ->
    Failed = [N || {N, fail} <- Results],
    io:format("~nSCENARIO RESULT: ~p/~p passed~n",
              [length(Results) - length(Failed), length(Results)]),
    case Failed of
        [] -> ok;
        _ -> {error, Failed}
    end.

own_groups(Node) ->
    case rpc:call(Node, s_group, own_s_groups, []) of
        Groups when is_list(Groups) ->
            lists:sort([{G, lists:sort(Ns)} || {G, Ns} <- Groups]);
        Other ->
            Other
    end.

check(Desc, Want, Got) ->
    case Want =:= Got of
        true -> ok;
        false -> erlang:error({check_failed, lists:flatten(Desc), {want, Want}, {got, Got}})
    end.

await(Desc, Fun) ->
    await(Desc, Fun, ?CONVERGE_MS).

await(Desc, Fun, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_loop(lists:flatten(Desc), Fun, Deadline).

await_loop(Desc, Fun, Deadline) ->
    case catch Fun() of
        true -> true;
        {true, V} -> V;
        Last ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> erlang:error({did_not_converge, Desc, {last, Last}});
                false -> timer:sleep(100), await_loop(Desc, Fun, Deadline)
            end
    end.

never(Desc, Fun) ->
    never(Desc, Fun, ?SAFETY_MS).

never(Desc, Fun, WindowMs) ->
    Deadline = erlang:monotonic_time(millisecond) + WindowMs,
    never_loop(lists:flatten(Desc), Fun, Deadline).

never_loop(Desc, Fun, Deadline) ->
    case Fun() of
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> ok;
                false -> timer:sleep(100), never_loop(Desc, Fun, Deadline)
            end;
        Other ->
            erlang:error({safety_violation, Desc, Other})
    end.
