-module(sd_demo_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    sd_demo_sup:start_link().

stop(_State) ->
    ok.
