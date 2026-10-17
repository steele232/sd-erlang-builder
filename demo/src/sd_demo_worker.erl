%% A stand-in "worker pool": registers itself as `worker_pool` inside one
%% s_group and answers {run, JobId, ReplyTo} messages.
-module(sd_demo_worker).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link(Group) ->
    gen_server:start_link(?MODULE, Group, []).

init(Group) ->
    %% Group-scoped registration: the same name may exist in other s_groups.
    yes = s_group:register_name(Group, worker_pool, self()),
    io:format("[~s] worker_pool registered in s_group ~p as ~p~n",
              [node(), Group, self()]),
    {ok, Group}.

handle_call(_Req, _From, Group) ->
    {reply, {error, unknown_call}, Group}.

handle_cast(_Msg, Group) ->
    {noreply, Group}.

%% s_group:send/3,4 delivers a plain message to the resolved pid.
handle_info({run, JobId, ReplyTo}, Group) ->
    ReplyTo ! {job_done, JobId, node(), Group},
    {noreply, Group};
handle_info(_Info, Group) ->
    {noreply, Group}.

terminate(_Reason, _Group) ->
    ok.

code_change(_OldVsn, Group, _Extra) ->
    {ok, Group}.
