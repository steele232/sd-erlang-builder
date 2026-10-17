%% Join-then-register: wait until global on this node knows every other
%% member of Group, then register Name there.
%%
%% Workaround for a defect observed in historical SD Erlang 19.3: a
%% group-scoped registration is multicast only to global:get_known_s_group/1
%% at that instant, and the exchange on later connections does not reliably
%% back-fill it, so an early registration can stay missing on some members
%% indefinitely (s_group:sync/0 does not repair it). Waiting for nodes() alone
%% is not enough; global's known set lags the links. Reproduce with `bin/sd-demo15 repro` (sd15_repro.erl), which boots
%% the cluster with {sd_demo, registration, boot} to skip the wait.
-module(sd_demo_registrar).

-export([register_when_joined/3]).

-define(POLL_MS, 200).
-define(MAX_WAIT_MS, 15000).

-spec register_when_joined(atom(), atom(), pid()) -> yes | {no, term()}.
register_when_joined(Group, Name, Pid) ->
    case application:get_env(sd_demo, registration, joined) of
        boot ->
            ok;
        joined ->
            wait_joined(Group, erlang:monotonic_time(millisecond) + ?MAX_WAIT_MS)
    end,
    s_group:register_name(Group, Name, Pid).

wait_joined(Group, Deadline) ->
    Missing = (s_group:own_nodes(Group) -- [node()]) -- known(Group),
    case Missing =:= [] orelse erlang:monotonic_time(millisecond) > Deadline of
        true when Missing =/= [] ->
            io:format("[~s] registering in ~p before joining ~p~n", [node(), Group, Missing]);
        true ->
            ok;
        false ->
            timer:sleep(?POLL_MS),
            wait_joined(Group, Deadline)
    end.

%% Members global on this node has synced with. 19.3 exposes this only as
%% the internal global:get_known_s_group/1; a port exports s_group:known_peers/1.
known(Group) ->
    case erlang:function_exported(s_group, known_peers, 1) of
        true -> s_group:known_peers(Group);
        false -> global:get_known_s_group(Group)
    end.
