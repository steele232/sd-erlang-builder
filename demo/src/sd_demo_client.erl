%% Client side of the router: called (via rpc) on a control-group node.
-module(sd_demo_client).

-export([submit/3]).

-spec submit(atom(), atom(), atom()) -> term().
submit(Group, Router, Pool) ->
    Ref = make_ref(),
    case s_group:send(Group, Router, {job, Pool, Ref, self()}) of
        Pid when is_pid(Pid) ->
            receive
                {job_result, Ref, Result} -> Result
            after 10000 ->
                    {error, timeout}
            end;
        {badarg, _} ->
            {error, {no_router, Router}}
    end.
