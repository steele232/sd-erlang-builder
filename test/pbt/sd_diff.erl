%% L2 differential fidelity: record and compare full-observation traces.
%%
%% A corpus is a list of command sequences in the sd_pbt_statem symbolic
%% format ([{set, Var, {call, sd_pbt_statem, F, Args}}]). Running a sequence
%% yields a trace: for every command, the normalised return value and a full
%% observation of the cluster *after it has come to rest*. Golden traces are
%% recorded on the 19.3 reference; a port must reproduce them.
%%
%% Model-free on purpose: L1 already measures distance to M, L2 measures
%% distance to the reference implementation, including everything M does not
%% model (link visibility, lookup side effects, non-member views).
%%
%%   sd_diff:sample_corpus(File, Seed, Count)  generate a fixed-seed corpus
%%   sd_diff:record(CorpusFile, GoldenFile)    run corpus, write golden traces
%%   sd_diff:compare(CorpusFile, GoldenFile)   run corpus, diff against golden
-module(sd_diff).

-export([sample_corpus/3, record/2, compare/2, run_sequence/1, observe/0]).

-define(TAB, sd_pbt).
%% Must exceed global's locker retry interval, min(1000 + 100*|known|, 3000) ms
%% (global.erl loop_the_locker/1); a shorter window can sample a quiet gap
%% mid-sync (measured: 26-27/30 self-agreement at 500 ms).
-define(STABLE_MS, 3500).
-define(SETTLE_CAP_MS, 30000).

%%--------------------------------------------------------------------
%% Corpus
%%--------------------------------------------------------------------

