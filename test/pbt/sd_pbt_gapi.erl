%% P18 stock `global` API on s_group members (JPDC'16 sec. 3.1.4).
%%
%% JPDC'16: "global:whereis_name(Name) ... On an s group node the function
%% returns 'undefined' because the s group name is not specified", and
%% global:registered_names() "can be used on both s group and free nodes".
%% The paper says nothing about global:register_name/2 on a member; 19.3
%% refuses it with {no, the_node_is_not_free} (global.erl register_name/2,3
%% check application env kernel s_groups, which s_group keeps as a mirror of
%% current membership).
%%
%% L1 issues only s_group operations and L5 runs only free nodes, so neither
%% sees this surface. The probe records one outcome list per runtime; compare
%% them line by line.
%%
%%   sd_pbt_gapi:run()
-module(sd_pbt_gapi).

-export([run/0]).

run() ->
    _ = (try ets:new(sd_pbt, [named_table, public, set]) catch _:_ -> ok end),
    ok = sd_pbt_cluster:reset(),
    N = fun(X) -> list_to_atom(X ++ "@pbt.sd.lab") end,
    {N1, N2} = {N("n1"), N("n2")},
    Spawn = fun(Node) -> rpc:call(Node, erlang, spawn, [timer, sleep, [infinity]]) end,
    Ref = fun(P) when is_pid(P) -> {pid_on, short(node(P))}; (X) -> X end,
    {F, G, H} = {Spawn(N1), Spawn(N1), Spawn(N1)},
    %% Free node baseline.
    R = [{free_register, rpc:call(N1, global, register_name, [p18_free, F])}],
    timer:sleep(500),
    {ok, g1, _} = rpc:call(N1, s_group, new_s_group, [g1, [N1, N2]]),
    timer:sleep(2000),
    R2 = R ++
        [{member_register, rpc:call(N1, global, register_name, [p18_member, G])},
         {member_re_register, rpc:call(N1, global, re_register_name, [p18_member_re, G])},
         {member_whereis_own, Ref(rpc:call(N1, global, whereis_name, [p18_member]))},
         {member_whereis_peer, Ref(rpc:call(N2, global, whereis_name, [p18_member]))},
         {member_whereis_pre_join_free_name, Ref(rpc:call(N1, global, whereis_name, [p18_free]))},
         {member_registered_names, lists:sort(norm(rpc:call(N1, global, registered_names, [])))},
         {member_send, send_shape(rpc:call(N1, global, send, [p18_member, hello]))},
         {member_unregister_free_name, rpc:call(N1, global, unregister_name, [p18_free])}],
    ok = rpc:call(N2, s_group, remove_nodes, [g1, [N1]]),
    timer:sleep(2000),
    R3 = R2 ++
        [{freed_register, rpc:call(N1, global, register_name, [p18_freed, H])},
         {freed_whereis, Ref(rpc:call(N1, global, whereis_name, [p18_freed]))}],
    [io:format("P18 ~-36s ~p~n", [K, V]) || {K, V} <- R3],
    R3.

norm(L) when is_list(L) -> [X || X <- L, is_p18(X)];
norm(X) -> X.

is_p18({_G, Nm}) -> is_p18(Nm);
is_p18(Nm) when is_atom(Nm) -> lists:prefix("p18_", atom_to_list(Nm));
is_p18(_) -> false.

send_shape(P) when is_pid(P) -> {pid_on, short(node(P))};
send_shape({badrpc, {'EXIT', {badarg, _}}}) -> {'EXIT', badarg};
send_shape(X) -> X.

short(Node) -> lists:takewhile(fun(C) -> C =/= $@ end, atom_to_list(Node)).
