%% @doc Supervise the rts_write FSM.
-module(sniffle_entity_coverage_fsm_sup).
-behavior(supervisor).

-include("sniffle.hrl").

-export([start_read_fsm/1,
         start_link/0]).

-export([init/1]).

-ignore_xref([
	      init/1,
	      start_link/0
	      ]).

start_read_fsm(Args) ->
    supervisor:start_child(?MODULE, Args).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ReadFsm = {undefined,
	       {sniffle_entity_coverage_fsm, start_link, []},
               temporary, 5000, worker, [sniffle_entity_coverage_fsm]},
    {ok, {{simple_one_for_one, 10, 10}, [ReadFsm]}}.
