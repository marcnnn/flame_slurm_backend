-module(ucx_niftest).

%% Exercises the NIF without distribution: two loopback connections in
%% one VM.
%%
%%   erl -noshell -pa ebin -s ucx_niftest main 1000:100 30000000:4

-export([main/1]).

main(Args) ->
    {ok, _} = ucx_dist_poller:start_link(),
    {ok, C1, Id1} = ucx_dist_nif:conn_new(),
    {ok, C2, Id2} = ucx_dist_nif:conn_new(),
    {ok, A} = ucx_dist_nif:worker_address(),
    ok = ucx_dist_nif:conn_connect(C1, A, Id2),
    ok = ucx_dist_nif:conn_connect(C2, A, Id1),
    ok = ucx_dist_nif:conn_activate(C1, self(), self()),
    ok = ucx_dist_nif:conn_activate(C2, self(), self()),
    [run(C1, list_to_integer(S), list_to_integer(N))
     || Arg <- Args, [S, N] <- [string:split(atom_to_list(Arg), ":")]],
    halt().

run(C, Size, N) ->
    Bins = [crypto:strong_rand_bytes(Size) || _ <- lists:seq(1, N)],
    T0 = erlang:monotonic_time(microsecond),
    [case ucx_dist_nif:send(C, B) of
         ok -> ok;
         busy -> receive ucx_drained -> ok end
     end || B <- Bins],
    Got = [receive {ucx_data, X} -> X after 3000 -> timeout end || _ <- Bins],
    io:format("size=~p n=~p ok=~p timeouts=~p us=~p~n  ~p~n",
              [Size, N, Got =:= Bins, length([x || timeout <- Got]),
               erlang:monotonic_time(microsecond) - T0, ucx_dist_nif:stats()]).
