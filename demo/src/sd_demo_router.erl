%% Gateway router: registered as Name in Group, it forwards jobs to the
%% `worker_pool` of any s_group the gateway itself belongs to and relays the
%% answer back. Callers never talk to workers directly, so no link between the
%% caller's group and the worker's group is ever needed.
-module(sd_demo_router).
-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(JOB_TIMEOUT_MS, 5000).

start_link(Group, Name) ->
    gen_server:start_link(?MODULE, {Group, Name}, []).

init({Group, Name}) ->
    self() ! register,
    {ok, {Group, Name}}.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(register, {Group, Name} = State) ->
    yes = sd_demo_registrar:register_when_joined(Group, Name, self()),
    io:format("[~s] router ~p registered in s_group ~p as ~p~n",
              [node(), Name, Group, self()]),
    {noreply, State};
handle_info({job, Pool, Ref, ReplyTo}, State) ->
    spawn(fun() -> ReplyTo ! {job_result, Ref, relay(Pool, Ref)} end),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Only route into groups this gateway is a member of; s_group:send/3 for a
%% foreign group would search (and connect to) that group's nodes.
relay(Pool, Ref) ->
    {Own, _Other} = s_group:s_groups(),
    case lists:member(Pool, Own) of
        false ->
            {error, {not_a_member_of, Pool}};
        true ->
            case s_group:send(Pool, worker_pool, {run, Ref, self()}) of
                Pid when is_pid(Pid) ->
                    receive
                        {job_done, Ref, Node, Pool} -> {ok, Node, Pool, node()}
                    after ?JOB_TIMEOUT_MS ->
                            {error, timeout}
                    end;
                {badarg, _} ->
                    {error, {no_worker_pool, Pool}}
            end
    end.
