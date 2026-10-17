%% Entry point for the model-conformance run (hidden driver node).
%%
%%   sd_pbt:run(NumTests)       quickcheck; on failure the shrunk counterexample
%%                              and run metadata go to /pbt/out/
%%   sd_pbt:replay(File)        re-run a stored counterexample
%%   sd_pbt:replay_stats(File, K)  replay K times; tally pass / failure kinds
%%                              (nondeterministic findings get a frequency)
%%   sd_pbt:campaign(Runs, N)   Runs independent quickchecks of N cases each,
%%                              no shrinking; tallies failure kinds. The tally
%%                              is the runtime's failure profile.
-module(sd_pbt).

-export([run/1, run/2, replay/1, replay_stats/2, campaign/2]).

-define(OUT, "/pbt/out").
-define(TAB, sd_pbt).

run(NumTests) ->
    run(NumTests, 25).

run(NumTests, MaxSize) ->
    setup(),
    T0 = erlang:monotonic_time(millisecond),
    Result = proper:quickcheck(sd_pbt_statem:prop_s_group(),
                               [{numtests, NumTests}, {max_size, MaxSize}, {to_file, user}]),
    Secs = (erlang:monotonic_time(millisecond) - T0) div 1000,
    summary(NumTests, Secs),
    case Result of
        true ->
            write_report(pass, NumTests, Secs, none),
            ok;
        _ ->
            CE = proper:counterexample(),
            File = write_report(fail, NumTests, Secs, CE),
            io:format("counterexample written to ~s~n", [File]),
            {error, File}
    end.

replay(File) ->
    setup(),
    {ok, [#{counterexample := CE}]} = file:consult(File),
    proper:check(sd_pbt_statem:prop_s_group(), CE, [{to_file, user}]).

campaign(Runs, NumTests) ->
    T0 = erlang:monotonic_time(millisecond),
    Outcomes =
        [begin
             setup(),
             R = proper:quickcheck(sd_pbt_statem:prop_s_group(),
                                   [{numtests, NumTests}, {max_size, 25}, noshrink, quiet]),
             case R of
                 true ->
                     io:format("run ~p/~p: pass~n", [I, Runs]),
                     pass;
                 _ ->
                     Kind = failure_kind(),
                     File = write_report(fail, NumTests, 0, proper:counterexample()),
                     io:format("run ~p/~p: ~p (~s)~n", [I, Runs, Kind, filename:basename(File)]),
                     Kind
             end
         end || I <- lists:seq(1, Runs)],
    Tally = lists:foldl(fun(O, Acc) -> maps:update_with(O, fun(C) -> C + 1 end, 1, Acc) end,
                        #{}, Outcomes),
    Secs = (erlang:monotonic_time(millisecond) - T0) div 1000,
    io:format("~ncampaign: ~p runs x ~p cases in ~p s~nfailure profile: ~p~n",
              [Runs, NumTests, Secs, Tally]),
    write_profile(Runs, NumTests, Secs, Tally),
    ok.

write_profile(Runs, NumTests, Secs, Tally) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    Stamp = lists:flatten(io_lib:format("~4..0w~2..0w~2..0wT~2..0w~2..0w~2..0wZ", [Y, Mo, D, H, Mi, S])),
    File = filename:join(?OUT, "profile-" ++ Stamp ++ ".eterm"),
    ok = file:write_file(File, io_lib:format("~p.~n",
             [#{runs => Runs, numtests => NumTests, seconds => Secs, profile => Tally,
                mode => os:getenv("SD_PBT_MODE", "quiescent"),
                otp_release => erlang:system_info(otp_release),
                sd_source_sha => source_sha(),
                runtime_image => os:getenv("SD_RUNTIME_IMAGE_ID", "unknown")}])),
    File.

replay_stats(File, K) ->
    {ok, [#{counterexample := CE}]} = file:consult(File),
    Outcomes = [begin
                    setup(),
                    R = proper:check(sd_pbt_statem:prop_s_group(), CE, [quiet]),
                    case R of
                        true -> pass;
                        _ -> failure_kind()
                    end
                end || _ <- lists:seq(1, K)],
    Tally = lists:foldl(fun(O, Acc) -> maps:update_with(O, fun(C) -> C + 1 end, 1, Acc) end,
                        #{}, Outcomes),
    io:format("replay_stats ~s x~p: ~p~n", [filename:basename(File), K, Tally]),
    ok.

failure_kind() ->
    case ets:lookup(?TAB, last_failure) of
        [{_, #{harness_error := E}}] -> {harness_error, element(1, E)};
        [{_, #{call := {call, _, F, _}, detail := {false, _, _}}}] -> {value_mismatch, F};
        [{_, #{call := {call, _, F, _}, detail := {_, {error, {not_quiescent, _}}, _}}}] -> {not_quiescent, F};
        [{_, #{call := {call, _, F, _}, detail := {_, {error, Diff}, _}}}] when is_list(Diff) ->
            {conformance, F, lists:usort([element(2, D) || D <- Diff])};
        [{_, #{call := {call, _, F, _}}}] -> {other, F};
        [] -> unknown
    end.

setup() ->
    case ets:info(?TAB) of
        undefined -> ets:new(?TAB, [named_table, public, set]);
        _ -> ets:delete_all_objects(?TAB)
    end,
    ok.

summary(NumTests, Secs) ->
    Lat = [{F, Ms} || {{latency, _}, F, Ms} <- ets:tab2list(?TAB)],
    ByOp = lists:foldl(fun({F, Ms}, Acc) -> maps:update_with(F, fun(L) -> [Ms | L] end, [Ms], Acc) end,
                       #{}, Lat),
    io:format("~n~p test cases in ~p s; convergence latency per operation (ms):~n", [NumTests, Secs]),
    [io:format("  ~s n=~w max=~w p50=~w~n",
               [F, length(L), lists:max(L), lists:nth(max(1, length(L) div 2), lists:sort(L))])
     || {F, L} <- lists:sort(maps:to_list(ByOp))],
    ok.

write_report(Verdict, NumTests, Secs, CE) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    Stamp = lists:flatten(io_lib:format("~4..0w~2..0w~2..0wT~2..0w~2..0w~2..0wZ", [Y, Mo, D, H, Mi, S])),
    File = filename:join(?OUT, "pbt-" ++ Stamp ++ "-" ++ atom_to_list(Verdict) ++ ".eterm"),
    Meta = #{verdict => Verdict,
             numtests => NumTests,
             seconds => Secs,
             otp_release => erlang:system_info(otp_release),
             sd_source_sha => source_sha(),
             runtime_image => os:getenv("SD_RUNTIME_IMAGE_ID", "unknown"),
             topology => sd_pbt_cluster:node_types(),
             last_failure => case ets:lookup(?TAB, last_failure) of [{_, F}] -> F; [] -> none end,
             counterexample => CE},
    ok = file:write_file(File, io_lib:format("~p.~n", [Meta])),
    File.

source_sha() ->
    case file:read_file("/opt/sd-erlang/SD_SOURCE_SHA") of
        {ok, B} -> string:strip(binary_to_list(B), right, $\n);
        _ -> "unknown"
    end.
