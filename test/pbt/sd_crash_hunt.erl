%% Find which corpus sequence/step makes a SUT node go down *or* makes its
%% s_group server unresponsive (gen_server:call default 5 s timeout ->
%% {badrpc, {'EXIT', {timeout, ...}}}), and capture evidence to /pbt/out.
%%
%%   sd_crash_hunt:run(CorpusFile, Rounds)
-module(sd_crash_hunt).

-export([run/2]).

-define(TAB, sd_pbt).

run(CorpusFile, Rounds) ->
    catch ets:new(?TAB, [named_table, public, set]),
    {ok, [#{sequences := Seqs}]} = file:consult(CorpusFile),
    Hits = lists:append([hunt(R, I, S) || R <- lists:seq(1, Rounds),
                                          {I, S} <- lists:zip(lists:seq(1, length(Seqs)), Seqs)]),
    io:format("~ncrash hunt: ~p node-down events in ~p rounds x ~p sequences~n",
              [length(Hits), Rounds, length(Seqs)]),
    [io:format("  round ~p seq ~p step ~p cmd ~P down ~p~n", [R, I, K, C, 12, D])
     || {R, I, K, C, D} <- Hits],
    ok.

hunt(Round, I, Cmds) ->
    _ = os:cmd("rm -f /pbt/erl_crash.dump"),
    ok = sd_pbt_cluster:reset(),
    ets:insert(?TAB, {pid_maps, sd_pbt_cluster:pid_maps()}),
    Steps = lists:zip(lists:seq(1, length(Cmds)), [C || {set, _, C} <- Cmds]),
    hunt_steps(Round, I, Steps).

hunt_steps(_R, _I, []) ->
    [];
hunt_steps(R, I, [{K, {call, sd_pbt_statem, F, Args}} | Rest]) ->
    _ = apply(sd_pbt_statem, F, Args),
    timer:sleep(1500),
    Down = [{N, Why} || N <- sd_pbt_cluster:sut_nodes(),
                        Why <- [health(N)], Why =/= ok],
    case Down of
        [] ->
            hunt_steps(R, I, Rest);
        _ ->
            Dump = case file:read_file("/pbt/erl_crash.dump") of
                       {ok, B} -> binary:part(B, 0, min(4000, byte_size(B)));
                       _ -> <<"no erl_crash.dump">>
                   end,
            File = lists:flatten(io_lib:format("/pbt/out/crash-r~p-s~p-k~p.txt", [R, I, K])),
            ok = file:write_file(File, io_lib:format("cmd: ~p~ndown: ~p~n~n~s~n", [{F, Args}, Down, Dump])),
            [{R, I, K, {F, Args}, Down}]
    end.

health(N) ->
    case net_adm:ping(N) of
        pang -> node_down;
        pong ->
            case rpc:call(N, s_group, s_groups, [], 8000) of
                {badrpc, Reason} -> {s_group_unresponsive, Reason, process_info_s_group(N)};
                _ -> ok
            end
    end.

process_info_s_group(N) ->
    case rpc:call(N, erlang, whereis, [s_group], 3000) of
        P when is_pid(P) ->
            rpc:call(N, erlang, process_info,
                     [P, [current_function, current_stacktrace, message_queue_len, status]], 3000);
        Other -> Other
    end.
