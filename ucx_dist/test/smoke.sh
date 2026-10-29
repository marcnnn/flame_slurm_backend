#!/bin/bash
# usage: smoke.sh SIZE... ; two VMs on this host over ucx_dist
export PATH=$HOME/.asdf/installs/erlang/27.1.2/bin:$PATH
cd ~/ucx_dist
IP=$(ip -4 -br addr show ib0 | awk '{print $3}' | cut -d/ -f1)
SIZES="[$(echo "$@" | tr ' ' ',')]"
timeout 60 erl -noshell -pa ebin -proto_dist ucx -name smoke_b@$IP -setcookie smk -eval "timer:sleep(50000), halt()." > /tmp/smoke_b.log 2>&1 &
sleep 2
timeout 55 erl -noshell -pa ebin -proto_dist ucx -name smoke_a@$IP -setcookie smk -eval "
P = list_to_atom(\"smoke_b@$IP\"),
pong = net_adm:ping(P),
E = spawn(P, ucx_bench, echo, []),
[begin
  B = crypto:strong_rand_bytes(S),
  T0 = erlang:monotonic_time(microsecond), E ! {self(), B},
  receive {E, B2} -> io:format(\"size=~p ok=~p us=~p~n\", [S, B2 =:= B, erlang:monotonic_time(microsecond)-T0]) after 10000 -> io:format(\"size=~p TIMEOUT~n\", [S]) end
 end || S <- $SIZES],
rpc:call(P, init, stop, []), halt()." 2>&1 | grep -v '^ [0-9]\|====\|^\['
wait
echo "B-LOG:"; grep -v '^ [0-9]\|====' /tmp/smoke_b.log | head -5
