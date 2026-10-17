%% Portability helpers shared by the demo and the verification harness
%% (OTP 20 historical runtime and OTP 21+ ports). See sd_compat.hrl.
-module(sd_compat).

-export([safe/1]).

%% `catch Expr` semantics without the deprecated construct; stack traces
%% are dropped (they differ between OTP releases).
-spec safe(fun(() -> term())) -> term().
safe(F) ->
    try F()
    catch throw:T -> T;
          exit:R -> {'EXIT', R};
          error:R -> {'EXIT', {R, []}}
    end.
