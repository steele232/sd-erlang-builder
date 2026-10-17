%% Executable demonstration of historical SD Erlang s_group semantics.
%%
%% Runs on the gateway node and inspects the other two nodes over rpc.
%% Every check is either
%%   immediate safety  - something illegal must never become visible, or
%%   eventual liveness - a legal state must converge before a deadline,
%% because s_group membership changes propagate asynchronously.
%%
%% run/0     full SD scenario (requires the SD runtime)
%% control/0 connectivity-only check for stock OTP, which is expected to
%%           show the transitive mesh that SD Erlang avoids
-module(sd_demo_scenario).

-export([run/0, control/0]).

-define(GATEWAY,   'gateway@gateway.sd.lab').
-define(GPU1,      'gpu1@gpu1.sd.lab').
-define(CONNECTOR, 'connector@connector.sd.lab').

-define(CONVERGE_MS, 15000).
-define(SAFETY_MS, 3000).
-define(RESTART_MS, 60000).

%%--------------------------------------------------------------------
%% SD scenario
%%--------------------------------------------------------------------

run() ->
    ?GATEWAY = node(),
    Steps =
        [{"peers reachable from gateway",
          fun step_reachable/0},
         {"overlapping static s_groups (gateway in both, workers in one)",
          fun step_membership/0},
         {"no transitive connection gpu1 <-> connector",
          fun step_no_transitive/0},
         {"same name `worker_pool` resolves per group",
          fun step_scoped_names/0},
         {"s_group:send/3 routes by group",
          fun step_routing/0},
         {"cannot register in a group you do not belong to",
          fun step_remote_register_refused/0},
         {"add_nodes/2: gpu1 joins external_ai dynamically",
          fun step_add_nodes/0},
         {"remove_nodes/2: gpu1 leaves external_ai and converges",
          fun step_remove_nodes/0},
         {"new_s_group/2 + delete_s_group/1",
          fun step_new_delete/0},
         {"crash connector: local_ai unaffected, external_ai recovers",
          fun step_crash_isolation/0}],
    report(run_steps(Steps)).

step_reachable() ->
    await("gateway pings gpu1",      fun() -> net_adm:ping(?GPU1) =:= pong end),
    await("gateway pings connector", fun() -> net_adm:ping(?CONNECTOR) =:= pong end),
    {ok, [{gateway_nodes, lists:sort(nodes())}]}.

step_membership() ->
    Expect =
        [{?GATEWAY,   [{external_ai, [?CONNECTOR, ?GATEWAY]},
                       {local_ai,    [?GATEWAY, ?GPU1]}]},
         {?GPU1,      [{local_ai,    [?GATEWAY, ?GPU1]}]},
         {?CONNECTOR, [{external_ai, [?CONNECTOR, ?GATEWAY]}]}],
    [check(io_lib:format("own_s_groups on ~s", [N]), Want, own_groups(N))
     || {N, Want} <- Expect],
    {ok, [{N, own_groups(N)} || {N, _} <- Expect]}.

step_no_transitive() ->
    %% Stock global would mesh gpu1 and connector once both know gateway.
    never("gpu1 connected to connector",
          fun() -> lists:member(?CONNECTOR, rpc:call(?GPU1, erlang, nodes, [])) end),
    never("connector connected to gpu1",
          fun() -> lists:member(?GPU1, rpc:call(?CONNECTOR, erlang, nodes, [])) end),
    check("gateway is connected to both", [?CONNECTOR, ?GPU1], lists:sort(nodes())),
    {ok, [{gpu1_nodes, rpc:call(?GPU1, erlang, nodes, [])},
          {connector_nodes, rpc:call(?CONNECTOR, erlang, nodes, [])}]}.

step_scoped_names() ->
    Local = await_pid_on(local_ai, ?GPU1),
    External = await_pid_on(external_ai, ?CONNECTOR),
    true = Local =/= External,
    %% Group names live outside the ordinary global namespace.
    check("global:whereis_name(worker_pool)", undefined, global:whereis_name(worker_pool)),
    {ok, [{local_ai, Local}, {external_ai, External}]}.

