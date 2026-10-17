%% PropEr reconstruction of the RELEASE eqc_statem s_group test
%% (D3.3 ch. 5, AST'14 sec. 4). NOT the original QuickCheck model, which is
%% not publicly available; see manifests/verification-status.yml.
%%
%% Structure follows the published description:
%%   * the abstract model is the executable semantics (spec/model/sd_model.erl)
%%   * 14 SUT nodes, 12 normal + 2 hidden (D3.3 5.2)
%%   * command weights of D3.3 Fig. 5.4 (node_down_up omitted: M ignores failures)
%%   * postcondition: returned value AND normalised actual state must match
%%     the model (D3.3 5.2, AST'14 Fig. 7), checked as eventual equality
%%     because the implementation converges asynchronously (R3)
%%
%% Return values are mapped onto M-values using only the divergences in
%% spec/deviations.yml (R1, R2, O4). Anything else is a test failure.
-module(sd_pbt_statem).

-include_lib("proper/include/proper.hrl").
-include("sd_compat.hrl").

-export([initial_state/0, command/1, precondition/2, next_state/3, postcondition/3]).
-export([prop_s_group/0, prop_s_group/1]).
-export([new_s_group/3, add_nodes/3, remove_nodes/3, delete_s_group/2,
         register_name/4, re_register_name/4, unregister_name/3,
         whereis_name/3, send/3]).

-define(GROUP_POOL, [g1, g2, g3, g4, g5, g6, g7, g8]).
-define(NAME_POOL, [a, b, c, d]).
-define(PID_INDICES, [1, 2, 3]).
-define(DEFAULT_CONVERGE_MS, 10000).
-define(TAB, sd_pbt).

%%--------------------------------------------------------------------
%% Model state
%%--------------------------------------------------------------------

initial_state() ->
    #{model => sd_model:initial_state(sd_pbt_cluster:node_types())}.

%%--------------------------------------------------------------------
%% Command generation (weights: D3.3 Fig. 5.4)
%%--------------------------------------------------------------------

command(#{model := M}) ->
    Nodes = sd_pbt_cluster:sut_nodes(),
    Existing = [G || {G, _, _} <- sd_model:groups(M)],
    Fresh = ?GROUP_POOL -- Existing,
    frequency(
      [{5, {call, ?MODULE, new_s_group, [oneof_or(Fresh, ?GROUP_POOL), node_subset(Nodes), oneof(Nodes)]}}
       || Fresh =/= []] ++
      [{5, {call, ?MODULE, add_nodes, [existing_group(Existing), node_subset(Nodes), caller(M, Existing, Nodes)]}},
       {5, {call, ?MODULE, remove_nodes, [existing_group(Existing), node_subset(Nodes), caller(M, Existing, Nodes)]}},
       {5, {call, ?MODULE, delete_s_group, [existing_group(Existing), caller(M, Existing, Nodes)]}},
       {10, {call, ?MODULE, register_name, [existing_group(Existing), oneof(?NAME_POOL), pid_ref(Nodes), caller(M, Existing, Nodes)]}},
       {10, {call, ?MODULE, whereis_name, [existing_group(Existing), oneof(?NAME_POOL), caller(M, Existing, Nodes)]}},
       {10, {call, ?MODULE, re_register_name, [existing_group(Existing), oneof(?NAME_POOL), pid_ref(Nodes), caller(M, Existing, Nodes)]}},
       {10, {call, ?MODULE, unregister_name, [existing_group(Existing), oneof(?NAME_POOL), caller(M, Existing, Nodes)]}},
       {10, {call, ?MODULE, send, [existing_group(Existing), oneof(?NAME_POOL), caller(M, Existing, Nodes)]}}]).

oneof_or([], Default) -> oneof(Default);
oneof_or(L, _) -> oneof(L).

%% Mostly an existing group, sometimes a non-existent one (error paths).
existing_group([]) -> oneof(?GROUP_POOL);
existing_group(Existing) -> frequency([{9, oneof(Existing)}, {1, oneof(?GROUP_POOL)}]).

node_subset(Nodes) ->
    ?LET(L, non_empty(list(oneof(Nodes))), lists:usort(L)).

%% Mostly a member of some existing group (interesting paths), sometimes any node.
caller(M, Existing, Nodes) ->
    Members = lists:usort(lists:append([Nis || {G, Nis, _} <- sd_model:groups(M),
                                               lists:member(G, Existing)])),
    case Members of
        [] -> oneof(Nodes);
        _ -> frequency([{4, oneof(Members)}, {1, oneof(Nodes)}])
    end.

pid_ref(Nodes) ->
    ?LET({N, I}, {oneof(Nodes), oneof(?PID_INDICES)}, {pid, N, I}).

%%--------------------------------------------------------------------
%% Preconditions
%%--------------------------------------------------------------------

%% D3.3 5.2: "A new s_group cannot be empty". A1: s_group names are unique.
precondition(#{model := M}, {call, ?MODULE, new_s_group, [G, Nis, _Ni]}) ->
    Nis =/= [] andalso sd_model:group(G, M) =:= false;
precondition(_S, _Call) ->
    true.

%%--------------------------------------------------------------------
%% Model transitions
%%--------------------------------------------------------------------

next_state(S = #{model := M}, _Res, {call, ?MODULE, F, Args}) ->
    {M1, _} = model_step(M, F, Args),
    S#{model := M1}.

%% M plus the registered state divergences of the reference implementation.
model_step(M, F, Args) -> sd_pbt_impl:step(M, F, Args).

%%--------------------------------------------------------------------
%% Postconditions
%%--------------------------------------------------------------------

postcondition(#{model := M}, {call, ?MODULE, F, Args} = Call, Res) ->
    {M1, Expected} = model_step(M, F, Args),
    ValueOk = value_ok(F, Args, M, Expected, Res),
    StateResult = case ValueOk of
                      true -> conform_then_settle(M1);
                      false -> skipped
                  end,
    case {ValueOk, StateResult, sd_model:check_invariants(M1)} of
        {true, {ok, Ms}, ok} ->
            record_latency(F, Ms),
            true;
        Failure ->
            record_failure(Call, Expected, Res, Failure),
            false
    end.

%% I-value -> M-value, using only registered divergences.
value_ok(add_nodes, [G, Nis, Ni], _M, error, {ok, G, []}) ->
    lists:usort(Nis) -- [Ni] =:= [];                          %% I1
value_ok(add_nodes, [G, Nis, Ni], _M, {G, []}, {ok, G, Nodes}) ->
    lists:usort(Nodes) =:= lists:usort(Nis) -- [Ni];          %% I3
value_ok(F, _Args, _M, Expected, Res) when F =:= new_s_group; F =:= add_nodes ->
    norm_ok_tuple(Res) =:= Expected;
value_ok(F, _Args, _M, Expected, Res) when F =:= remove_nodes; F =:= delete_s_group ->
    norm_ok(Res) =:= Expected;
value_ok(F, _Args, _M, Expected, Res) when F =:= register_name; F =:= re_register_name ->
    norm_yes(Res) =:= Expected;
value_ok(unregister_name, _Args, _M, true, _Res) ->
    true;                                                     %% R2
value_ok(F, [G, N, Ni], M, Expected, Res) when F =:= whereis_name; F =:= send ->
    Got = norm_lookup(Res),                                   %% R1 for send/3
    case sd_model:is_s_group_s_node(Ni, G, M) of
        true -> Got =:= Expected;
        %% O4: a non-member's lookup searches other groups' nodes, so it may
        %% also return the pid M has registered under (G, N).
        false -> lists:member(Got, [undefined, group_lookup(M, G, N)])
    end.

norm_ok_tuple({ok, G, Nodes}) when is_list(Nodes) -> {G, lists:usort(Nodes)};
norm_ok_tuple({error, _}) -> error;
norm_ok_tuple(Other) -> {unexpected, Other}.

norm_ok(ok) -> true;
norm_ok({error, _}) -> false;
norm_ok(Other) -> {unexpected, Other}.

norm_yes(yes) -> true;
norm_yes(no) -> false;
norm_yes({no, _}) -> false;
norm_yes(Other) -> {unexpected, Other}.

norm_lookup({badarg, _}) -> undefined;
norm_lookup(V) -> V.

group_lookup(M, G, N) ->
    case sd_model:group(G, M) of
        {G, _, Ns} -> proplists:get_value(N, Ns, undefined);
        false -> undefined
    end.

%%--------------------------------------------------------------------
%% Command wrappers: run on node Ni, translate pids both ways
%%--------------------------------------------------------------------

new_s_group(G, Nis, Ni) -> call(Ni, new_s_group, [G, Nis]).
add_nodes(G, Nis, Ni) -> call(Ni, add_nodes, [G, Nis]).
remove_nodes(G, Nis, Ni) -> call(Ni, remove_nodes, [G, Nis]).
delete_s_group(G, Ni) -> call(Ni, delete_s_group, [G]).
register_name(G, N, P, Ni) -> call(Ni, register_name, [G, N, P]).
re_register_name(G, N, P, Ni) -> call(Ni, re_register_name, [G, N, P]).
unregister_name(G, N, Ni) -> call(Ni, unregister_name, [G, N]).
whereis_name(G, N, Ni) -> call(Ni, whereis_name, [G, N]).
send(G, N, Ni) -> call(Ni, send, [G, N, sd_pbt_msg]).

call(Ni, F, Args) ->
    Maps = pid_maps(),
    Res = rpc:call(Ni, s_group, F, sd_pbt_cluster:to_real(Args, Maps), 30000),
    sd_pbt_cluster:to_ref(Res, Maps).

%%--------------------------------------------------------------------
%% Property
%%--------------------------------------------------------------------

prop_s_group() ->
    prop_s_group(#{}).

prop_s_group(_Opts) ->
    ?FORALL(Cmds, proper_statem:commands(?MODULE),
            begin
                harness(fun() ->
                                ok = sd_pbt_cluster:reset(),
                                ets:insert(?TAB, {pid_maps, sd_pbt_cluster:pid_maps()})
                        end),
                {History, State, Result} = proper_statem:run_commands(?MODULE, Cmds),
                ?WHENFAIL(io:format("~nHistory: ~p~nModel: ~p~nResult: ~p~nFailure: ~p~n",
                                    [History, State, Result, last_failure()]),
                          aggregate(proper_statem:command_names(Cmds), Result =:= ok))
            end).

pid_maps() ->
    [{pid_maps, M}] = ets:lookup(?TAB, pid_maps),
    M.

%% Infrastructure failures are recorded as such, never as SUT findings.
harness(Fun) ->
    try Fun()
    catch ?EXCEPTION(Class, Reason, Stack) ->
            ets:insert(?TAB, {last_failure, #{harness_error => {Class, Reason}}}),
            erlang:raise(Class, Reason, ?GET_STACK(Stack))
    end.

%% Mode quiescent (default): after conformance, also wait for quiescence
%% before the next command. Mode eager: conformance only (exposes O5).
conform_then_settle(M1) ->
    case sd_pbt_obs:await_conformance(M1, pid_maps(), converge_ms()) of
        {ok, Ms} ->
            case os:getenv("SD_PBT_MODE", "quiescent") of
                "eager" -> {ok, Ms};
                _ ->
                    case sd_pbt_obs:await_quiescent(M1, converge_ms()) of
                        {ok, _} -> {ok, Ms};
                        Err -> Err
                    end
            end;
        Err ->
            Err
    end.

%% Eventual-equality deadline; SD_PBT_CONVERGE_MS overrides (e.g. to tell a
%% slow convergence from a permanent divergence).
converge_ms() ->
    case os:getenv("SD_PBT_CONVERGE_MS") of
        false -> ?DEFAULT_CONVERGE_MS;
        V -> list_to_integer(V)
    end.

record_latency(F, Ms) ->
    ets:insert(?TAB, {{latency, erlang:unique_integer([monotonic])}, F, Ms}).

record_failure(Call, Expected, Res, Failure) ->
    ets:insert(?TAB, {last_failure, #{call => Call, model_value => Expected,
                                      impl_value => Res, detail => Failure}}).

last_failure() ->
    case ets:lookup(?TAB, last_failure) of
        [{_, F}] -> F;
        [] -> none
    end.
