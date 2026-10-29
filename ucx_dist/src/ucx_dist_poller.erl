-module(ucx_dist_poller).

%% Drives the VM's single UCP worker: progresses it whenever its event fd
%% becomes readable. Started by net_kernel through ucx_dist:childspecs/0.

-export([start_link/0, init/1]).

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
    case ucx_dist_nif:init() of
        ok ->
            register(?MODULE, self()),
            process_flag(priority, high),
            proc_lib:init_ack(Parent, {ok, self()}),
            loop();
        {error, Reason} ->
            proc_lib:init_fail(Parent, {error, {ucx_init, Reason}}, {exit, normal})
    end.

loop() ->
    case ucx_dist_nif:poll() of
        busy ->
            loop();
        armed ->
            receive
                {select, _, _, ready_input} -> loop()
            after 1000 ->
                %% Safety net against a missed wakeup.
                loop()
            end;
        {error, Reason} ->
            exit({ucx_poll, Reason})
    end.
