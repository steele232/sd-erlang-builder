%% L5 free-node equivalence (design contract S2: "a node in no s_group
%% behaves as a usual distributed Erlang node"; JPDC'16: global functions are
%% identical on free nodes in distributed Erlang and SD Erlang).
%%
%% Runs an s_group-free workload (connections + global name registry) on the
%% 14-node cluster and records full observations. The same corpus is run on
%% the SD runtime and on stock OTP built from the SD commit's exact parent;
%% the traces must be identical. No model needed.
%%
%%   sd_free_equiv:sample_corpus(File, Seed, Count)
%%   sd_free_equiv:record(CorpusFile, TraceFile)
%%   sd_free_equiv:compare(CorpusFile, TraceFileA, TraceFileB)   (pure, no cluster)
-module(sd_free_equiv).

-include("sd_compat.hrl").

-export([sample_corpus/3, record/2, compare/3]).

-define(TAB, sd_pbt).
-define(NAMES, [a, b, c, d]).
%% Must exceed global's locker retry interval, min(1000 + 100*|known|, 3000) ms
%% (global.erl loop_the_locker/1); a shorter window can sample a quiet gap
%% mid-sync (measured: 26-27/30 self-agreement at 500 ms).
-define(STABLE_MS, 3500).
-define(SETTLE_CAP_MS, 30000).

sample_corpus(File, Seed, Count) ->
    rand:seed(exsplus, {Seed, Seed + 1, Seed + 2}),
    Nodes = sd_pbt_cluster:sut_nodes(),
    Seqs = [[command(Nodes) || _ <- lists:seq(1, 6 + rand:uniform(10))]
            || _ <- lists:seq(1, Count)],
    ok = file:write_file(File, io_lib:format("~p.~n", [#{seed => Seed, sequences => Seqs}])),
    io:format("free-node corpus ~s: ~p sequences~n", [File, Count]),
    ok.

pick(L) -> lists:nth(rand:uniform(length(L)), L).

command(Nodes) ->
    Ni = pick(Nodes),
    pick([{connect, Ni, pick(Nodes)}, {connect, Ni, pick(Nodes)}, {connect, Ni, pick(Nodes)},
          {register_name, pick(?NAMES), {pid, pick(Nodes), rand:uniform(3)}, Ni},
          {register_name, pick(?NAMES), {pid, pick(Nodes), rand:uniform(3)}, Ni},
          {re_register_name, pick(?NAMES), {pid, pick(Nodes), rand:uniform(3)}, Ni},
          {unregister_name, pick(?NAMES), Ni},
          {whereis_name, pick(?NAMES), Ni},
          {send, pick(?NAMES), Ni},
          {disconnect, Ni, pick(Nodes)}]).

record(CorpusFile, TraceFile) ->
    {ok, [#{sequences := Seqs}]} = file:consult(CorpusFile),
    Traces = [run_sequence(S) || S <- Seqs],
    Meta = #{otp_release => erlang:system_info(otp_release),
             sd_source_sha => source_sha(),
             runtime_image => os:getenv("SD_RUNTIME_IMAGE_ID", "unknown"),
             corpus => filename:basename(CorpusFile),
             traces => Traces},
    ok = file:write_file(TraceFile, io_lib:format("~p.~n", [Meta])),
    io:format("recorded ~p free-node traces to ~s~n", [length(Traces), TraceFile]),
    ok.

compare(CorpusFile, FileA, FileB) ->
    {ok, [#{sequences := Seqs}]} = file:consult(CorpusFile),
    {ok, [#{traces := TA, sd_source_sha := ShaA}]} = file:consult(FileA),
    {ok, [#{traces := TB, sd_source_sha := ShaB}]} = file:consult(FileB),
    Diffs = [{I, first_diff(A, B)} || {I, A, B} <- lists:zip3(lists:seq(1, length(Seqs)), TA, TB), A =/= B],
    io:format("free-node equivalence ~s vs ~s: ~p/~p sequences identical~n",
              [ShaA, ShaB, length(Seqs) - length(Diffs), length(Seqs)]),
    [io:format("  seq ~p: ~P~n", [I, D, 30]) || {I, D} <- Diffs],
    case Diffs of [] -> ok; _ -> {error, [I || {I, _} <- Diffs]} end.

first_diff(A, B) ->
    hd([{step, K, {a, SA}, {b, SB}}
        || {K, SA, SB} <- lists:zip3(lists:seq(1, length(A)), A, B), SA =/= SB]).

run_sequence(Cmds) ->
    _ = ?CATCH(ets:new(?TAB, [named_table, public, set])),
    ok = sd_pbt_cluster:reset(),
    Maps = sd_pbt_cluster:pid_maps(),
    ets:insert(?TAB, {pid_maps, Maps}),
    [{Cmd, sd_pbt_cluster:to_ref(exec(Cmd, Maps), Maps), settle(Maps)} || Cmd <- Cmds].

exec({connect, A, B}, _) -> rpc:call(A, net_kernel, connect_node, [B]);
exec({disconnect, A, B}, _) -> rpc:call(A, erlang, disconnect_node, [B]);
exec({register_name, N, P, Ni}, M) -> rpc:call(Ni, global, register_name, [N, sd_pbt_cluster:to_real(P, M)]);
exec({re_register_name, N, P, Ni}, M) -> rpc:call(Ni, global, re_register_name, [N, sd_pbt_cluster:to_real(P, M)]);
exec({unregister_name, N, Ni}, _) -> rpc:call(Ni, global, unregister_name, [N]);
exec({whereis_name, N, Ni}, _) -> rpc:call(Ni, global, whereis_name, [N]);
exec({send, N, Ni}, _) -> rpc:call(Ni, erlang, apply,
                                   [fun() -> ?CATCH(global:send(N, sd_free_msg)) end, []]).

settle(Maps) ->
    Deadline = erlang:monotonic_time(millisecond) + ?SETTLE_CAP_MS,
    settle_loop(observe(Maps), Maps, Deadline).

settle_loop(Prev, Maps, Deadline) ->
    timer:sleep(?STABLE_MS),
    Obs = observe(Maps),
    case Obs =:= Prev orelse erlang:monotonic_time(millisecond) > Deadline of
        true -> Obs;
        false -> settle_loop(Obs, Maps, Deadline)
    end.

observe(Maps) ->
    Sut = sd_pbt_cluster:sut_nodes(),
    Only = fun(L) when is_list(L) -> lists:sort([N || N <- L, lists:member(N, Sut)]);
              (O) -> O end,
    [{N, Only(rpc:call(N, erlang, nodes, [visible])),
         Only(rpc:call(N, erlang, nodes, [hidden])),
         lists:sort([{Name, sd_pbt_cluster:to_ref(rpc:call(N, global, whereis_name, [Name]), Maps)}
                     || Name <- ?NAMES])}
     || N <- Sut].

source_sha() ->
    case file:read_file("/opt/sd-erlang/SD_SOURCE_SHA") of
        {ok, B} -> string:strip(binary_to_list(B), right, $\n);
        _ -> "unknown"
    end.
