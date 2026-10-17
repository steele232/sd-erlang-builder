%% Stack traces across OTP 20 (historical) and OTP 21+ (modern ports).
-ifdef(OTP_RELEASE).
-define(EXCEPTION(Class, Reason, Stack), Class:Reason:Stack).
-define(GET_STACK(Stack), Stack).
-else.
-define(EXCEPTION(Class, Reason, _Stack), Class:Reason).
-define(GET_STACK(_Stack), erlang:get_stacktrace()).
-endif.

%% `catch Expr` is deprecated in OTP 29; this try/catch keeps its observable
%% semantics on OTP 20 and 29 (throw -> value, exit -> {'EXIT', R}, error ->
%% {'EXIT', {R, []}}), so traces recorded by either harness compare equal.
%% (Stack traces are dropped: they differ between OTP releases anyway.)
-define(CATCH(Expr), (try Expr
                      catch throw:CATCH_T -> CATCH_T;
                            exit:CATCH_R -> {'EXIT', CATCH_R};
                            error:CATCH_R -> {'EXIT', {CATCH_R, []}}
                      end)).