%% Seeded sampling from the same generator L1 uses, so the corpus has L1's
%% operation mix. The corpus file is what gets committed, not the seed:
%% generator changes must not silently change the corpus.
sample_corpus(File, Seed, Count) ->
    rand:seed(exsplus, {Seed, Seed + 1, Seed + 2}),
    Seqs = [sample_one(Seed + I) || I <- lists:seq(1, Count)],
    ok = file:write_file(File, io_lib:format("~p.~n", [#{seed => Seed, sequences => Seqs}])),
    io:format("corpus ~s: ~p sequences, ~p commands~n",
              [File, length(Seqs), lists:sum([length(S) || S <- Seqs])]),
    ok.

sample_one(Seed) ->
    rand:seed(exsplus, {Seed, Seed * 3, Seed * 5}),
    {ok, Cmds} = proper_gen:pick(proper_statem:commands(sd_pbt_statem), 20),
    Cmds.

load_corpus(File) ->
    {ok, [#{sequences := Seqs}]} = file:consult(File),
    Seqs.

%%--------------------------------------------------------------------
%% Record / compare
%%--------------------------------------------------------------------

record(CorpusFile, GoldenFile) ->
    Traces = [run_sequence(S) || S <- load_corpus(CorpusFile)],
    Meta = #{otp_release => erlang:system_info(otp_release),
             sd_source_sha => source_sha(),
             runtime_image => os:getenv("SD_RUNTIME_IMAGE_ID", "unknown"),
             corpus => filename:basename(CorpusFile),
             traces => Traces},
    ok = file:write_file(GoldenFile, io_lib:format("~p.~n", [Meta])),
    io:format("recorded ~p traces to ~s~n", [length(Traces), GoldenFile]),
    ok.

compare(CorpusFile, GoldenFile) ->
    {ok, [#{traces := Golden, sd_source_sha := RefSha}]} = file:consult(GoldenFile),
    Seqs = load_corpus(CorpusFile),
    Results = [{I, diff_trace(run_sequence(S), G)}
               || {I, S, G} <- lists:zip3(lists:seq(1, length(Seqs)), Seqs, Golden)],
    Bad = [{I, D} || {I, D} <- Results, D =/= []],
    io:format("~ndifferential vs ~s (ref ~s): ~p/~p sequences identical~n",
              [filename:basename(GoldenFile), RefSha, length(Results) - length(Bad), length(Results)]),
    [io:format("  seq ~p: first difference at step ~p~n    ~P~n", [I, Step, What, 40])
     || {I, [{Step, What} | _]} <- Bad],
    case Bad of
        [] -> ok;
        _ -> {error, [I || {I, _} <- Bad]}
    end.

diff_trace(Trace, Golden) ->
    Steps = lists:zip(lists:seq(1, length(Trace)), lists:zip(Trace, Golden)),
    [{Step, {cmd, C, {got, step_summary(T)}, {want, step_summary(G)}, deltas(T, G)}}
     || {Step, {{C, _, _} = T, {C, _, _} = G}} <- Steps, T =/= G].

step_summary({_Cmd, Res, _Obs}) -> Res.

deltas({_, R1, O1}, {_, R2, O2}) ->
    [{value, R1, R2} || R1 =/= R2] ++
    [{N, K, {got, maps:get(K, maps:get(N, O1, #{}), none)},
            {want, maps:get(K, maps:get(N, O2, #{}), none)}}
     || N <- lists:usort(maps:keys(O1) ++ maps:keys(O2)),
        K <- [own_s_groups, s_groups, own_nodes, visible, hidden, names],
        maps:get(K, maps:get(N, O1, #{}), none) =/= maps:get(K, maps:get(N, O2, #{}), none)].

%%--------------------------------------------------------------------
%% Running a sequence
%%--------------------------------------------------------------------

run_sequence(Cmds) ->
    catch ets:new(?TAB, [named_table, public, set]),
    ok = sd_pbt_cluster:reset(),
    ets:insert(?TAB, {pid_maps, sd_pbt_cluster:pid_maps()}),
    [begin
         {call, sd_pbt_statem, F, Args} = Call,
         Res = apply(sd_pbt_statem, F, Args),
         {{F, Args}, Res, settle()}
     end || {set, _, Call} <- Cmds].

%% At rest = two observations ?STABLE_MS apart are identical (capped).
settle() ->
    Deadline = erlang:monotonic_time(millisecond) + ?SETTLE_CAP_MS,
    settle_loop(observe(), Deadline).

settle_loop(Prev, Deadline) ->
    timer:sleep(?STABLE_MS),
    Obs = observe(),
    case Obs =:= Prev orelse erlang:monotonic_time(millisecond) > Deadline of
        true -> Obs;
        false -> settle_loop(Obs, Deadline)
    end.

%% Everything observable through public APIs, per SUT node.
observe() ->
    [{pid_maps, Maps}] = ets:lookup(?TAB, pid_maps),
    Sut = sd_pbt_cluster:sut_nodes(),
    Only = fun(L) when is_list(L) -> lists:sort([N || N <- L, lists:member(N, Sut)]);
              (Other) -> Other end,
    maps:from_list(
      [{N, #{own_s_groups => sort_groups(rpc:call(N, s_group, own_s_groups, [])),
             s_groups => norm_s_groups(rpc:call(N, s_group, s_groups, [])),
             own_nodes => Only(rpc:call(N, s_group, own_nodes, [])),
             visible => Only(rpc:call(N, erlang, nodes, [visible])),
             hidden => Only(rpc:call(N, erlang, nodes, [hidden])),
             names => names(N, Maps)}}
       || N <- Sut]).

sort_groups(L) when is_list(L) -> lists:sort([{G, lists:sort(Ns)} || {G, Ns} <- L]);
sort_groups(Other) -> Other.

norm_s_groups({Own, Other}) -> {lists:sort(Own), lists:sort(Other)};
norm_s_groups(Other) -> Other.

names(N, Maps) ->
    case rpc:call(N, global, registered_names, [all_names]) of
        L when is_list(L) ->
            lists:sort([{G, Name, sd_pbt_cluster:to_ref(rpc:call(N, global, whereis_name, [G, Name]), Maps)}
                        || {G, Name} <- L]);
        Other ->
            Other
    end.

source_sha() ->
    case file:read_file("/opt/sd-erlang/SD_SOURCE_SHA") of
        {ok, B} -> string:strip(binary_to_list(B), right, $\n);
        _ -> "unknown"
    end.
