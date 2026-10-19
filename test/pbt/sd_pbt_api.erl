%% 19.3 API parity (port patch 0014) and the {via, s_group, {G, Name}}
%% adapter, on the harness cluster.
%%   sd_pbt_api:run()
-module(sd_pbt_api).
-behaviour(gen_server).

-export([run/0]).
-export([init/1, handle_call/3, handle_cast/2]).

run() ->
    _ = (try ets:new(sd_pbt, [named_table, public, set]) catch _:_ -> ok end),
    ok = sd_pbt_cluster:reset(),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    {N1, N2, N3} = {N("n1"), N("n2"), N("n3")},
    R = [
      %% new_s_group/1: a generated name, usable like any other
      {new_s_group_1, case rpc:call(N1, s_group, new_s_group, [[N1, N2]]) of
                          {ok, G0, Ms} when is_atom(G0) -> {ok, length(Ms), lists:member({G0, lists:sort(Ms)}, own(N2))};
                          Other0 -> Other0
                      end},
      {g, rpc:call(N1, s_group, new_s_group, [g, [N1, N2, N3]])},
      %% monitor_nodes/1: nodedown of a fellow member reaches the subscriber
      {monitor_nodes, monitor_probe(N1, N3)},
      {monitor_not_boolean, rpc:call(N1, s_group, monitor_nodes, [maybe])},
      %% attributes on other nodes
      {add_attributes_2, rpc:call(N1, s_group, add_attributes, [[N2], [gpu]])},
      {choose_nodes, lists:member(N2, rpc:call(N1, s_group, choose_nodes, [[{attribute, gpu}]]))},
      {remove_attributes_2, rpc:call(N1, s_group, remove_attributes, [[N2], [gpu]])},
      {choose_after_remove, lists:member(N2, rpc:call(N1, s_group, choose_nodes, [[{attribute, gpu}]]))},
      {attributes_not_list, rpc:call(N1, s_group, add_attributes, [gpu])},
      %% via: a gen_server registered in group g, called by name from another member
      {via_start, via_start(N1)},
      {via_call, rpc:call(N2, gen_server, call, [{via, s_group, {g, svc}}, ping])},
      {via_second_start, via_start(N2)},
      {via_whereis_peer, is_pid(rpc:call(N2, s_group, whereis_name, [{g, svc}]))}
    ],
    [io:format("API ~-22s ~p~n", [K, V]) || {K, V} <- R],
    Want = [{new_s_group_1, {ok, 2, true}}, {monitor_nodes, ok}, {monitor_not_boolean, {error, not_boolean}},
            {add_attributes_2, [N2]}, {choose_nodes, true}, {remove_attributes_2, [N2]},
            {choose_after_remove, false}, {attributes_not_list, {error, parameter_should_be_a_list}},
            {via_start, ok}, {via_call, pong}, {via_second_start, already_started}, {via_whereis_peer, true}],
    Bad = [{K, V, W} || {K, W} <- Want, {K2, V} <- R, K2 =:= K, V =/= W],
    io:format("API RESULT: ~s~n", [case Bad of [] -> "pass"; _ -> io_lib:format("FAIL ~p", [Bad]) end]),
    ok.

own(N) -> lists:sort([{G, lists:sort(Ns)} || {G, Ns} <- rpc:call(N, s_group, own_s_groups, [])]).

monitor_probe(At, Victim) ->
    Self = self(),
    Pid = spawn(At, fun() ->
                            ok = s_group:monitor_nodes(true),
                            Self ! subscribed,
                            receive {nodedown, Victim} -> Self ! got_nodedown
                            after 20000 -> Self ! no_nodedown
                            end
                    end),
    receive subscribed -> ok after 5000 -> exit(Pid, kill) end,
    rpc:cast(Victim, erlang, halt, []),
    receive got_nodedown -> ok; no_nodedown -> no_nodedown after 25000 -> timeout end.

%% Start the probe server under {via, s_group, {g, svc}} on Node (it lives
%% there; the start blocks until registration succeeded or failed).
via_start(Node) ->
    Self = self(),
    spawn(Node, fun() ->
                        R = gen_server:start({via, s_group, {g, svc}}, ?MODULE, [], []),
                        Self ! {via, case R of
                                         {ok, _} -> ok;
                                         {error, {already_started, _}} -> already_started;
                                         Other -> Other
                                     end}
                end),
    receive {via, X} -> X after 15000 -> timeout end.

init([]) -> {ok, #{}}.
handle_call(ping, _From, S) -> {reply, pong, S}.
handle_cast(_, S) -> {noreply, S}.