step_routing() ->
    {ok, [round_trip(local_ai, ?GPU1), round_trip(external_ai, ?CONNECTOR)]}.

step_remote_register_refused() ->
    GpuPid = rpc:call(?GPU1, erlang, whereis, [init]),
    check("gpu1 registers in external_ai",
          {no, cannot_register_in_remote_group},
          rpc:call(?GPU1, s_group, register_name, [external_ai, intruder, GpuPid])),
    {ok, []}.

step_add_nodes() ->
    check("add_nodes reply", {ok, external_ai, [?GPU1]},
          s_group:add_nodes(external_ai, [?GPU1])),
    Members = [?CONNECTOR, ?GATEWAY, ?GPU1],
    await("gpu1 sees itself in external_ai",
          fun() -> lists:member({external_ai, Members}, own_groups(?GPU1)) end),
    await("connector sees gpu1 in external_ai",
          fun() -> lists:member({external_ai, Members}, own_groups(?CONNECTOR)) end),
    ConnectorPool = await_pid_on(external_ai, ?CONNECTOR),
    await("gpu1 resolves external_ai worker_pool via its own membership",
          fun() ->
                  rpc:call(?GPU1, s_group, whereis_name, [external_ai, worker_pool])
                      =:= ConnectorPool
          end),
    await("gpu1 <-> connector may now connect (shared group)",
          fun() ->
                  _ = rpc:call(?GPU1, net_adm, ping, [?CONNECTOR]),
                  lists:member(?CONNECTOR, rpc:call(?GPU1, erlang, nodes, []))
          end),
    {ok, [{gpu1_groups, own_groups(?GPU1)}]}.

step_remove_nodes() ->
    check("remove_nodes reply", ok, s_group:remove_nodes(external_ai, [?GPU1])),
    await("gpu1 left external_ai",
          fun() -> own_groups(?GPU1) =:= [{local_ai, [?GATEWAY, ?GPU1]}] end),
    await("connector dropped gpu1 from external_ai",
          fun() -> own_groups(?CONNECTOR) =:= [{external_ai, [?CONNECTOR, ?GATEWAY]}] end),
    GpuPid = rpc:call(?GPU1, erlang, whereis, [init]),
    check("gpu1 may no longer register in external_ai",
          {no, cannot_register_in_remote_group},
          rpc:call(?GPU1, s_group, register_name, [external_ai, intruder, GpuPid])),
    %% Historical 19.3 behaviour: s_group's disconnect_nodes/1 is a *logical*
    %% disconnect (global forgets the node; no erlang:disconnect_node/1), so
    %% the distribution link opened while gpu1 was a member may stay up.
    %% Observed and reported here, deliberately not asserted either way.
    {ok, [{gpu1_groups, own_groups(?GPU1)},
          {gpu1_transport_links_after_remove, rpc:call(?GPU1, erlang, nodes, [])}]}.

step_new_delete() ->
    check("new_s_group reply", {ok, audit, [?GATEWAY, ?GPU1]},
          s_group:new_s_group(audit, [?GATEWAY, ?GPU1])),
    await("gpu1 joined audit",
          fun() -> lists:keymember(audit, 1, own_groups(?GPU1)) end),
    never("connector learns about audit membership",
          fun() -> lists:keymember(audit, 1, own_groups(?CONNECTOR)) end),
    check("delete_s_group reply", ok, s_group:delete_s_group(audit)),
    await("gpu1 left audit",
          fun() -> not lists:keymember(audit, 1, own_groups(?GPU1)) end),
    await("gateway left audit",
          fun() -> not lists:keymember(audit, 1, own_groups(?GATEWAY)) end),
    {ok, [{gateway_groups, own_groups(?GATEWAY)}]}.

