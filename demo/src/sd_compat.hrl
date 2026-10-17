%% Stack traces across OTP 20 (historical) and OTP 21+ (modern ports).
-ifdef(OTP_RELEASE).
-define(EXCEPTION(Class, Reason, Stack), Class:Reason:Stack).
-define(GET_STACK(Stack), Stack).
-else.
-define(EXCEPTION(Class, Reason, _Stack), Class:Reason).
-define(GET_STACK(_Stack), erlang:get_stacktrace()).
-endif.

%% `catch Expr` is deprecated in OTP 29. sd_compat:safe/1 keeps its observable
%% semantics on OTP 20 and 29 (throw -> value, exit -> {'EXIT', R}, error ->
%% {'EXIT', {R, []}}), so traces recorded by either harness compare equal.
-define(CATCH(Expr), sd_compat:safe(fun() -> Expr end)).
