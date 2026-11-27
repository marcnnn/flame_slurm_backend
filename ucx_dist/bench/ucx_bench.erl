-module(ucx_bench).

%% Distribution benchmarks, run on the client node against a peer node
%% that has this module in its code path.
%%
%%   ucx_bench:main(['peer@host', "label", "out.csv"])

-export([main/1, echo/0, sink/1]).

-define(SIZES, [8, 64, 512, 4096, 32768, 262144, 1048576, 8388608, 67108864]).

main([Peer0, Label, Out]) ->
    Peer = to_atom(Peer0),
    wait_connected(Peer, 60),
    {ok, Fd} = file:open(to_list(Out), [append]),
    Rows = latency(Peer) ++ throughput(Peer) ++ rpc_calls(Peer),
    [io:format(Fd, "~s,~s~n", [to_list(Label), Row]) || Row <- Rows],
    ok = file:close(Fd),
    [io:format("~s,~s~n", [to_list(Label), Row]) || Row <- Rows],
    rpc:call(Peer, init, stop, []),
    ok.

to_atom(A) when is_atom(A) -> A;
to_atom(L) -> list_to_atom(L).

to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(L) -> L.

wait_connected(Peer, 0) ->
    exit({peer_unreachable, Peer});
wait_connected(Peer, N) ->
    case net_adm:ping(Peer) of
        pong ->
            ok;
        pang ->
            timer:sleep(1000),
            wait_connected(Peer, N - 1)
    end.

%% Round trip of a binary to an echo process on the peer.
latency(Peer) ->
    Echo = spawn(Peer, ?MODULE, echo, []),
    Rows = [latency(Echo, Size) || Size <- ?SIZES],
    Echo ! stop,
    Rows.

latency(Echo, Size) ->
    Bin = payload(Size),
    Iters = iters(Size),
    [roundtrip(Echo, Bin) || _ <- lists:seq(1, min(Iters, 100))],
    Samples = lists:sort([roundtrip(Echo, Bin) || _ <- lists:seq(1, Iters)]),
    Median = percentile(Samples, 0.5),
    row("pingpong", Size, Iters, Median, percentile(Samples, 0.99),
        2 * Size / Median).

roundtrip(Echo, Bin) ->
    T0 = erlang:monotonic_time(nanosecond),
    Echo ! {self(), Bin},
    receive
        {Echo, _} -> ok
    end,
    (erlang:monotonic_time(nanosecond) - T0) / 1000.

echo() ->
    receive
        {From, Bin} ->
            From ! {self(), Bin},
            echo();
        stop ->
            ok
    end.

%% One-way stream of Count messages; the sink acknowledges the last one.
throughput(Peer) ->
    [stream(Peer, Size) || Size <- ?SIZES, Size >= 512].

stream(Peer, Size) ->
    Bin = payload(Size),
    Count = max(20, min(20000, (512 bsl 20) div Size)),
    Sink = spawn(Peer, ?MODULE, sink, [Count]),
    T0 = erlang:monotonic_time(nanosecond),
    [Sink ! {self(), Bin} || _ <- lists:seq(1, Count)],
    receive
        {Sink, done} -> ok
    end,
    Us = (erlang:monotonic_time(nanosecond) - T0) / 1000,
    row("stream", Size, Count, Us / Count, Us / Count, Size * Count / Us).

sink(0) ->
    ok;
sink(N) ->
    receive
        {From, _} when N =:= 1 ->
            From ! {self(), done};
        {_, _} ->
            sink(N - 1)
    end.

%% erpc:call shipping a binary and returning its size, which is roughly
%% what a FLAME.call with a large argument does.
rpc_calls(Peer) ->
    [rpc_call(Peer, Size) || Size <- [1024, 1048576, 67108864]].

rpc_call(Peer, Size) ->
    Bin = payload(Size),
    Iters = min(iters(Size), 2000),
    Size = erpc:call(Peer, erlang, byte_size, [Bin]),
    Samples = lists:sort([begin
                              T0 = erlang:monotonic_time(nanosecond),
                              Size = erpc:call(Peer, erlang, byte_size, [Bin]),
                              (erlang:monotonic_time(nanosecond) - T0) / 1000
                          end || _ <- lists:seq(1, Iters)]),
    Median = percentile(Samples, 0.5),
    row("erpc", Size, Iters, Median, percentile(Samples, 0.99), Size / Median).

payload(Size) ->
    crypto:strong_rand_bytes(Size).

iters(Size) ->
    max(20, min(10000, (256 bsl 20) div Size)).

percentile(Sorted, P) ->
    lists:nth(max(1, round(P * length(Sorted))), Sorted).

%% test,size,iters,median_us,p99_us,mb_per_s (MB/s = bytes per us)
row(Test, Size, Iters, Median, P99, MBps) ->
    io_lib:format("~s,~b,~b,~.2f,~.2f,~.1f", [Test, Size, Iters, Median, P99, MBps]).
