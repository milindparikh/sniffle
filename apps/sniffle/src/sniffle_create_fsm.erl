%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 17 Oct 2012 by Heinz Nikolaus Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(sniffle_create_fsm).

-behaviour(gen_fsm).

-include("sniffle.hrl").

%% API
-export([create/4,
	 start_link/0]).

%% gen_fsm callbacks
-export([
	 init/1,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 terminate/3, 
	 code_change/4
	]).

-export([
	 get_package/2,
	 get_dataset/2,
	 compile_spec/2,
	 create/2,
	 get_server/2,
	 get_ips/2
	]).

-define(SERVER, ?MODULE).

-ignore_xref([
	      compile_spec/2,
	      create/2,
	      get_dataset/2,
	      get_package/2,
	      start_link/0,
	      get_server/2,
	      get_ips/2
	     ]).

-record(state, {
	  uuid,
	  package,
	  package_name,
	  dataset,
	  dataset_name,
	  owner,
	  type,
	  hypervisor,
	  spec = []}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [], []).

create(UUID, Package, Dataset, Owner) ->
    supervisor:start_child(sniffle_create_fsm_sup, [UUID, Package, Dataset, Owner]).


%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init([UUID, Package, Dataset, Owner]) ->
    process_flag(trap_exit, true),
    {ok, get_package, #state{
	   uuid = UUID,
	   package_name = Package,
	   dataset_name = Dataset,
	   owner = Owner
	  }, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same
%% name as the current state name StateName is called to handle
%% the event. It is also called if a timeout occurs.
%%
%% @spec state_name(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------

get_package(_Event, State = #state{
		      uuid = UUID,
		      package_name = PackageName}) ->
    sniffle_vm:set_attribute(UUID, <<"state">>, <<"fetching_package">>),
    {ok, Package} = sniffle_package:get_attribute(PackageName),
    {next_state, get_dataset, State#state{package = dict:to_list(Package)}, 0}.

get_dataset(_Event, State = #state{
		      uuid = UUID,
		      dataset_name = DatasetName}) ->
    sniffle_vm:set_attribute(UUID, <<"state">>, <<"fetching_dataset">>),
    {ok, Dataset} = sniffle_dataset:get_attribute(DatasetName),
    {next_state, get_ips, State#state{dataset = dict:to_list(Dataset)}, 0}.

get_ips(_Event, State = #state{dataset = Dataset}) ->
    {<<"networks">>, Ns} = lists:keyfind(<<"networks">>, 1, Dataset),
    Dataset1 = lists:keydelete(<<"networks">>, 1, Dataset),
    Ns1 = lists:foldl(fun(NicTag, NsAcc) ->
			      {ok, {IP, Net, Gw}} = sniffle_iprange:claim_ip(NicTag),
			      [[{<<"nic_tag">>, NicTag},
				{<<"ip">>, sniffle_iprange_state:to_bin(IP)},
				{<<"netmask">>, sniffle_iprange_state:to_bin(Net)},
				{<<"gateway">>, sniffle_iprange_state:to_bin(Gw)}] | NsAcc]
		      end, [], Ns),
    {next_state, compile_spec, State#state{dataset = [{<<"networks">>, Ns1} | Dataset1]}, 0}.

compile_spec(_Event, State = #state{dataset = Dataset,
				    package = Package,
				    owner = Owner}) ->
    {next_state, get_server, State#state{spec = [{<<"owner">>, Owner} | Dataset ++ Package]}, 0}.


get_server(_Event, State = #state{
		     dataset = Dataset,
		     uuid = UUID,
		     owner = Owner,
		     package = Package}) ->
    {<<"ram">>, Ram} = lists:keyfind(<<"ram">>, 1, Package),
    sniffle_vm:set_attribute(UUID, <<"state">>, <<"fetching_dataset">>),
    Permission = [hypervisor, {<<"res">>, <<"name">>}, create],
    {<<"networks">>, Ns} = lists:keyfind(<<"networks">>, 1, Dataset),
    NicTags = lists:foldl(fun (N, Acc) ->
			     {<<"nic_tag">>, Tag} = lists:keyfind(<<"nic_tag">>, 1, N),
			     [Tag | Acc]
		     end, [], Ns),
    {ok, #hypervisor{host=Host,port=Port}} = 
	sniffle_hypervisor:list([
				 {'allowed', Permission, Owner},
				 {'subset', <<"networks">>, NicTags},
				 {'>=', <<"free-memory">>, Ram}
				]),
    {next_state, create, State#state{hypervisor = {Host, Port}}, 0}.

create(_Event, State = #state{
		 dataset = Dataset,
		 package = Package,
		 uuid = UUID,
		 owner = Owner,
		 hypervisor = {Host, Port}}) ->
    sniffle_vm:set_attribute(UUID, <<"state">>, <<"creating">>),
    libchunter:create_machine(Host, Port, UUID, Package, Dataset, [{<<"owner">>, Owner}]),
    {stop, normal, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(shutdown, _StateName, _StateData) ->
    ok;

terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================