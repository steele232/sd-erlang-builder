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

-include("sd_compat.hrl").

-export([sample_corpus/3, record/2, compare/2, compare_set/2, compare_set/3,
         project_compare/3, run_sequence/1, observe/0, final_states/3, crash_rate/3]).

%% Observation keys split by measured determinism on 19.3 (3 recordings of
%% corpus-v1, 292 steps). Return values never differed. own_s_groups, s_groups
%% and names differed in 1 step each, visible in 2, free-node own_nodes in 4,
%% hidden links in 10. CORE gates L2; PERIPHERY is reported only.
-define(CORE, [own_s_groups, s_groups, names]).
-define(PERIPHERY, [own_nodes, visible, hidden]).

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

%% Outcome-set comparison (deviation N1: some sequences have several
%% legitimate reference outcomes). GoldenFiles are K reference recordings of
%% the same corpus; a run passes a sequence if its trace equals ANY of them.
%% Also reports, per sequence, how many distinct reference outcomes exist.
compare_set(CorpusFile, GoldenFiles) ->
    compare_set(CorpusFile, GoldenFiles, "/pbt/out/candidate-traces.eterm").

%% Also saves the candidate's traces (CandidateFile) so other projections can
%% be evaluated offline with project_compare/3, with no new cluster runs.
compare_set(CorpusFile, GoldenFiles, CandidateFile) ->
    Goldens = [begin {ok, [#{traces := T}]} = file:consult(F), T end || F <- GoldenFiles],
    Seqs = load_corpus(CorpusFile),
    PerSeq = lists:zip(lists:seq(1, length(Seqs)),
                       lists:zip(Seqs, transpose(Goldens))),
    Results = [{I, run_sequence(S), lists:usort(Gs)} || {I, {S, Gs}} <- PerSeq],
    ok = file:write_file(CandidateFile, io_lib:format("~p.~n",
             [#{sd_source_sha => source_sha(),
                runtime_image => os:getenv("SD_RUNTIME_IMAGE_ID", "unknown"),
                traces => [T || {_, T, _} <- Results]}])),
    Nondet = [{I, length(Set)} || {I, _, Set} <- Results, length(Set) > 1],
    Bad = [I || {I, T, Set} <- Results, not lists:member(T, Set)],
    io:format("~noutcome-set differential vs ~p reference recordings: ~p/~p sequences inside the set~n"
              "  nondeterministic reference sequences (distinct outcomes): ~p~n"
              "  outside the set: ~p~n",
              [length(GoldenFiles), length(Results) - length(Bad), length(Results), Nondet, Bad]),
    case Bad of [] -> ok; _ -> {error, Bad} end.

%% Offline: compare saved candidate traces with K golden recordings using
%% only the given observation Keys (plus return values), with outcome sets.
project_compare(CandidateFile, GoldenFiles, Keys) ->
    {ok, [#{traces := Cand}]} = file:consult(CandidateFile),
    Goldens = [begin {ok, [#{traces := T}]} = file:consult(F), T end || F <- GoldenFiles],
    Proj = fun(Trace) -> [{C, V, [{N, [maps:get(K, maps:get(N, O)) || K <- Keys]}
                                  || N <- lists:sort(maps:keys(O))]}
                          || {C, V, O} <- Trace] end,
    Rows = [{I, Proj(C), lists:usort([Proj(G) || G <- Gs])}
            || {I, C, Gs} <- lists:zip3(lists:seq(1, length(Cand)), Cand, transpose(Goldens))],
    Bad = [I || {I, P, Set} <- Rows, not lists:member(P, Set)],
    io:format("projected differential on ~p: ~p/~p sequences inside the reference outcome set; outside: ~p~n",
              [Keys, length(Rows) - length(Bad), length(Rows), Bad]),
    case Bad of [] -> ok; _ -> {error, Bad} end.

transpose([[] | _]) -> [];
transpose(Ls) -> [[hd(L) || L <- Ls] | transpose([tl(L) || L <- Ls])].

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

%% Run sequence I of a corpus K times; report how many distinct final
%% observations occur (1 = deterministic at this settle window).
final_states(CorpusFile, I, K) ->
    Seq = lists:nth(I, load_corpus(CorpusFile)),
    Finals = [element(3, lists:last(run_sequence(Seq))) || _ <- lists:seq(1, K)],
    Distinct = length(lists:usort(Finals)),
    io:format("seq ~p x~p (stable ~p ms): ~p distinct final observation(s)~n",
              [I, K, stable_ms(), Distinct]),
    ok.

%% Run sequence I of a corpus K times under the L2 runner; count runs in which
%% some SUT node became unreachable ({badrpc, _} in an observation, C1).
crash_rate(CorpusFile, I, K) ->
    Seq = lists:nth(I, load_corpus(CorpusFile)),
    Runs = [run_sequence(Seq) || _ <- lists:seq(1, K)],
    Crashed = [first_badrpc(T) || T <- Runs],
    Hits = [X || X <- Crashed, X =/= none],
    io:format("seq ~p x~p under the L2 runner: ~p run(s) with an unreachable node ~p~n",
              [I, K, length(Hits), Hits]),
    ok.

first_badrpc(Trace) ->
    Steps = lists:zip(lists:seq(1, length(Trace)), Trace),
    case [{Step, N} || {Step, {_, _, Obs}} <- Steps, {N, O} <- maps:to_list(Obs),
                       lists:any(fun({badrpc, _}) -> true; (_) -> false end, maps:values(O))] of
        [] -> none;
        [First | _] -> First
    end.

%%--------------------------------------------------------------------
%% Running a sequence
%%--------------------------------------------------------------------

run_sequence(Cmds) ->
    _ = ?CATCH(ets:new(?TAB, [named_table, public, set])),
    ok = sd_pbt_cluster:reset(),
    ets:insert(?TAB, {pid_maps, sd_pbt_cluster:pid_maps()}),
    [begin
         {call, sd_pbt_statem, F, Args} = Call,
         Res = apply(sd_pbt_statem, F, Args),
         {{F, Args}, Res, settle()}
     end || {set, _, Call} <- Cmds].

%% At rest = two observations ?STABLE_MS apart are identical (capped).
settle() ->
    Deadline = erlang:monotonic_time(millisecond) + settle_cap_ms(),
    settle_loop(observe(), Deadline).

%% SD_DIFF_STABLE_MS / SD_DIFF_SETTLE_CAP_MS override (experiments only;
%% golden traces must be recorded and compared with the same values).
stable_ms() -> env_int("SD_DIFF_STABLE_MS", ?STABLE_MS).
settle_cap_ms() -> env_int("SD_DIFF_SETTLE_CAP_MS", ?SETTLE_CAP_MS).

env_int(Var, Default) ->
    case os:getenv(Var) of
        false -> Default;
        V -> list_to_integer(V)
    end.

settle_loop(Prev, Deadline) ->
    timer:sleep(stable_ms()),
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

%% An unresponsive node is itself an observation ({badrpc, _}), never a crash.
sort_groups(L) when is_list(L) -> lists:sort([{G, lists:sort(Ns)} || {G, Ns} <- L]);
sort_groups(Other) -> Other.

norm_s_groups({badrpc, _} = E) -> E;
norm_s_groups({Own, Other}) when is_list(Own), is_list(Other) -> {lists:sort(Own), lists:sort(Other)};
norm_s_groups(Other) -> Other.

names(N, Maps) ->
    case rpc:call(N, erlang, function_exported, [s_group, known_peers, 1]) of
        true -> port_names(N, Maps);
        _ -> ref_names(N, Maps)
    end.

%% Ports: the same {Group, Name} view from the public API only; free names
%% appear as {undefined, Name}, as in 19.3's global_names table.
port_names(N, Maps) ->
    Grp = case rpc:call(N, s_group, registered_names, [{node, N}]) of
              L when is_list(L) -> L;
              _ -> []
          end,
    Free = case rpc:call(N, global, registered_names, []) of
               F when is_list(F) -> [{undefined, Nm} || Nm <- F];
               _ -> []
           end,
    Where = fun(undefined, Nm) -> rpc:call(N, global, whereis_name, [Nm]);
               (G, Nm) -> rpc:call(N, s_group, whereis_name, [G, Nm])
            end,
    lists:sort([{G, Nm, sd_pbt_cluster:to_ref(Where(G, Nm), Maps)} || {G, Nm} <- Grp ++ Free]).

%% 19.3 reference: unchanged observation (golden traces stay valid).
ref_names(N, Maps) ->
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
