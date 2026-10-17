%% PROTOTYPE port candidate (design B, library-only) of SD Erlang s_groups on
%% stock OTP >= 25 (target 29.1.2). Purpose: give the verification stack
%% (spec/VERIFICATION_STRATEGY.md) a real modern implementation to judge.
%% It is NOT the kernel port: there is no net_kernel/global patch, so
%% cross-group links are ordinary visible links (deviation O2 is expected to
%% show up in L2). Run nodes with `-kernel connect_all false` so global does
%% not mesh the cluster transitively.
%%
%% API and return shapes follow the 19.3 reference (spec/SD_ERLANG_SPEC.md 3),
%% including the registered I-behaviours I1, I2, I3, R1, R2. Requirements met by
%% design: R-ISO-1 (no logical disconnects at all), R-NS-1/2/3/4 (no
%% global-partition merge; each group's namespace is replicated explicitly
%% under a group-wide lock), R-ATTR-1 (one attribute store). With connect_all
%% false, S2's transitive meshing of free normal nodes is emulated here
%% (free_mesh/1).
-module(s_group).
-behaviour(gen_server).

-export([start/0, start_link/0, stop/0]).
-export([new_s_group/2, add_nodes/2, remove_nodes/2, delete_s_group/1,
         register_name/3, re_register_name/3, unregister_name/2,
         whereis_name/2, whereis_name/3, send/3, send/4, registered_names/1,
         own_nodes/0, own_nodes/1, own_s_groups/0, s_groups/0, sync/0, info/0,
         add_attributes/1, registered_attributes/0, choose_nodes/1,
         known_peers/1]).
