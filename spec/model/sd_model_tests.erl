%% Tests of the executable semantics itself (no runtime involved).
%%
%%   * one or more unit tests per D3.3 rule, citing the clause they pin
%%   * a seeded random walk over all operations checking the D3.3 state
%%     property and the AST'14 4.5 invariants after every step
%%     ("the same model can also be used to test the semantics itself",
%%     AST'14 5)
-module(sd_model_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, 'a@h'). -define(B, 'b@h'). -define(C, 'c@h'). -define(D, 'd@h').
-define(H, 'h@h').
-define(P(N, I), {pid, N, I}).

init() ->
    sd_model:initial_state([{?A, normal}, {?B, normal}, {?C, normal},
                            {?D, normal}, {?H, hidden}]).

with_g1() ->
    {S, {g1, [?A, ?B, ?C]}} = sd_model:new_s_group(init(), g1, [?A, ?B, ?C], ?A),
    S.

%%--------------------------------------------------------------------
%% Initial state / state property
%%--------------------------------------------------------------------

initial_partition_test() ->
    S = init(),
    ?assert(sd_model:partition_ok(S)),
    ?assertEqual(ok, sd_model:check_invariants(S)),
    ?assertEqual([{?H, []}], sd_model:free_hidden_groups(S)),
    ?assertEqual(4, length(sd_model:free_groups(S))).

%%--------------------------------------------------------------------
%% new_s_group (D3.3 4.2.1)
%%--------------------------------------------------------------------

new_s_group_requires_caller_in_nodes_test() ->
    ?assertMatch({_, error}, sd_model:new_s_group(init(), g1, [?B, ?C], ?A)).

new_s_group_interconnects_and_leaves_free_groups_test() ->
    S = with_g1(),
    ?assertEqual({g1, [?A, ?B, ?C], []}, sd_model:group(g1, S)),
    ?assertEqual({?A, normal, [?B, ?C], [g1]}, sd_model:node_record(?A, S)),
    %% R6: joined nodes leave their free groups
    ?assertEqual([{[?D], []}], sd_model:free_groups(S)),
    ?assertEqual(ok, sd_model:check_invariants(S)).

new_s_group_duplicate_name_is_error_test() ->            %% ERRATUM-4
    ?assertMatch({_, error}, sd_model:new_s_group(with_g1(), g1, [?A, ?D], ?A)).

%%--------------------------------------------------------------------
%% Names
%%--------------------------------------------------------------------

register_name_test() ->
    S0 = with_g1(),
    {S1, true} = sd_model:register_name(S0, g1, n, ?P(?B, 1), ?A),
    ?assertMatch({_, false}, sd_model:register_name(S1, g1, n, ?P(?C, 1), ?A)),  %% name taken
    ?assertMatch({_, false}, sd_model:register_name(S1, g1, m, ?P(?B, 1), ?A)),  %% pid taken
    ?assertMatch({_, false}, sd_model:register_name(S0, g1, n, ?P(?D, 1), ?D)),  %% non-member
    ?assertEqual({S1, ?P(?B, 1)}, sd_model:whereis_name(S1, g1, n, ?C)).

re_register_name_test() ->
    {S1, true} = sd_model:register_name(with_g1(), g1, n, ?P(?B, 1), ?A),
    {S2, true} = sd_model:re_register_name(S1, g1, n, ?P(?C, 1), ?B),
    ?assertEqual({S2, ?P(?C, 1)}, sd_model:whereis_name(S2, g1, n, ?A)),
    %% pid already registered (under any name) -> False
    ?assertMatch({_, false}, sd_model:re_register_name(S2, g1, m, ?P(?C, 1), ?A)).

unregister_name_always_true_test() ->                     %% ERRATUM-7, R2
    {S1, true} = sd_model:register_name(with_g1(), g1, n, ?P(?B, 1), ?A),
    {S2, true} = sd_model:unregister_name(S1, g1, n, ?A),
    ?assertEqual({S2, undefined}, sd_model:whereis_name(S2, g1, n, ?A)),
    ?assertEqual({S2, true}, sd_model:unregister_name(S2, g1, n, ?A)),
    ?assertEqual({S1, true}, sd_model:unregister_name(S1, g1, n, ?D)).

registered_names_test() ->
    {S1, true} = sd_model:register_name(with_g1(), g1, n, ?P(?B, 1), ?A),
    ?assertEqual({S1, [{g1, n}]}, sd_model:registered_names(S1, g1, ?C)),
    ?assertEqual({S1, []}, sd_model:registered_names(S1, g1, ?D)).

whereis_name_non_member_is_undefined_and_pure_test() ->
    {S1, true} = sd_model:register_name(with_g1(), g1, n, ?P(?B, 1), ?A),
    ?assertEqual({S1, undefined}, sd_model:whereis_name(S1, g1, n, ?D)).

whereis_name3_connects_test() ->
    {S1, true} = sd_model:register_name(with_g1(), g1, n, ?P(?B, 1), ?A),
    {S2, P} = sd_model:whereis_name(S1, ?A, g1, n, ?D),
    ?assertEqual(?P(?B, 1), P),
    {?D, normal, DCs, no_group} = sd_model:node_record(?D, S2),
    ?assert(lists:member(?A, DCs)),
    ?assertEqual(ok, sd_model:check_invariants(S2)).

send3_unknown_is_undefined_test() ->                     %% ERRATUM-3, R1
    S = with_g1(),
    ?assertEqual({S, undefined}, sd_model:send(S, g1, nope, ?A)).

send2_connects_to_pid_node_test() ->
    {S1, P} = sd_model:send_pid(with_g1(), ?P(?D, 1), ?D, ?A),
    ?assertEqual(?P(?D, 1), P),
    {?A, normal, ACs, _} = sd_model:node_record(?A, S1),
    ?assert(lists:member(?D, ACs)).

%%--------------------------------------------------------------------
%% Membership changes
%%--------------------------------------------------------------------

add_nodes_test() ->
    {S1, {g1, [?D]}} = sd_model:add_nodes(with_g1(), g1, [?D, ?A], ?B),  %% ERRATUM-5
    ?assertEqual({g1, [?A, ?B, ?C, ?D], []}, sd_model:group(g1, S1)),
    ?assertEqual([], sd_model:free_groups(S1)),
    ?assertEqual({?D, normal, [?A, ?B, ?C], [g1]}, sd_model:node_record(?D, S1)),
    ?assertMatch({_, error}, sd_model:add_nodes(with_g1(), g1, [?D], ?D)),  %% non-member
    ?assertEqual(ok, sd_model:check_invariants(S1)).

remove_nodes_keeps_connections_test() ->                  %% S5 / O1
    {S1, true} = sd_model:remove_nodes(with_g1(), g1, [?C], ?A),
    ?assertEqual({g1, [?A, ?B], []}, sd_model:group(g1, S1)),
    ?assertEqual({?C, normal, [?A, ?B], no_group}, sd_model:node_record(?C, S1)),
    ?assertEqual(ok, sd_model:check_invariants(S1)).

remove_nodes_preconditions_test() ->
    S = with_g1(),
    ?assertMatch({_, false}, sd_model:remove_nodes(S, g1, [?A], ?A)),  %% cannot remove itself
    ?assertMatch({_, false}, sd_model:remove_nodes(S, g1, [?D], ?A)),  %% not a member
    ?assertMatch({_, false}, sd_model:remove_nodes(S, g1, [?B], ?D)).  %% caller not a member

removed_node_rejoins_free_group_via_connections_test() ->
    %% C becomes free; it is connected to A and B (s_group nodes), not to any
    %% free normal node, so it forms a new free normal group by itself.
    {S1, true} = sd_model:remove_nodes(with_g1(), g1, [?C], ?A),
    ?assertEqual([{[?C], []}, {[?D], []}], sd_model:free_groups(S1)).

delete_s_group_test() ->
    {S1, true} = sd_model:delete_s_group(with_g1(), g1, ?B),
    ?assertEqual(false, sd_model:group(g1, S1)),
    ?assertEqual(no_group, element(4, sd_model:node_record(?A, S1))),
    ?assertEqual(ok, sd_model:check_invariants(S1)),
    ?assertMatch({_, false}, sd_model:delete_s_group(with_g1(), g1, ?D)).

own_nodes_and_groups_test() ->
    {S1, {g2, _}} = sd_model:new_s_group(with_g1(), g2, [?C, ?D], ?C),
    ?assertEqual({S1, [?A, ?B, ?C, ?D]}, sd_model:own_nodes(S1, ?C)),
    ?assertEqual({S1, [?A, ?B, ?C]}, sd_model:own_nodes(S1, g1, ?C)),
    ?assertEqual({S1, []}, sd_model:own_nodes(S1, g1, ?D)),
    ?assertEqual({S1, [{g1, [?A, ?B, ?C]}, {g2, [?C, ?D]}]}, sd_model:own_s_groups(S1, ?C)),
    ?assertEqual({S1, []}, sd_model:own_s_groups(S1, ?H)),
    ?assertEqual({S1, [?H]}, sd_model:own_nodes(S1, ?H)).

%%--------------------------------------------------------------------
%% AddConnections outcomes (D3.3 4.2.2)
%%--------------------------------------------------------------------

add_connections_merges_free_normal_groups_test() ->
    S1 = sd_model:add_connections(?A, ?B, init()),
    ?assert(sd_model:same_free_group(?A, ?B, S1)),
    ?assertEqual(ok, sd_model:check_invariants(S1)).

add_connections_hidden_does_not_merge_test() ->
    S1 = sd_model:add_connections(?H, ?A, init()),
    ?assertNot(sd_model:same_free_group(?H, ?A, S1)),
    {?H, hidden, [?A], no_group} = sd_model:node_record(?H, S1).

add_connections_s_group_to_free_is_plain_link_test() ->
    S1 = sd_model:add_connections(?A, ?D, with_g1()),
    {?D, normal, [?A], no_group} = sd_model:node_record(?D, S1),
    ?assertEqual([{[?D], []}], sd_model:free_groups(S1)).

%%--------------------------------------------------------------------
%% Random walk over the semantics: invariants hold after every step
%%--------------------------------------------------------------------

random_walk_invariants_test_() ->
    {timeout, 60, fun() -> [walk(Seed, 300) || Seed <- lists:seq(1, 200)] end}.

walk(Seed, Steps) ->
    rand:seed(exsplus, {Seed, Seed * 7, Seed * 13}),
    Nodes = [{list_to_atom("n" ++ integer_to_list(I) ++ "@h"), normal} || I <- lists:seq(1, 6)]
        ++ [{'x1@h', hidden}, {'x2@h', hidden}],
    walk_loop(sd_model:initial_state(Nodes), [N || {N, _} <- Nodes], Steps, Seed, []).

walk_loop(_S, _Ns, 0, _Seed, _Trace) ->
    ok;
walk_loop(S, Ns, K, Seed, Trace) ->
    Op = random_op(S, Ns),
    {S1, _Value} = apply_op(S, Op),
    case sd_model:check_invariants(S1) of
        ok -> walk_loop(S1, Ns, K - 1, Seed, [Op | Trace]);
        Err -> erlang:error({invariant_broken, {seed, Seed}, Err, lists:reverse([Op | Trace])})
    end.

pick(L) -> lists:nth(rand:uniform(length(L)), L).
some(L) -> lists:usort([pick(L) || _ <- lists:seq(1, rand:uniform(length(L)))]).

random_op(S, Ns) ->
    Groups = [G || {G, _, _} <- sd_model:groups(S)],
    G = case Groups =/= [] andalso rand:uniform(3) > 1 of
            true -> pick(Groups);
            false -> pick([g1, g2, g3, g4])
        end,
    Ni = pick(Ns),
    Pid = {pid, pick(Ns), rand:uniform(3)},
    Name = pick([a, b, c]),
    %% weights after D3.3 Fig. 5.4 (no node_down_up: M ignores failures)
    pick(lists:append([
      lists:duplicate(5, {new_s_group, G, some(Ns), Ni}),
      lists:duplicate(5, {add_nodes, G, some(Ns), Ni}),
      lists:duplicate(5, {remove_nodes, G, some(Ns), Ni}),
      lists:duplicate(5, {delete_s_group, G, Ni}),
      lists:duplicate(10, {register_name, G, Name, Pid, Ni}),
      lists:duplicate(10, {whereis_name, G, Name, Ni}),
      lists:duplicate(10, {re_register_name, G, Name, Pid, Ni}),
      lists:duplicate(10, {unregister_name, G, Name, Ni}),
      lists:duplicate(10, {send, G, Name, Ni}),
      lists:duplicate(3, {whereis_name3, pick(Ns), G, Name, Ni}),
      lists:duplicate(3, {send_pid, Pid, Ni})])).

apply_op(S, {new_s_group, G, Nis, Ni}) -> sd_model:new_s_group(S, G, Nis, Ni);
apply_op(S, {add_nodes, G, Nis, Ni}) -> sd_model:add_nodes(S, G, Nis, Ni);
apply_op(S, {remove_nodes, G, Nis, Ni}) -> sd_model:remove_nodes(S, G, Nis, Ni);
apply_op(S, {delete_s_group, G, Ni}) -> sd_model:delete_s_group(S, G, Ni);
apply_op(S, {register_name, G, N, P, Ni}) -> sd_model:register_name(S, G, N, P, Ni);
apply_op(S, {re_register_name, G, N, P, Ni}) -> sd_model:re_register_name(S, G, N, P, Ni);
apply_op(S, {unregister_name, G, N, Ni}) -> sd_model:unregister_name(S, G, N, Ni);
apply_op(S, {whereis_name, G, N, Ni}) -> sd_model:whereis_name(S, G, N, Ni);
apply_op(S, {whereis_name3, Ni1, G, N, Ni}) -> sd_model:whereis_name(S, Ni1, G, N, Ni);
apply_op(S, {send, G, N, Ni}) -> sd_model:send(S, G, N, Ni);
apply_op(S, {send_pid, {pid, PN, _} = P, Ni}) -> sd_model:send_pid(S, P, PN, Ni).