step_crash_isolation() ->
    await_pid_on(external_ai, ?CONNECTOR),
    {UptimeBefore, _} = rpc:call(?CONNECTOR, erlang, statistics, [wall_clock]),
    %% Abrupt BEAM exit; the container's restart policy brings it back.
    rpc:cast(?CONNECTOR, erlang, halt, [1]),
    await("gateway sees connector down",
          fun() -> not lists:member(?CONNECTOR, nodes()) end),
    await("gateway's external_ai name table drops the dead worker_pool",
          fun() -> global:whereis_name(external_ai, worker_pool) =:= undefined end),
    LocalDuringOutage = round_trip(local_ai, ?GPU1),
    check("gpu1 membership untouched by connector crash",
          [{local_ai, [?GATEWAY, ?GPU1]}], own_groups(?GPU1)),
    %% Restart detection uses node uptime, not pid inequality: OTP 20's 2-bit
    %% node creation restarts at 1 under a fresh epmd, so the re-registered
    %% worker can print (and compare) as the very same pid.
    await("connector restarted (uptime reset)",
          fun() ->
                  _ = net_adm:ping(?CONNECTOR),
                  case rpc:call(?CONNECTOR, erlang, statistics, [wall_clock]) of
                      {Up, _} when is_integer(Up), Up < UptimeBefore -> true;
                      _ -> false
                  end
          end, ?RESTART_MS),
    NewPool = await_pid_on(external_ai, ?CONNECTOR),
    ExternalAfter = round_trip(external_ai, ?CONNECTOR),
    never("gpu1 connected to restarted connector",
          fun() -> lists:member(?CONNECTOR, rpc:call(?GPU1, erlang, nodes, [])) end),
    {ok, [LocalDuringOutage, {connector_uptime_before_ms, UptimeBefore},
          {new_pool, NewPool}, ExternalAfter]}.

%%--------------------------------------------------------------------
%% Stock OTP control: same three nodes, no s_groups
%%--------------------------------------------------------------------

control() ->
    Steps =
        [{"peers reachable from gateway", fun step_reachable/0},
         {"stock global meshes gpu1 <-> connector transitively",
          fun() ->
                  await("gpu1 connected to connector",
                        fun() -> lists:member(?CONNECTOR, rpc:call(?GPU1, erlang, nodes, [])) end),
                  {ok, [{gpu1_nodes, rpc:call(?GPU1, erlang, nodes, [])}]}
          end}],
    report(run_steps(Steps)).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

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

await_pid_on(Group, Node) ->
    await(io_lib:format("~p worker_pool on ~s", [Group, Node]),
          fun() ->
                  case s_group:whereis_name(Group, worker_pool) of
                      P when is_pid(P), node(P) =:= Node -> {true, P};
                      _ -> false
                  end
          end).

round_trip(Group, ExpectNode) ->
    JobId = make_ref(),
    Pid = s_group:send(Group, worker_pool, {run, JobId, self()}),
    true = is_pid(Pid),
    receive
        {job_done, JobId, ExpectNode, Group} -> {Group, job_done_on, ExpectNode}
    after 5000 ->
            erlang:error({no_reply_from, Group, ExpectNode})
    end.

check(Desc, Want, Got) ->
    case Want =:= Got of
        true -> ok;
        false -> erlang:error({check_failed, lists:flatten(Desc), {want, Want}, {got, Got}})
    end.

%% Eventual liveness: Fun must return true or {true, V} before the deadline.
await(Desc, Fun) ->
    await(Desc, Fun, ?CONVERGE_MS).

await(Desc, Fun, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_loop(lists:flatten(Desc), Fun, Deadline).

await_loop(Desc, Fun, Deadline) ->
    case catch Fun() of
        true -> true;
        {true, V} -> V;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> erlang:error({did_not_converge, Desc});
                false -> timer:sleep(100), await_loop(Desc, Fun, Deadline)
            end
    end.

%% Immediate safety: Fun must stay false for the whole observation window.
never(Desc, Fun) ->
    Deadline = erlang:monotonic_time(millisecond) + ?SAFETY_MS,
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
