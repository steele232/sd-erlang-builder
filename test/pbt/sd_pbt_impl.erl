%% I-adapter: the registered *state* divergences of the 19.3 implementation
%% from M, applied on top of sd_model so the model follows what the reference
%% implementation does. Value-only divergences live in sd_pbt_statem:value_ok/5.
%%
%% Every clause here cites a spec/deviations.yml id. A clause without an id
%% is a bug in the harness.
-module(sd_pbt_impl).

-export([step/3]).

%% I2: remove_nodes/2 removes the intersection of the list with the group's
%% members and returns ok whenever the caller is a member and not in the
%% list; M returns False unless every listed node is a member.
step(M, remove_nodes, [G, Nis0, Ni]) ->
    Nis = lists:usort(Nis0),
    case {lists:member(Ni, Nis), sd_model:group(G, M)} of
        {false, {G, Members, _}} ->
            case lists:member(Ni, Members) of
                true ->
                    case [N || N <- Nis, lists:member(N, Members)] of
                        [] -> {M, true};
                        Common -> sd_model:remove_nodes(M, G, Common, Ni)
                    end;
                false ->
                    sd_model:remove_nodes(M, G, Nis, Ni)
            end;
        _ ->
            sd_model:remove_nodes(M, G, Nis, Ni)
    end;
step(M, F, Args) ->
    model_step(M, F, Args).

model_step(M, new_s_group, [G, Nis, Ni]) -> sd_model:new_s_group(M, G, Nis, Ni);
model_step(M, add_nodes, [G, Nis, Ni]) -> sd_model:add_nodes(M, G, Nis, Ni);
model_step(M, delete_s_group, [G, Ni]) -> sd_model:delete_s_group(M, G, Ni);
model_step(M, register_name, [G, N, P, Ni]) -> sd_model:register_name(M, G, N, P, Ni);
model_step(M, re_register_name, [G, N, P, Ni]) -> sd_model:re_register_name(M, G, N, P, Ni);
model_step(M, unregister_name, [G, N, Ni]) -> sd_model:unregister_name(M, G, N, Ni);
model_step(M, whereis_name, [G, N, Ni]) -> sd_model:whereis_name(M, G, N, Ni);
model_step(M, send, [G, N, Ni]) -> sd_model:send(M, G, N, Ni).
