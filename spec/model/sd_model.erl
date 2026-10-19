%% Executable transcription of the SD Erlang s_group operational semantics,
%% RELEASE D3.3 ch. 4 (Fig. 4.1, sections 4.2.1-4.2.2), restated in TOPLAS'17
%% Fig. 14-15. "As the semantics is concrete it can readily be made executable
%% in Erlang, with lists replacing sets throughout" (TOPLAS'17 V.iii).
%%
%% Pure: no processes, no distribution. Sets are kept as sorted, duplicate-free
%% lists (ordsets) so that two equal states are =:=. Every exported operation
%% has the transition form of D3.3 4.2:
%%
%%     (State, Command, Ni) -> {State', Value}
%%
%% Values are M-values (true | false | undefined | error | Pid | ...). Mapping
%% implementation return values onto M-values is NOT done here; that is the
%% harness's job, governed by spec/deviations.yml.
%%
%% Where the printed rules are ambiguous or self-inconsistent, the choice made
%% is marked ERRATUM-n and listed in spec/model/ERRATA.md.
%%
%% Must compile on OTP 20 (historical runtime) and current OTP (host checks).
-module(sd_model).

-export([node_down_up/2]).
-export([initial_state/1,
         %% the fifteen SD Erlang functions (D3.3 4.2.1)
         register_name/5, re_register_name/5, unregister_name/4,
         registered_names/3, whereis_name/4, whereis_name/5,
         send/4, send/5, send_pid/4,
         new_s_group/4, add_nodes/4, delete_s_group/3, remove_nodes/4,
         own_nodes/2, own_nodes/3, own_s_groups/2,
         %% auxiliary functions (D3.3 4.2.2), exported for testing
         is_s_group_node/2, is_s_group_s_node/3,
         is_free_normal_node/2, is_free_hidden_node/2,
         same_free_group/3, same_s_group/3,
         add_connections/3, inter_connect_nodes/2, find_name/4,
         own_group_nis/2,
         %% invariants
         partition_ok/1, check_invariants/1,
         %% accessors
         groups/1, free_groups/1, free_hidden_groups/1, nodes/1,
         node_record/2, group/2]).

-export_type([state/0, node_id/0, s_group_name/0, pid_ref/0]).

-type node_id()      :: node().
-type s_group_name() :: atom().
-type name()         :: term().
%% Pids are normalised stand-ins {pid, Node, Index}: node(p) must be known
%% for send/2's AddConnections, and real pids differ between runtimes.
-type pid_ref()      :: {pid, node_id(), non_neg_integer()}.
-type namespace()    :: [{name(), pid_ref()}].
-type node_type()    :: normal | hidden.
-type gr_names()     :: no_group | [s_group_name()].

-record(st, {grs = [] :: [{s_group_name(), [node_id()], namespace()}],
             fgs = [] :: [{[node_id()], namespace()}],
             fhs = [] :: [{node_id(), namespace()}],
             nds = [] :: [{node_id(), node_type(), [node_id()], gr_names()}]}).

-opaque state() :: #st{}.

%%====================================================================
%% Initial state
%%====================================================================

%% All nodes free and unconnected: each normal node is its own free normal
%% group (a maximal transitively connected set of one), each hidden node its
%% own free hidden group. Mirrors D3.3 5.2's 12 normal + 2 hidden setup.
-spec initial_state([{node_id(), node_type()}]) -> state().
initial_state(Nodes) ->
    #st{grs = [],
        fgs = lists:sort([{[N], []} || {N, normal} <- Nodes]),
        fhs = lists:sort([{N, []} || {N, hidden} <- Nodes]),
        nds = lists:sort([{N, T, [], no_group} || {N, T} <- Nodes])}.

%%====================================================================
%% SD Erlang functions (D3.3 4.2.1)
%%====================================================================

