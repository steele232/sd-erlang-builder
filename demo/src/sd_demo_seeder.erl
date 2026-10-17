%% Discovery kept separate from topology: periodically ping the configured
%% seeds, but only those s_group says this node currently shares a group with.
%% Re-pinging heals links after a seed restarts. On stock OTP (no s_group)
%% every seed is pinged.
-module(sd_demo_seeder).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(INTERVAL_MS, 2000).

start_link(Seeds) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Seeds, []).

init(Seeds) ->
    self() ! ping,
    {ok, Seeds}.

handle_call(_Req, _From, Seeds) ->
    {reply, {error, unknown_call}, Seeds}.

handle_cast(_Msg, Seeds) ->
    {noreply, Seeds}.

handle_info(ping, Seeds) ->
    [net_adm:ping(S) || S <- permitted(Seeds), not lists:member(S, nodes())],
    erlang:send_after(?INTERVAL_MS, self(), ping),
    {noreply, Seeds};
handle_info(_Info, Seeds) ->
    {noreply, Seeds}.

terminate(_Reason, _Seeds) ->
    ok.

code_change(_OldVsn, Seeds, _Extra) ->
    {ok, Seeds}.

permitted(Seeds) ->
    case catch s_group:own_nodes() of
        Own when is_list(Own) -> [S || S <- Seeds, lists:member(S, Own)];
        _ -> Seeds
    end.
