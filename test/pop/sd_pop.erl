%% POP1 acceptance scenario (decision D-5): a real pairwise partition inside
%% one group, then a heal. Driven step by step by bin/sd-pop, which cuts and
%% restores the a<->x link with iptables between the steps.
%%
%%   g1 = {a, r, x}   the partitioned group (r keeps both links)
%%   g2 = {x, y}      must be unaffected (P8 / Collateral)
-module(sd_pop).
-export([trace_tla/1]).
-export([setup/0, split_register/0, split_register_rev/0, check_g2/0, heal/0, check_converged/0, state/0]).

-define(N(X), list_to_atom(atom_to_list(X) ++ "@" ++ atom_to_list(X) ++ ".pop.lab")).
-define(WAIT_MS, 30000).

setup() ->
    [A, R, X, Y] = [?N(a), ?N(r), ?N(x), ?N(y)],
    {ok, g1, _} = rpc:call(A, s_group, new_s_group, [g1, [A, R, X]]),
    {ok, g2, _} = rpc:call(X, s_group, new_s_group, [g2, [X, Y]]),
    ok = await("g1 and g2 meshed", fun() ->
                   lists:member(X, rpc:call(A, erlang, nodes, [])) andalso
                   lists:member(Y, rpc:call(X, erlang, nodes, []))
           end),
    ok.

%% Precondition (checked here): a and x no longer see each other.
%% split_register/0 registers on a first, split_register_rev/0 on x first:
%% the last writer is what r ends up with during the partition.
split_register() -> split_register([a, x]).
split_register_rev() -> split_register([x, a]).

split_register(Order) ->
    [A, X] = [?N(a), ?N(x)],
    ok = await("a and x see the cut", fun() ->
                   not lists:member(X, rpc:call(A, erlang, nodes, [])) andalso
                   not lists:member(A, rpc:call(X, erlang, nodes, []))
           end),
    PA = rpc:call(A, erlang, spawn, [timer, sleep, [infinity]]),
    PX = rpc:call(X, erlang, spawn, [timer, sleep, [infinity]]),
    Reg = fun(a) -> rpc:call(A, s_group, register_name, [g1, n, PA]);
             (x) -> rpc:call(X, s_group, register_name, [g1, n, PX])
          end,
    [R1, R2] = [Reg(W) || W <- Order],
    {RA, RX} = case Order of [a, x] -> {R1, R2}; [x, a] -> {R2, R1} end,
    io:format("register on a: ~p (pid on a ~p), on x: ~p (pid on x ~p)~n", [RA, PA, RX, PX]),
    io:format("tables right after: ~p~n", [state()]),
    links_intact().

%% POP1 is logical: partition prevention never cuts a link. r keeps both of
%% its g1 links, and x keeps its g2 link to y (the link x shares through
%% another group), during the cut.
links_intact() ->
    [A, R, X, Y] = [?N(a), ?N(r), ?N(x), ?N(y)],
    Want = [{R, A}, {R, X}, {X, Y}],
    Down = [{P, Q} || {P, Q} <- Want, not lists:member(Q, rpc:call(P, erlang, nodes, []))],
    case Down of
        [] -> ok;
        _ -> io:format("LINKS CUT during the partition: ~p~n", [Down]), {links_cut, Down}
    end.

check_g2() ->
    [X, Y] = [?N(x), ?N(y)],
    P = rpc:call(Y, erlang, spawn, [timer, sleep, [infinity]]),
    yes = rpc:call(Y, s_group, register_name, [g2, m, P]),
    await("g2 name m on both members", fun() ->
              rpc:call(X, s_group, whereis_name, [g2, m]) =:= P andalso
              rpc:call(Y, s_group, whereis_name, [g2, m]) =:= P
          end).

%% The iptables rules are already gone; re-dial as an application or a
%% libcluster strategy would (decision RC1: no re-dial in the kernel).
heal() ->
    [A, X] = [?N(a), ?N(x)],
    true = rpc:call(A, s_group, connect_node, [X]),
    ok.

check_converged() ->
    Members = [?N(a), ?N(r), ?N(x)],
    Res = await("g1 converged: one pid for n, alive, same on every member, one name per pid",
                fun() ->
                        Views = [rpc:call(M, s_group, whereis_name, [g1, n]) || M <- Members],
                        Tables = [lists:sort(rpc:call(M, s_group, registered_names, [{s_group, g1}]))
                                  || M <- Members],
                        case lists:usort(Views) of
                            [P] when is_pid(P) ->
                                rpc:call(node(P), erlang, is_process_alive, [P]) =:= true
                                    andalso length(lists:usort(Tables)) =:= 1;
                            _ -> false
                        end
                end),
    io:format("~p~n", [state()]),
    Res.

state() ->
    [{M, case rpc:call(M, s_group, whereis_name, [g1, n]) of
             P when is_pid(P) -> {node(P), P};
             Other -> Other
         end,
      rpc:call(M, s_group, registered_names, [{s_group, g1}]),
      lists:sort(rpc:call(M, erlang, nodes, []))}
     || M <- [?N(a), ?N(r), ?N(x)]].

await(What, F) ->
    Deadline = erlang:monotonic_time(millisecond) + ?WAIT_MS,
    await(What, F, Deadline).