%% register_name: add (n,p) iff ni is a member of s and neither n nor p is
%% already in the namespace.
register_name(S, Grp, Name, Pid, Ni) ->
    case member_group(Ni, Grp, S) of
        {ok, {Grp, Nis, Ns}} ->
            case lists:keymember(Name, 1, Ns) orelse lists:keymember(Pid, 2, Ns) of
                false -> {put_group({Grp, Nis, ordsets:add_element({Name, Pid}, Ns)}, S), true};
                true -> {S, false}
            end;
        error ->
            {S, false}
    end.

%% re_register_name: iff p is not already registered, ns - {(n,_)} + {(n,p)}.
re_register_name(S, Grp, Name, Pid, Ni) ->
    case member_group(Ni, Grp, S) of
        {ok, {Grp, Nis, Ns}} ->
            case lists:keymember(Pid, 2, Ns) of
                false ->
                    Ns1 = ordsets:add_element({Name, Pid}, lists:keydelete(Name, 1, Ns)),
                    {put_group({Grp, Nis, Ns1}, S), true};
                true ->
                    {S, false}
            end;
        error ->
            {S, false}
    end.

%% unregister_name: removes (n,_) if present; True in every case
%% (AST'14 5: "the semantics specified that unregister_name always returns True").
unregister_name(S, Grp, Name, Ni) ->
    case member_group(Ni, Grp, S) of
        {ok, {Grp, Nis, Ns}} -> {put_group({Grp, Nis, lists:keydelete(Name, 1, Ns)}, S), true};
        error -> {S, true}
    end.

%% registered_names(s): OutputNs(s, ns) for members, {} otherwise.
registered_names(S, Grp, Ni) ->
    case member_group(Ni, Grp, S) of
        {ok, {Grp, _, Ns}} -> {S, lists:usort([{Grp, N} || {N, _} <- Ns])};
        error -> {S, []}
    end.

%% whereis_name/2: FindName for members, undefined otherwise. No state change.
whereis_name(S, Grp, Name, Ni) ->
    case is_s_group_s_node(Ni, Grp, S) of
        true -> {S, find_name(Ni, Grp, Name, S)};
        false -> {S, undefined}
    end.

%% whereis_name/3: connect ni to ni', then FindName on ni'.
whereis_name(S, Ni1, Grp, Name, Ni) ->
    S1 = add_connections(Ni, Ni1, S),
    {S1, find_name(Ni1, Grp, Name, S1)}.

%% send(p, m): AddConnections(ni, node(p)); returns p. Message passing is not
%% modelled. PidNode is node(p), supplied by the caller (pids are opaque here).
send_pid(S, Pid, PidNode, Ni) ->
    {add_connections(Ni, PidNode, S), Pid}.

%% send/3 = whereis_name/2 then send/2 (D3.3 Listing 4.1). M is silent on the
%% undefined case; we return undefined with no state change (ERRATUM-3).
send(S, Grp, Name, Ni) ->
    send_resolved(whereis_name(S, Grp, Name, Ni), Ni).

%% send/4 = whereis_name/3 then send/2 (D3.3 Listing 4.2).
send(S, Ni1, Grp, Name, Ni) ->
    send_resolved(whereis_name(S, Ni1, Grp, Name, Ni), Ni).

send_resolved({S1, undefined}, _Ni) ->
    {S1, undefined};
send_resolved({S1, {pid, PidNode, _} = Pid}, Ni) ->
    send_pid(S1, Pid, PidNode, Ni).

%% new_s_group(s, nis): requires ni in nis. Assumption A1 (unique names) is a
%% precondition for callers; a duplicate name returns error here (ERRATUM-4).
new_s_group(S = #st{grs = Grs}, Grp, Nis0, Ni) ->
    Nis = lists:usort(Nis0),
    case lists:member(Ni, Nis) andalso not lists:keymember(Grp, 1, Grs) of
        true ->
            Nds1 = inter_connect_nodes(Nis, S#st.nds),
            Nds2 = add_s_group(Grp, Nis, Nds1),
            {Fgs1, Fhs1} = remove_nodes_from_free(Nis, S#st.fgs, S#st.fhs),
            {S#st{grs = lists:sort([{Grp, Nis, []} | Grs]), fgs = Fgs1, fhs = Fhs1, nds = Nds2},
             {Grp, Nis}};
        false ->
            {S, error}
    end.

%% add_nodes(s, nis): ni must be a member of s; nis are new members (disjoint
%% union in the rule; already-members are ignored, ERRATUM-5).
add_nodes(S, Grp, Nis0, Ni) ->
    case member_group(Ni, Grp, S) of
        {ok, {Grp, Members, Ns}} ->
            Nis = lists:usort(Nis0) -- Members,
            All = lists:usort(Members ++ Nis),
            Nds1 = inter_connect_nodes(All, S#st.nds),
            Nds2 = add_s_group(Grp, Nis, Nds1),
            {Fgs1, Fhs1} = remove_nodes_from_free(Nis, S#st.fgs, S#st.fhs),
            S1 = put_group({Grp, All, Ns}, S#st{fgs = Fgs1, fhs = Fhs1, nds = Nds2}),
            {S1, {Grp, Nis}};
        error ->
            {S, error}
    end.

%% delete_s_group(s): ni must be a member; membership removed from all its
%% nodes, newly free nodes placed in free groups.
delete_s_group(S = #st{grs = Grs}, Grp, Ni) ->
    case member_group(Ni, Grp, S) of
        {ok, {Grp, Members, _Ns}} ->
            Nds1 = remove_s_group(Grp, Members, S#st.nds),
            S1 = new_free_nodes(S#st{grs = lists:keydelete(Grp, 1, Grs), nds = Nds1}),
            {S1, true};
        error ->
            {S, false}
    end.

%% remove_nodes(s, nis): ni not in nis, ni a member, nis members of s.
%% Connections are unchanged (cs untouched by RemoveSGroup), consistent with
%% JPDC'16 3.1.4 ("keeps its existing connections").
remove_nodes(S, Grp, Nis0, Ni) ->
    Nis = lists:usort(Nis0),
    case member_group(Ni, Grp, S) of
        {ok, {Grp, Members, Ns}} ->
            case (not lists:member(Ni, Nis)) andalso (Nis -- Members) =:= [] of
                true ->
                    S1 = put_group({Grp, Members -- Nis, Ns}, S),
                    Nds1 = remove_s_group(Grp, Nis, S1#st.nds),
                    {new_free_nodes(S1#st{nds = Nds1}), true};
                false ->
                    {S, false}
            end;
        error ->
            {S, false}
    end.

own_nodes(S, Ni) ->
    {S, own_group_nis(Ni, S)}.

own_nodes(S, Grp, Ni) ->
    case member_group(Ni, Grp, S) of
        {ok, {Grp, Members, _}} -> {S, Members};
        error -> {S, []}
    end.

own_s_groups(S, Ni) ->
    case is_s_group_node(Ni, S) of
        true -> {S, lists:sort([{G, Nis} || {G, Nis, _} <- S#st.grs, lists:member(Ni, Nis)])};
        false -> {S, []}
    end.

%%====================================================================
%% Auxiliary functions (D3.3 4.2.2)
%%====================================================================

is_s_group_node(Ni, #st{grs = Grs}) ->
    lists:any(fun({_, Nis, _}) -> lists:member(Ni, Nis) end, Grs).

is_s_group_s_node(Ni, Grp, S) ->
    member_group(Ni, Grp, S) =/= error.

is_free_normal_node(Ni, #st{fgs = Fgs}) ->
    lists:any(fun({Nis, _}) -> lists:member(Ni, Nis) end, Fgs).

is_free_hidden_node(Ni, #st{fhs = Fhs}) ->
    lists:keymember(Ni, 1, Fhs).

same_free_group(A, B, #st{fgs = Fgs}) ->
    lists:any(fun({Nis, _}) -> lists:member(A, Nis) andalso lists:member(B, Nis) end, Fgs).

same_s_group(A, B, #st{grs = Grs}) ->
    lists:any(fun({_, Nis, _}) -> lists:member(A, Nis) andalso lists:member(B, Nis) end, Grs).

%% AddConnections(ni, ni'): three outcomes, in rule order.
add_connections(Ni, Ni, S) ->
    S;                                        %% ERRATUM-6: self-connection is a no-op
add_connections(Ni, Ni1, S = #st{fgs = Fgs, nds = Nds}) ->
    case same_free_group(Ni, Ni1, S) orelse same_s_group(Ni, Ni1, S) of
        true ->
            S;
        false ->
            case (is_s_group_node(Ni, S) andalso not same_s_group(Ni, Ni1, S))
                orelse is_free_hidden_node(Ni, S)
                orelse (is_free_normal_node(Ni, S) andalso not is_free_normal_node(Ni1, S)) of
                true ->
                    S#st{nds = inter_connect_nodes([Ni, Ni1], Nds)};
                false ->
                    case {free_group_of(Ni, Fgs), free_group_of(Ni1, Fgs)} of
                        {{Nis1, Ns1} = G1, {Nis2, Ns2} = G2} when G1 =/= G2 ->
                            Merged = {lists:usort(Nis1 ++ Nis2), lists:usort(Ns1 ++ Ns2)},
                            Fgs1 = lists:sort([Merged | (Fgs -- [G1, G2])]),
                            S#st{fgs = Fgs1, nds = inter_connect_nodes(element(1, Merged), Nds)};
                        _ ->
                            S
                    end
            end
    end.

%% InterConnectNodes(nis, nds): every node in nis gains connections to the others.
inter_connect_nodes(Nis, Nds) ->
    lists:sort([case lists:member(N, Nis) of
                    true -> {N, T, lists:usort(Cs ++ Nis) -- [N], Gs};
                    false -> Nd
                end || {N, T, Cs, Gs} = Nd <- Nds]).

%% AddSGroup / AddSGroupS
add_s_group(Grp, Nis, Nds) ->
    lists:sort([case lists:member(N, Nis) of
                    true -> {N, T, Cs, add_s_group_s(Grp, Gs)};
                    false -> Nd
                end || {N, T, Cs, Gs} = Nd <- Nds]).

add_s_group_s(Grp, no_group) -> [Grp];
add_s_group_s(Grp, Gs) -> ordsets:add_element(Grp, Gs).

%% RemoveSGroup: remove s from gr_names of nis. An empty list is left for
%% NewFreeNodes to turn into NoGroup.
remove_s_group(Grp, Nis, Nds) ->
    lists:sort([case lists:member(N, Nis) andalso is_list(Gs) of
                    true -> {N, T, Cs, Gs -- [Grp]};
                    false -> Nd
                end || {N, T, Cs, Gs} = Nd <- Nds]).

%% RemoveNodes(nis, fgs, fhs): take nis out of free groups. Free groups left
%% empty are dropped (ERRATUM-2).
remove_nodes_from_free(Nis, Fgs, Fhs) ->
    Fgs1 = [{Ns -- Nis, Names} || {Ns, Names} <- Fgs],
    {lists:sort([G || {Ns, _} = G <- Fgs1, Ns =/= []]),
     lists:sort([H || {N, _} = H <- Fhs, not lists:member(N, Nis)])}.

%% FindName(ni, s, n): s is NoGroup or an s_group name.
find_name(Ni, no_group, Name, S = #st{fgs = Fgs, fhs = Fhs}) ->
    case node_record(Ni, S) of
        {Ni, normal, _, _} ->
            case free_group_of(Ni, Fgs) of
                {_, Ns} -> lookup(Name, Ns);
                none -> undefined
            end;
        {Ni, hidden, _, _} ->
            case lists:keyfind(Ni, 1, Fhs) of
                {Ni, Ns} -> lookup(Name, Ns);
                false -> undefined
            end;
        false ->
            undefined
    end;
find_name(Ni, Grp, Name, S) ->
    case member_group(Ni, Grp, S) of
        {ok, {Grp, _, Ns}} -> lookup(Name, Ns);
        error -> undefined
    end.

%% NewFreeNodes: nodes left with no s_group become NoGroup and join free
%% groups by type. ERRATUM-1: the free-normal placement uses the NoGroup-updated
%% node set (nds'), not the original nds as printed.
new_free_nodes(S = #st{fgs = Fgs, fhs = Fhs, nds = Nds}) ->
    Nds1 = lists:sort([case Gs of
                           [] -> {N, T, Cs, no_group};
                           _ -> Nd
                       end || {N, T, Cs, Gs} = Nd <- Nds]),
    NewFree = [Nd || {_, _, _, []} = Nd <- Nds],
    Fhs1 = lists:sort(Fhs ++ [{N, []} || {N, hidden, _, _} <- NewFree]),
    NewNormal = [N || {N, normal, _, _} <- NewFree],
    {Fgs1, Nds2} = add_free_normal_group(NewNormal, NewFree, Fgs, Nds1),
    S#st{fgs = Fgs1, fhs = Fhs1, nds = Nds2}.

%% AddFreeNormalGroup + MergeFreeNormalGroups.
add_free_normal_group([], _NewFree, Fgs, Nds) ->
    {Fgs, Nds};
add_free_normal_group(Nis, NewFree, Fgs, Nds) ->
    Css = lists:usort(lists:append([Cs || {N, normal, Cs, _} <- NewFree, lists:member(N, Nis)])),
    %% css': connections that are members of existing free normal groups
    Css1 = [C || C <- Css, free_group_of(C, Fgs) =/= none],
    case Css1 of
        [] ->
            %% "In case a new node has no connections with existing free normal
            %% nodes a new free normal group is created" (one group for all nis).
            {lists:sort([{lists:usort(Nis), []} | Fgs]), Nds};
        _ ->
            FgsR = lists:usort([free_group_of(C, Fgs) || C <- Css1]),
            Nis2 = lists:usort(lists:append([Ns || {Ns, _} <- FgsR]) ++ Nis),
            Names = lists:usort(lists:append([Nm || {_, Nm} <- FgsR])),
            {lists:sort([{Nis2, Names} | (Fgs -- FgsR)]), inter_connect_nodes(Nis2, Nds)}
    end.

%% OwnGroupNis / OwnSGroupNis
own_group_nis(Ni, S = #st{fgs = Fgs}) ->
    case {is_free_normal_node(Ni, S), is_free_hidden_node(Ni, S)} of
        {true, _} -> {Nis, _} = free_group_of(Ni, Fgs), Nis;
        {_, true} -> [Ni];
        _ -> lists:usort([Ni | lists:append([Nis || {_, Nis, _} <- S#st.grs, lists:member(Ni, Nis)])])
    end.

%%====================================================================
%% Invariants
%%====================================================================

%% D3.3 4.1 "SD Erlang State Property": s_group nodes, free normal nodes and
%% free hidden nodes partition the node set.
partition_ok(S = #st{nds = Nds}) ->
    All = lists:sort([N || {N, _, _, _} <- Nds]),
    SG = lists:usort(lists:append([Nis || {_, Nis, _} <- S#st.grs])),
    FG = lists:append([Nis || {Nis, _} <- S#st.fgs]),
    FH = [N || {N, _} <- S#st.fhs],
    Parts = SG ++ FG ++ FH,
    lists:sort(Parts) =:= All
        andalso ordsets:intersection(SG, lists:sort(FG)) =:= []
        andalso ordsets:intersection(SG, lists:sort(FH)) =:= [].

%% Partition plus per-node consistency (AST'14 4.5 lists these as useful
%% generic invariants; R7 is the gr_names one).
check_invariants(S = #st{nds = Nds, grs = Grs}) ->
    Problems =
        [partition || not partition_ok(S)] ++
        [{gr_names, N} || {N, _, _, Gs} <- Nds,
                          Gs =/= no_group,
                          lists:sort(Gs) =/= lists:sort([G || {G, Nis, _} <- Grs, lists:member(N, Nis)])] ++
        [{no_group_but_member, N} || {N, _, _, no_group} <- Nds, is_s_group_node(N, S)] ++
        [{empty_s_group_list, N} || {N, _, _, []} <- Nds] ++
        [{asymmetric_connection, A, B} || {A, _, Cs, _} <- Nds, B <- Cs,
                                          not lists:member(A, connections_of(B, Nds))],
    case Problems of
        [] -> ok;
        _ -> {error, Problems}
    end.

%%====================================================================
%% Accessors and helpers
%%====================================================================

groups(#st{grs = Grs}) -> Grs.
free_groups(#st{fgs = Fgs}) -> Fgs.
free_hidden_groups(#st{fhs = Fhs}) -> Fhs.
nodes(#st{nds = Nds}) -> Nds.

node_record(Ni, #st{nds = Nds}) -> lists:keyfind(Ni, 1, Nds).

group(Grp, #st{grs = Grs}) -> lists:keyfind(Grp, 1, Grs).

member_group(Ni, Grp, #st{grs = Grs}) ->
    case lists:keyfind(Grp, 1, Grs) of
        {Grp, Nis, _} = G ->
            case lists:member(Ni, Nis) of
                true -> {ok, G};
                false -> error
            end;
        false ->
            error
    end.

put_group({Grp, _, _} = G, S = #st{grs = Grs}) ->
    S#st{grs = lists:sort(lists:keystore(Grp, 1, Grs, G))}.

free_group_of(Ni, Fgs) ->
    case [G || {Nis, _} = G <- Fgs, lists:member(Ni, Nis)] of
        [G] -> G;
        [] -> none
    end.

connections_of(N, Nds) ->
    case lists:keyfind(N, 1, Nds) of
        {N, _, Cs, _} -> Cs;
        false -> []
    end.

lookup(Name, Ns) ->
    case lists:keyfind(Name, 1, Ns) of
        {Name, P} -> P;
        false -> undefined
    end.

%%====================================================================
%% Failures (proposal M1, decisions D-7..D-10, 2026-10-19)
%%====================================================================

%% node_down_up(ni): ni crashes and restarts from its record.
%%   - Membership is configuration, not liveness (D3.3 2.1, 2.3): unchanged.
%%   - Every name whose pid lives on ni is removed, from every namespace
%%     (stock global's rule).
%%   - ni loses all connections; on restart it reconnects to the members of
%%     its groups (its record names them, D-7); a free ni stays unconnected
%%     and is its own free group.
-spec node_down_up(state(), node_id()) -> {state(), ok}.
node_down_up(S = #st{grs = Grs, fgs = Fgs, fhs = Fhs, nds = Nds}, Ni) ->
    Keep = fun(Ns) -> [{Nm, P} || {Nm, {pid, PN, _} = P} <- Ns, PN =/= Ni] end,
    Grs1 = [{G, Nis, Keep(Ns)} || {G, Nis, Ns} <- Grs],
    Fgs0 = [{Nis, Keep(Ns)} || {Nis, Ns} <- Fgs],
    Fhs0 = [{N, case N of Ni -> []; _ -> Keep(Ns) end} || {N, Ns} <- Fhs],
    Nds0 = lists:sort([case N of
                           Ni -> {N, T, [], Gs};
                           _ -> {N, T, Cs -- [Ni], Gs}
                       end || {N, T, Cs, Gs} <- Nds]),
    {Ni, _, _, MyGs} = lists:keyfind(Ni, 1, Nds0),
    S1 = case MyGs of
             no_group ->
                 Fgs1 = case free_group_of(Ni, Fgs0) of
                            none -> Fgs0;
                            {Nis, Names} = FG ->
                                Rest = [{Nis -- [Ni], Names} || Nis =/= [Ni]],
                                lists:sort([{[Ni], []} | Rest ++ (Fgs0 -- [FG])])
                        end,
                 S#st{grs = Grs1, fgs = Fgs1, fhs = Fhs0, nds = Nds0};
             Gs ->
                 Mates = lists:usort(lists:append([Nis || {G, Nis, _} <- Grs1, lists:member(G, Gs)])),
                 S#st{grs = Grs1, fgs = Fgs0, fhs = Fhs0, nds = inter_connect_nodes(Mates, Nds0)}
         end,
    {S1, ok}.

