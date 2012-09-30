-module(sniffle_iprange_vnode).
-behaviour(riak_core_vnode).
-include("sniffle.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([
	 repair/3,
	 get/3,
	 list/2,
	 create/4,
	 delete/3,
	 claim_ip/3,
	 return_ip/4
	]).

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

-record(state, {
	  ipranges,
	  partition,
	  node,
	  dbref,
	  index
	 }).

-define(MASTER, sniffle_iprange_vnode_master).

%%%===================================================================
%%% API
%%%===================================================================

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

repair(IdxNode, Iprange, Obj) ->
    riak_core_vnode_master:command(IdxNode,
                                   {repair, undefined, Iprange, Obj},
                                   ignore,
                                   ?MASTER).

%%%===================================================================
%%% API - reads
%%%===================================================================

get(Preflist, ReqID, Iprange) ->
    ?PRINT({get, Preflist, ReqID, Iprange}),
    riak_core_vnode_master:command(Preflist,
				   {get, ReqID, Iprange},
				   {fsm, undefined, self()},
				   ?MASTER).

%%%===================================================================
%%% API - coverage
%%%===================================================================

list(Preflist, ReqID) ->
    riak_core_vnode_master:coverage(
      {list, ReqID},
      Preflist,
      all,
      {fsm, undefined, self()},
      ?MASTER).

%%%===================================================================
%%% API - writes
%%%===================================================================

create(Preflist, ReqID, Iprange, Data) ->
    riak_core_vnode_master:command(Preflist,
				   {create, ReqID, Iprange, Data},
				   {fsm, undefined, self()},
				   ?MASTER).

delete(Preflist, ReqID, Iprange) ->
    riak_core_vnode_master:command(Preflist,
                                   {delete, ReqID, Iprange},
				   {fsm, undefined, self()},
                                   ?MASTER).

claim_ip(Preflist, ReqID, Iprange) ->
    riak_core_vnode_master:command(Preflist,
                                   {ip, claim, ReqID, Iprange},
				   {fsm, undefined, self()},
                                   ?MASTER).

return_ip(Preflist, ReqID, Iprange, IP) ->
    riak_core_vnode_master:command(Preflist,
                                   {ip, return, ReqID, Iprange, IP},
				   {fsm, undefined, self()},
                                   ?MASTER).

%%%===================================================================
%%% VNode
%%%===================================================================

init([Partition]) ->
    {ok, DBRef} = eleveldb:open("ipranges."++integer_to_list(Partition)++".ldb", [{create_if_missing, true}]),
    {Index, Ranges} = read_ranges(DBRef),
    {ok, #state{
       partition = Partition,
       index = Index,
       node = node(),
       ipranges = Ranges,
       dbref=DBRef
      }}.

