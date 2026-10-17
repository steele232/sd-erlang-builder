%% Runs on every system-under-test node. Keeps a small pool of long-lived,
%% locally registered processes so the driver can refer to pids
%% runtime-independently as {pid, Node, Index}.
-module(sd_pbt_agent).

-export([start_pool/1, pool/0]).

-define(POOL_PREFIX, "sd_pbt_p").

-spec start_pool(pos_integer()) -> [{pos_integer(), pid()}].
start_pool(K) ->
    [{I, ensure(I)} || I <- lists:seq(1, K)].

-spec pool() -> [{pos_integer(), pid()}].
pool() ->
    [{I, P} || {I, P} <- [{I, whereis(name(I))} || I <- lists:seq(1, 16)], is_pid(P)].

ensure(I) ->
    case whereis(name(I)) of
        undefined ->
            Pid = spawn(fun loop/0),
            true = register(name(I), Pid),
            Pid;
        Pid ->
            Pid
    end.

name(I) -> list_to_atom(?POOL_PREFIX ++ integer_to_list(I)).

%% Absorb s_group:send/3,4 traffic.
loop() ->
    receive _ -> loop() end.
