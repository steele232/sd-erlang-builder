%% Lifecycle of the 14-node system under test, run from a hidden driver node
%% in the same container. Topology after D3.3 5.2: 12 normal + 2 hidden
%% nodes, all free (no s_groups config) at start.
-module(sd_pbt_cluster).

-include("sd_compat.hrl").

-export([sut_nodes/0, node_types/0, start/0, reset/0, stop/0,
         pid_maps/0, to_real/2, to_ref/2]).

-define(HOST, "pbt.sd.lab").
-define(NORMAL, 12).
-define(HIDDEN, 2).
-define(POOL, 3).
-define(START_TIMEOUT_MS, 30000).

node_types() ->
    [{node_name("n", I), normal} || I <- lists:seq(1, ?NORMAL)] ++
    [{node_name("h", I), hidden} || I <- lists:seq(1, ?HIDDEN)].

sut_nodes() -> [N || {N, _} <- node_types()].

node_name(Prefix, I) ->
    list_to_atom(Prefix ++ integer_to_list(I) ++ "@" ++ ?HOST).

start() ->
    [launch(N, T) || {N, T} <- node_types()],
    wait_until(fun() -> [N || N <- sut_nodes(), net_adm:ping(N) =/= pong] =:= [] end,
               ?START_TIMEOUT_MS, all_nodes_up),
    [{N, _} = {N, rpc:call(N, sd_pbt_agent, start_pool, [?POOL])} || N <- sut_nodes()],
    ok.

stop() ->
    [rpc:cast(N, erlang, halt, []) || N <- sut_nodes()],
    wait_until(fun() -> [N || N <- sut_nodes(), lists:member(N, erlang:nodes(hidden))] =:= [] end,
               ?START_TIMEOUT_MS, all_nodes_down),
    %% epmd may still list a name for a moment after the VM exits
    wait_until(fun() ->
                       {ok, Names} = net_adm:names(),
                       [Nm || {Nm, _} <- Names,
                              lists:member(list_to_atom(Nm ++ "@" ++ ?HOST), sut_nodes())] =:= []
               end, ?START_TIMEOUT_MS, epmd_clear),
    ok.

reset() ->
    ok = stop(),
    ok = start().

launch(Node, Type) ->
    [Name, _] = string:tokens(atom_to_list(Node), "@"),
    Hidden = case Type of hidden -> " -hidden"; normal -> "" end,
    %% Crash dumps go to the mounted results dir (the container is --rm), one
    %% file per node and launch, so a SUT crash leaves evidence.
    %% Error reports go to a per-node log so the crashing kernel child and its
    %% reason are recorded (detached nodes otherwise discard them).
    Stamp = integer_to_list(erlang:system_time(millisecond)),
    Dump = "/pbt/out/erl_crash-" ++ Name ++ "-" ++ Stamp ++ ".dump",
    Log = "/pbt/out/log-" ++ Name ++ "-" ++ Stamp ++ ".log",
    %% SD_PBT_NODE_ARGS: extra erl args a runtime image needs on every SUT node
    %% (e.g. a library-only port: "-kernel connect_all false -pa ... -s ...").
    Extra = os:getenv("SD_PBT_NODE_ARGS", ""),
    Cmd = "ERL_CRASH_DUMP=" ++ Dump ++ " erl -detached -noshell -name " ++ Name ++ "@" ++ ?HOST ++ Hidden ++
          " -pa /pbt/ebin -kernel error_logger '{file,\"" ++ Log ++ "\"}' " ++ Extra,
    _ = os:cmd(Cmd),
    ok.

%% {RefToPid, PidToRef} for every pool process on every node.
pid_maps() ->
    Pairs = [{{pid, N, I}, P} || N <- sut_nodes(),
                                 {I, P} <- rpc:call(N, sd_pbt_agent, pool, [])],
    {maps:from_list(Pairs), maps:from_list([{P, R} || {R, P} <- Pairs])}.

to_real(Term, {RefToPid, _}) -> map_term(Term, fun(T) -> maps:find(T, RefToPid) end).
to_ref(Term, {_, PidToRef}) -> map_term(Term, fun(T) when is_pid(T) ->
                                                       case maps:find(T, PidToRef) of
                                                           {ok, R} -> {ok, R};
                                                           error -> {ok, {unknown_pid, node(T)}}
                                                       end;
                                                  (_) -> error end).

map_term(T, F) ->
    case F(T) of
        {ok, V} -> V;
        error when is_list(T) -> [map_term(E, F) || E <- T];
        error when is_tuple(T) -> list_to_tuple([map_term(E, F) || E <- tuple_to_list(T)]);
        error -> T
    end.

wait_until(Fun, TimeoutMs, What) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(Fun, Deadline, What).

wait_loop(Fun, Deadline, What) ->
    case ?CATCH(Fun()) of
        true -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> erlang:error({timeout, What});
                false -> timer:sleep(100), wait_loop(Fun, Deadline, What)
            end
    end.