%% internal (called on other members)
-export([i_install/3, i_drop/1, i_insert/4, i_delete/3, i_lookup/2, i_names/1,
         i_is_free/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(T, 15000).

%% groups :: #{G => [node()]}, names :: #{G => #{Name => pid()}},
%% mons :: #{reference() => {G, Name}}
-record(st, {groups = #{}, names = #{}, mons = #{}, attrs = []}).

start() -> gen_server:start({local, ?MODULE}, ?MODULE, [], []).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
stop() -> gen_server:stop(?MODULE).

%%--------------------------------------------------------------------
%% Membership
%%--------------------------------------------------------------------

new_s_group(G, Nodes0) ->
    Nodes = lists:usort(Nodes0),
    case {lists:member(node(), Nodes), maps:is_key(G, groups())} of
        {false, _} -> {error, remote_s_group};
        {true, true} -> {error, s_group_name_is_in_use};
        {true, false} ->
            %% Install here first: while the initiator is still free, its
            %% first link to a free member would start a free-mesh exchange
            %% and leave that member with visible links to free nodes
            %% (C4, test/corpus/l1-c4-joinrace.eterm).
            ok = i_install(G, Nodes, #{}),
            Others = Nodes -- [node()],
            [net_kernel:connect_node(N) || N <- Others],
            _ = multicall(Others, i_install, [G, Nodes, #{}]),
            {ok, G, Nodes}
    end.

add_nodes(G, Nodes0) ->
    case lists:usort(Nodes0) -- [node()] of
        [] -> {ok, G, []};                                     % I1
        Nodes ->
            case maps:find(G, groups()) of
                error -> {error, node_does_not_belong_to_the_s_group};
                {ok, Members} ->
                    case Nodes -- Members of
                        [] -> {ok, G, Nodes};                  % I3
                        New ->
                            All = lists:usort(Members ++ New),
                            [net_kernel:connect_node(N) || N <- New],
                            locked(G, All,
                                   fun() ->
                                           Ns = i_names(G),
                                           _ = multicall(All, i_install, [G, All, Ns]),
                                           {ok, G, New}
                                   end)
                    end
            end
    end.

remove_nodes(G, Nodes0) ->
    Nodes = lists:usort(Nodes0),
    case {Nodes, lists:member(node(), Nodes), maps:find(G, groups())} of
        {[], _, _} -> ok;
        {_, true, _} -> {error, "cannot_remove_itself"};
        {_, _, error} -> {error, {"node_does_not_belong_to_s_group", G}};
        {_, _, {ok, Members}} ->
            case [N || N <- Nodes, lists:member(N, Members)] of   % I2
                [] -> ok;
                Rm ->
                    Rest = Members -- Rm,
                    locked(G, Members,
                           fun() ->
                                   Ns = i_names(G),
                                   _ = multicall(Rest, i_install, [G, Rest, Ns]),
                                   _ = multicall(Rm, i_drop, [G]),
                                   ok
                           end)
            end
    end.

delete_s_group(G) ->
    case maps:find(G, groups()) of
        error -> {error, {"node_does_not_belong_to_s_group", G}};
        {ok, Members} ->
            _ = multicall(Members, i_drop, [G]),
            ok
    end.

%%--------------------------------------------------------------------
%% Names (replicated per group under a group-wide lock)
%%--------------------------------------------------------------------

register_name(G, Name, Pid) when is_pid(Pid) ->
    with_members(G, {no, cannot_register_in_remote_group},
                 fun(Members) ->
                         locked(G, Members,
                                fun() ->
                                        Ns = i_names(G),
                                        case maps:is_key(Name, Ns) orelse
                                             lists:member(Pid, maps:values(Ns)) of
                                            true -> {no, name_or_pid_already_registered};
                                            false ->
                                                _ = multicall(Members, i_insert, [G, Name, Pid, none]),
                                                yes
                                        end
                                end)
                 end).

re_register_name(G, Name, Pid) when is_pid(Pid) ->
    with_members(G, {no, cannot_re_register_in_remote_group},
                 fun(Members) ->
                         locked(G, Members,
                                fun() ->
                                        Ns = i_names(G),
                                        case lists:member(Pid, maps:values(Ns)) of
                                            true -> {no, pid_is_already_registered};
                                            false ->
                                                _ = multicall(Members, i_insert, [G, Name, Pid, replace]),
                                                yes
                                        end
                                end)
                 end).

unregister_name(G, Name) ->
    with_members(G, {no, cannot_unregister_from_remote_group},       % R2
                 fun(Members) ->
                         locked(G, Members,
                                fun() -> _ = multicall(Members, i_delete, [G, Name, any]), true end)
                 end).

whereis_name(G, Name) ->
    case maps:is_key(G, groups()) of
        true -> i_lookup(G, Name);
        false -> undefined          % allowed by the O4 mapping (undefined or the group's pid)
    end.

whereis_name(Node, G, Name) ->
    case rpc:call(Node, ?MODULE, i_lookup, [G, Name], ?T) of
        P when is_pid(P) -> P;
        _ -> undefined
    end.

send(G, Name, Msg) ->
    case whereis_name(G, Name) of
        P when is_pid(P) -> P ! Msg, P;
        undefined -> {badarg, {G, Name, Msg}}                        % R1
    end.

send(Node, G, Name, Msg) ->
    case whereis_name(Node, G, Name) of
        P when is_pid(P) -> P ! Msg, P;
        undefined -> {badarg, {G, Name, Msg}}
    end.

registered_names({s_group, G}) ->
    case maps:is_key(G, groups()) of
        true -> [{G, N} || N <- lists:sort(maps:keys(i_names(G)))];
        false -> []
    end;
registered_names({node, N}) when N =:= node() ->
    lists:append([[{G, Nm} || Nm <- maps:keys(Ns)] || {G, Ns} <- maps:to_list(all_names())]);
registered_names({node, N}) ->
    rpc:call(N, ?MODULE, registered_names, [{node, N}], ?T).

%%--------------------------------------------------------------------
%% Introspection
%%--------------------------------------------------------------------

own_s_groups() -> lists:sort(maps:to_list(groups())).
own_nodes() -> lists:usort([node() | lists:append(maps:values(groups()))]).
own_nodes(G) -> maps:get(G, groups(), []).
s_groups() -> {lists:sort(maps:keys(groups())), []}.
sync() -> ok.
info() -> [{state, synced}, {own_s_groups, own_s_groups()}].

%% Quiescence probe for the harness (sd_pbt_obs): with explicit replication
%% there is no background sync, so knowledge equals membership.
known_peers(G) -> own_nodes(G) -- [node()].

add_attributes(As) -> gen_server:call(?MODULE, {add_attributes, As}).
registered_attributes() -> gen_server:call(?MODULE, attributes).

choose_nodes(Args) ->                                                % R-ATTR-1
    Want = lists:usort([A || {attribute, A} <- Args]),
    [N || N <- nodes(),
          begin
              Has = rpc:call(N, ?MODULE, registered_attributes, [], ?T),
              is_list(Has) andalso (Want -- Has) =:= []
          end].

%%--------------------------------------------------------------------
%% Internal operations executed on each member
%%--------------------------------------------------------------------

i_install(G, Members, Names) -> gen_server:call(?MODULE, {install, G, Members, Names}).
i_drop(G) -> gen_server:call(?MODULE, {drop, G}).
i_insert(G, Name, Pid, Mode) -> gen_server:call(?MODULE, {insert, G, Name, Pid, Mode}).
i_delete(G, Name, Pid) -> gen_server:call(?MODULE, {delete, G, Name, Pid}).
i_lookup(G, Name) -> maps:get(Name, maps:get(G, all_names(), #{}), undefined).
i_names(G) -> maps:get(G, all_names(), #{}).
i_is_free() -> groups() =:= #{} andalso init:get_argument(hidden) =:= error.

groups() -> gen_server:call(?MODULE, groups).
all_names() -> gen_server:call(?MODULE, names).

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

%% Static configuration (D3.3 3.1 launch config, as in 19.3):
%% {kernel, [{s_groups, [{G, normal, Nodes}]}]}. Same-name definitions are
%% merged by union, as 19.3 does (DN1, decision D-3 still open).
init([]) ->
    Groups = case application:get_env(kernel, s_groups) of
                 {ok, Defs} when is_list(Defs) ->
                     Merged = lists:foldl(fun({G, _Type, Ns}, Acc) ->
                                                  maps:update_with(G, fun(Old) -> lists:usort(Old ++ Ns) end,
                                                                   lists:usort(Ns), Acc)
                                          end, #{}, Defs),
                     maps:filter(fun(_G, Ns) -> lists:member(node(), Ns) end, Merged);
                 _ -> #{}
             end,
    Peers = lists:usort(lists:append(maps:values(Groups))) -- [node()],
    ok = net_kernel:monitor_nodes(true),
    _ = spawn(fun() -> [net_kernel:connect_node(N) || N <- Peers] end),
    {ok, #st{groups = Groups, names = maps:map(fun(_, _) -> #{} end, Groups)}}.

handle_call(groups, _F, S) -> {reply, S#st.groups, S};
handle_call(names, _F, S) -> {reply, S#st.names, S};
handle_call(attributes, _F, S) -> {reply, S#st.attrs, S};
handle_call({add_attributes, As}, _F, S) ->
    {reply, ok, S#st{attrs = lists:usort(S#st.attrs ++ As)}};
handle_call({install, G, Members, Names}, _F, S) ->
    %% P2 / D3.3 InterConnectNodes: every member connects to every other
    %% member (found by L1 on OTP 29: without it only creator<->member links
    %% existed, since connect_all is false).
    Others = Members -- [node()],
    _ = spawn(fun() -> [net_kernel:connect_node(N) || N <- Others] end),
    S1 = lists:foldl(fun({Nm, P}, Acc) -> put_name(G, Nm, P, Acc) end,
                     S#st{groups = maps:put(G, Members, S#st.groups),
                          names = maps:put(G, maps:get(G, S#st.names, #{}), S#st.names)},
                     maps:to_list(Names)),
    {reply, ok, S1};
handle_call({drop, G}, _F, S) ->
    S1 = S#st{groups = maps:remove(G, S#st.groups), names = maps:remove(G, S#st.names)},
    %% Became free: rejoin the free mesh over the links it already has.
    case S#st.groups =/= #{} andalso S1#st.groups =:= #{} of
        true -> free_mesh(nodes(), S1);
        false -> ok
    end,
    {reply, ok, S1};
handle_call({insert, G, Name, Pid, Mode}, _F, S) ->
    S1 = case Mode of replace -> del_name(G, Name, S); none -> S end,
    {reply, ok, put_name(G, Name, Pid, S1)};
handle_call({delete, G, Name, _Pid}, _F, S) ->
    {reply, ok, del_name(G, Name, S)}.

handle_cast({merge, G, Names}, S) ->
    case maps:is_key(G, S#st.groups) of
        true -> {noreply, lists:foldl(fun({Nm, P}, Acc) -> merge_name(G, Nm, P, Acc) end,
                                      S, Names)};
        false -> {noreply, S}
    end;
handle_cast({free_peers, From, Peers, Answer}, S) ->
    case free_normal(S) of
        true ->
            _ = spawn(fun() -> [net_kernel:connect_node(P) || P <- Peers -- [node() | nodes()]] end),
            Answer andalso free_mesh([From], false, S);
        false -> ok
    end,
    {noreply, S};
handle_cast({pid_down, G, Name, Pid}, S) ->
    {noreply, del_pid_name(G, Name, Pid, S)};
handle_cast(_, S) -> {noreply, S}.

%% A registered process died: drop its name on this replica (every member
%% monitors the pid, so all replicas converge).
handle_info({'DOWN', Ref, process, Pid, _}, S) ->
    case maps:take(Ref, S#st.mons) of
        {{G, Name}, Mons} ->
            %% Only some replicas monitor (see put_name/4): tell the rest.
            Others = maps:get(G, S#st.groups, []) -- [node()],
            _ = [gen_server:cast({?MODULE, M}, {pid_down, G, Name, Pid}) || M <- Others],
            {noreply, del_pid_name(G, Name, Pid, S#st{mons = Mons})};
        error -> {noreply, S}
    end;
%% P16 when the pid's node goes away: drop its names on every replica
%% (stock global does the same on nodedown).
handle_info({nodedown, N}, S) ->
    Gone = [{G, Nm, P} || {G, Ns} <- maps:to_list(S#st.names), {Nm, P} <- maps:to_list(Ns),
                          node(P) =:= N],
    {noreply, lists:foldl(fun({G, Nm, P}, Acc) -> del_pid_name(G, Nm, P, Acc) end, S, Gone)};
%% R-NS-1 (merge on join): a member that connects after a registration was
%% multicast never received it. Each node is authoritative for the names of
%% its own processes and pushes them, per shared group, to the new peer.
handle_info({nodeup, N}, S) ->
    _ = [gen_server:cast({?MODULE, N}, {merge, G, [{Nm, P} || {Nm, P} <- maps:to_list(maps:get(G, S#st.names, #{})),
                                                     node(P) =:= node()]})
         || {G, Members} <- maps:to_list(S#st.groups), lists:member(N, Members)],
    free_mesh([N], S),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.

terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

put_name(G, Name, Pid, S) ->
    Ns = maps:get(G, S#st.names, #{}),
    case maps:get(Name, Ns, undefined) of
        Pid -> S;
        _ ->
            S1 = S#st{names = maps:put(G, maps:put(Name, Pid, Ns), S#st.names)},
            %% Monitoring a pid on an unconnected node would open a new
            %% visible link to it (C4/P1, found by L1). Monitor only when the
            %% link already exists; the other replicas learn of the death
            %% through {pid_down, ...} or nodedown.
            case node(Pid) =:= node() orelse lists:member(node(Pid), nodes(connected)) of
                true ->
                    Ref = erlang:monitor(process, Pid),
                    S1#st{mons = maps:put(Ref, {G, Name}, S1#st.mons)};
                false -> S1
            end
    end.

del_pid_name(G, Name, Pid, S) ->
    case maps:get(Name, maps:get(G, S#st.names, #{}), undefined) of
        Pid -> del_name(G, Name, S);
        _ -> S
    end.

%% Merge one pushed name. Same name, different pid: both sides keep the
%% smaller pid (term order), so a pairwise merge is deterministic. A pid
%% already registered under another name is not added twice (P4).
merge_name(G, Name, Pid, S) ->
    Ns = maps:get(G, S#st.names, #{}),
    case maps:find(Name, Ns) of
        {ok, Pid} -> S;
        {ok, Old} when Old < Pid -> S;
        {ok, _Old} -> put_name(G, Name, Pid, del_name(G, Name, S));
        error ->
            case lists:member(Pid, maps:values(Ns)) of
                true -> S;
                false -> put_name(G, Name, Pid, S)
            end
    end.

del_name(G, Name, S) ->
    Ns = maps:get(G, S#st.names, #{}),
    S#st{names = maps:put(G, maps:remove(Name, Ns), S#st.names)}.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% S2 / D3.3 NewFreeNodes: connected free normal nodes share their
%% connections. Stock global does this transitively only with connect_all
%% true, which would also mesh s_groups, so it is emulated: a free normal node
%% tells each free peer in Targets which free nodes it is connected to, and
%% the peer connects to them (never to a group member). Hidden free nodes
%% keep their links and mesh with no one.
free_normal(S) -> S#st.groups =:= #{} andalso init:get_argument(hidden) =:= error.

free_mesh(Targets, S) -> free_mesh(Targets, true, S).

%% Answer: ask each target to reply with its own free peers (once).
free_mesh(Targets, Answer, S) ->
    case free_normal(S) of
        true ->
            _ = spawn(fun() ->
                              Free = [M || M <- nodes(),
                                           rpc:call(M, ?MODULE, i_is_free, [], ?T) =:= true],
                              [gen_server:cast({?MODULE, T}, {free_peers, node(), Free -- [T], Answer})
                               || T <- Targets, lists:member(T, Free)]
                      end),
            ok;
        false -> ok
    end.

with_members(G, NotMember, Fun) ->
    case maps:find(G, groups()) of
        {ok, Members} -> Fun(Members);
        error -> NotMember
    end.

%% Group-wide lock on all members (stock global:trans with an explicit node list).
locked(G, Members, Fun) ->
    case global:trans({{?MODULE, G}, self()}, Fun, Members, infinity) of
        aborted -> {error, lock_aborted};
        R -> R
    end.

multicall(Nodes, F, Args) ->
    erpc:multicall(Nodes, ?MODULE, F, Args, ?T).