await(What, F, Deadline) ->
    case (try F() catch _:_ -> error end) of
        true -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> io:format("TIMEOUT: ~s~n", [What]), {timeout, What};
                false -> timer:sleep(200), await(What, F, Deadline)
            end
    end.

%% Trace validation: merge the -s_group_trace logs of g1's members by time
%% and print a self-contained TLA+ module that replays them; TLC checks the
%% spec invariant InSyncAgree wherever no operation holds the group lock
%% (spec/tla/README.md, "Trace validation").
trace_tla(Run) ->
    Members = [?N(a), ?N(r), ?N(x)],
    Short = fun(N) -> hd(string:tokens(atom_to_list(N), "@")) end,
    Evs = lists:keysort(1, [{T, Short(M), Ev} || M <- Members,
                                                 {_, T, Ev} <- rpc:call(M, s_group, i_log, []),
                                                 g1_event(Ev)]),
    Q = fun(X) -> [$" | X] ++ "\"" end,
    Str = fun(A) when is_atom(A) -> Q(atom_to_list(A));
             (P) when is_pid(P) -> Q(pid_to_list(P));
             (T) -> Q(lists:flatten(io_lib:format("~0p", [T])))
          end,
    Set = fun(L) -> "{" ++ lists:join(", ", [Q(Short(N)) || N <- L]) ++ "}" end,
    Rec = fun({_, N, {put, g1, Nm, P}}) -> io_lib:format("[k |-> \"put\", n |-> ~s, a |-> ~s, b |-> ~s]", [Q(N), Str(Nm), Str(P)]);
             ({_, N, {del, g1, Nm, _, _}}) -> io_lib:format("[k |-> \"del\", n |-> ~s, a |-> ~s, b |-> \"\"]", [Q(N), Str(Nm)]);
             ({_, N, {sync, g1, L}}) -> io_lib:format("[k |-> \"sync\", n |-> ~s, s |-> ~s]", [Q(N), Set(L)]);
             ({_, N, {op_begin, g1, _, Id}}) -> io_lib:format("[k |-> \"begin\", n |-> ~s, a |-> ~s]", [Q(N), Str(Id)]);
             ({_, N, {op_end, g1, _, Id}}) -> io_lib:format("[k |-> \"end\", n |-> ~s, a |-> ~s]", [Q(N), Str(Id)])
          end,
    Mod = "Trace_" ++ atom_to_list(Run),
    Body = ["---- MODULE ", Mod, " ----\n",
            "\\* ", integer_to_list(length(Evs)), " events of g1 from a, r, x (bin/sd-pop, SD_POP_TRACE=1)\n",
            "EXTENDS Naturals, Sequences, FiniteSets\n",
            "Nodes == {\"a\", \"r\", \"x\"}\n",
            "Log == <<\n  ", lists:join(",\n  ", [Rec(E) || E <- Evs]), "\n>>\n",
            trace_spec(),
            "====\n"],
    io:format("TLA-BEGIN~n~s~nTLA-END~n", [Body]),
    ok.

%% Replays Log; tbl[n] = n's replica of g1 as {name, pid} pairs, K[n] = its
%% in-sync set, inflight = operations holding the group lock.
trace_spec() ->
    "VARIABLES i, tbl, K, inflight\n"
    "vars == <<i, tbl, K, inflight>>\n"
    "Init == i = 1 /\\ tbl = [n \\in Nodes |-> {}] /\\ K = [n \\in Nodes |-> {}] /\\ inflight = {}\n"
    "Step(e) ==\n"
    "    CASE e.k = \"put\" -> /\\ tbl' = [tbl EXCEPT ![e.n] = {x \\in @ : x[1] # e.a} \\cup {<<e.a, e.b>>}]\n"
    "                         /\\ UNCHANGED <<K, inflight>>\n"
    "      [] e.k = \"del\" -> /\\ tbl' = [tbl EXCEPT ![e.n] = {x \\in @ : x[1] # e.a}]\n"
    "                         /\\ UNCHANGED <<K, inflight>>\n"
    "      [] e.k = \"sync\" -> /\\ K' = [K EXCEPT ![e.n] = e.s] /\\ UNCHANGED <<tbl, inflight>>\n"
    "      [] e.k = \"begin\" -> /\\ inflight' = inflight \\cup {e.a} /\\ UNCHANGED <<tbl, K>>\n"
    "      [] e.k = \"end\" -> /\\ inflight' = inflight \\ {e.a} /\\ UNCHANGED <<tbl, K>>\n"
    "Next == i <= Len(Log) /\\ Step(Log[i]) /\\ i' = i + 1\n"
    "Spec == Init /\\ [][Next]_vars\n"
    "\\* spec/tla/SGroupLockScope.tla InSyncAgree, at every point where no\n"
    "\\* operation holds the group lock.\n"
    "InSyncAgree == inflight = {} => \\A n \\in Nodes : \\A m \\in K[n] : tbl[n] = tbl[m]\n"
    "\\* The whole log was replayed (every event explained by the step relation).\n"
    "Replayed == <>(i = Len(Log) + 1)\n".

g1_event({put, g1, _, _}) -> true;
g1_event({del, g1, _, _, _}) -> true;
g1_event({sync, g1, _}) -> true;
g1_event({op_begin, g1, _, _}) -> true;
g1_event({op_end, g1, _, _}) -> true;
g1_event(_) -> false.

