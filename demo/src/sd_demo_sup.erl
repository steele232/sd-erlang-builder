-module(sd_demo_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children =
        case application:get_env(sd_demo, role) of
            {ok, worker} ->
                {ok, Group} = application:get_env(sd_demo, group),
                [#{id => sd_demo_worker,
                   start => {sd_demo_worker, start_link, [Group]}}];
            _ ->
                []
        end,
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
