%% Stack traces across OTP 20 (historical) and OTP 21+ (modern ports).
-ifdef(OTP_RELEASE).
-define(EXCEPTION(Class, Reason, Stack), Class:Reason:Stack).
-define(GET_STACK(Stack), Stack).
-else.
-define(EXCEPTION(Class, Reason, _Stack), Class:Reason).
-define(GET_STACK(_Stack), erlang:get_stacktrace()).
-endif.

%% `catch Expr` is deprecated in OTP 29; try/catch works on OTP 20 and 29.
-define(CATCH(Expr), (try Expr catch _:_ -> {'EXIT', caught} end)).
