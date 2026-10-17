-module(sd_demo_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, children()}}.

%% Two configuration styles:
%%   {topology, [{Node, [{seeds, Nodes}, {services, Specs}]}]}  (15-node demo)
%%   {role, worker}, {group, G}                                  (3-node demo)
children() ->
    case application:get_env(sd_demo, topology) of
        {ok, Topology} ->
            Spec = proplists:get_value(node(), Topology, []),
            Seeds = proplists:get_value(seeds, Spec, []),
            Services = case sd_runtime() of
                           true -> proplists:get_value(services, Spec, []);
                           %% Stock OTP control: discovery only, no s_group services.
                           false -> []
                       end,
            [#{id => sd_demo_seeder, start => {sd_demo_seeder, start_link, [Seeds]}}
             | [service(S) || S <- Services]];
        undefined ->
            case application:get_env(sd_demo, role) of
                {ok, worker} ->
                    {ok, Group} = application:get_env(sd_demo, group),
                    [service({worker, Group})];
                _ ->
                    []
            end
    end.

service({worker, Group}) ->
    #{id => {sd_demo_worker, Group},
      start => {sd_demo_worker, start_link, [Group]}};
service({router, Group, Name}) ->
    #{id => {sd_demo_router, Name},
      start => {sd_demo_router, start_link, [Group, Name]}}.

sd_runtime() ->
    code:which(s_group) =/= non_existing.