handle_command(ping, _Sender, State) ->
    {reply, {pong, State#state.partition}, State};

handle_command({get, ReqID, Iprange}, _Sender, State) ->
    ?PRINT({handle_command, get, ReqID, Iprange}),
    NodeIdx = {State#state.partition, State#state.node},
    Res = case dict:find(Iprange, State#state.ipranges) of
	      error ->
		  {ok, ReqID, NodeIdx, not_found};
	      {ok, V} ->
		  {ok, ReqID, NodeIdx, V}
	  end,
    {reply, 
     Res,
     State};

handle_command({create, {ReqID, Coordinator}, Iprange,
		[Network, Gateway, Netmask, First, Last, Tag]},
	       _Sender, #state{dbref = DBRef} = State) ->
    I0 = statebox:new(fun sniffle_iprange_state:new/0),
    I1 = lists:foldl(
	   fun (OP, SB) ->
		   statebox:modify(OP, SB)
	   end, I0, [{fun sniffle_iprange_state:name/2, [Iprange]},
		     {fun sniffle_iprange_state:network/2, [Network]},
		     {fun sniffle_iprange_state:gateway/2, [Gateway]},
		     {fun sniffle_iprange_state:netmask/2, [Netmask]},
		     {fun sniffle_iprange_state:first/2, [First]},
		     {fun sniffle_iprange_state:current/2, [First]},
		     {fun sniffle_iprange_state:last/2, [Last]},
		     {fun sniffle_iprange_state:tag/2, [Tag]}]),
    
    VC0 = vclock:fresh(),
    VC = vclock:increment(Coordinator, VC0),
    HObject = #sniffle_obj{val=I1, vclock=VC},

    Is0 = dict:store(Iprange, HObject, State#state.ipranges),

    eleveldb:put(DBRef, <<"#ipranges">>, term_to_binary(dict:fetch_keys(Is0)), []),
    eleveldb:put(DBRef, Iprange, term_to_binary(HObject), []),
    
    {reply, {ok, ReqID}, State#state{ipranges = Is0}};

handle_command({delete, {ReqID, _Coordinator}, Iprange}, _Sender, #state{dbref = DBRef} = State) ->
    Is0 = dict:erase(Iprange, State#state.ipranges),

    eleveldb:put(DBRef, <<"#ipranges">>, term_to_binary(dict:fetch_keys(Is0)), []),
    eleveldb:delete(DBRef, Iprange, []),

    {reply, {ok, ReqID}, State#state{ipranges = Is0}};

handle_command({ip, claim, 
		{ReqID, Coordinator}, Iprange, IP}, _Sender, #state{dbref = DBRef} = State) ->
    Hs0 = dict:update(Iprange,
		      fun(_, #sniffle_obj{val=I0} = O) ->
			      I1 = statebox:modify(
				     {fun sniffle_iprange_state:claim_ip/2,
				      [IP]}, I0),
			      I2 = statebox:expire(?STATEBOX_EXPIRE, I1),
			      sniffle_obj:update(I2, Coordinator, O)
		      end, State#state.ipranges),
    
    {IP, Hs1} = case dict:find(Iprange, State#state.ipranges) of
		    error ->
			{not_found, Iprange};
		    {ok, #sniffle_obj{val=I0} = O} ->
			NewIP = case statebox:value(I0) of
				    #iprange{free=[],
					     current=FoundIP} ->
					FoundIP;
				    #iprange{free=[FoundIP|_]} ->
					FoundIP
				end,
			I1 = statebox:modify(
			       {fun sniffle_iprange_state:claim_ip/2, [NewIP]}, 
			       I0
			      ),
			I2 = statebox:expire(?STATEBOX_EXPIRE, I1),

			eleveldb:put(DBRef, Iprange, term_to_binary(I2), []),
			
			Hs0 = dict:store(Iprange, 
					 sniffle_obj:update(I2, Coordinator, O), 
					 State#state.ipranges),
			{NewIP, Hs0}
		end,

    {reply, {ok, ReqID, IP}, State#state{ipranges = Hs1}};

handle_command({ip, return, 
		{ReqID, Coordinator}, Iprange, IP}, _Sender, #state{dbref = DBRef} = State) ->
    Hs0 = dict:update(Iprange, 
		      fun(_, #sniffle_obj{val=I0} = O) ->
			      I1 = statebox:modify(
				     {fun sniffle_iprange_state:return_ip/2, 
				      [IP]}, I0),
			      I2 = statebox:expire(?STATEBOX_EXPIRE, I1),
			      eleveldb:put(DBRef, Iprange, term_to_binary(I2), []),
			      sniffle_obj:update(I2, Coordinator, O)
		      end, State#state.ipranges),
    {reply, {ok, ReqID}, State#state{ipranges = Hs0}};

handle_command(Message, _Sender, State) ->
    ?PRINT({unhandled_command, Message}),
    {noreply, State}.

handle_handoff_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0}, _Sender, State) ->
    Acc = dict:fold(Fun, Acc0, State#state.ipranges),
    {reply, Acc, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(Data, #state{dbref = DBRef} = State) ->
    {Iprange, HObject} = binary_to_term(Data),
    Is0 = dict:store(Iprange, HObject, State#state.ipranges),
    eleveldb:put(DBRef, <<"#ipranges">>, term_to_binary(dict:fetch_keys(Is0)), []),
    eleveldb:put(DBRef, Iprange, term_to_binary(HObject), []),
    {reply, ok, State#state{ipranges = Is0}}.

encode_handoff_item(Iprange, Data) ->
    term_to_binary({Iprange, Data}).

is_empty(State) ->
    case dict:size(State#state.ipranges) of
	0 ->
	    {true, State};
	_ ->
	    {true, State}
    end.

delete(#state{dbref = DBRef} = State) ->
    eleveldb:close(DBRef),
    eleveldb:destroy("ipranges."++integer_to_list(State#state.partition)++".ldb",[]),
    {ok, DBRef1} = eleveldb:open("ipranges."++integer_to_list(State#state.partition)++".ldb",
				 [{create_if_missing, true}]),

    {ok, State#state{ipranges = dict:new(), dbref = DBRef1}}.

handle_coverage({list, ReqID}, _KeySpaces, _Sender, State) ->
    {reply, 
     {ok, ReqID, {State#state.partition,State#state.node}, dict:fetch_keys(State#state.ipranges)},
     State};

handle_coverage({overlap, ReqID, Start, Stop}, _KeySpaces, _Sender, State) ->
    Res = dict:fold(fun (_, _, true) ->
			    true;
			(_, #sniffle_obj{val=V0}, false) ->
			    #iprange{first=Start1,
				     last=Stop1} = statebox:value(V0),
			    (Start1 =< Start andalso
				Start =< Stop1)
				orelse
				  (Start1 =< Stop andalso
				   Stop =< Stop1)
		    end, false, State#state.ipranges),
    {reply, 
     {ok, ReqID, {State#state.partition,State#state.node}, [Res]},
     State};

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, #state{dbref=DBRef} = _State) ->
    eleveldb:close(DBRef),
    ok.

read_ranges(DBRef) ->
    case eleveldb:get(DBRef, <<"#ipranges">>, []) of
	not_found -> 
	    {[], dict:new()};
	{ok, Bin} ->
	    Index = binary_to_term(Bin),
	    {Index,
	     lists:foldl(fun (Iprange, Ipranges0) ->
				 {ok, IpBin} = eleveldb:get(DBRef, Iprange, []),
				 dict:store(Iprange, binary_to_term(IpBin), Ipranges0)
			 end, dict:new(), Index)}
    end.
