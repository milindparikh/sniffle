%% @doc Interface for sniffle-admin commands.
-module(sniffle_console).
-export([
         join/1,
         leave/1,
         remove/1,
         vms/1,
         hvs/1,
         pkgs/1,
         ds/1,
         dtrace/1,
         ips/1,
         down/1,
         pp_json/1,
         staged_join/1,
         reip/1,
         ringready/1]
       ).

-ignore_xref([
              join/1,
              leave/1,
              vms/1,
              ds/1,
              ips/1,
              hvs/1,
              down/1,
              pkgs/1,
              dtrace/1,
              remove/1,
              staged_join/1,
              reip/1,
              ringready/1
             ]).


dtrace([C, "-j" | R]) ->
    sniffle_console_dtrace:command(json, [C | R]);

dtrace([]) ->
    sniffle_console_dtrace:help(),
    ok;

dtrace(R) ->
    sniffle_console_dtrace:command(text, R).

vms([C, "-j" | R]) ->
    sniffle_console_vms:command(json, [C | R]);

vms([]) ->
    sniffle_console_vms:help(),
    ok;

vms(R) ->
    sniffle_console_vms:command(text, R).

hvs([C, "-j" | R]) ->
    sniffle_console_hypervisors:command(json, [C | R]);

hvs([]) ->
    sniffle_console_hypervisors:help(),
    ok;

hvs(R) ->
    sniffle_console_hypervisors:command(text, R).

pkgs([C, "-j" | R]) ->
    sniffle_console_packages:command(json, [C | R]);

pkgs([]) ->
    sniffle_console_packages:help(),
    ok;

pkgs(R) ->
    sniffle_console_packages:command(text, R).

ds([C, "-j" | R]) ->
    sniffle_console_datasets:command(json, [C | R]);

ds([]) ->
    sniffle_console_datasets:help(),
    ok;

ds(R) ->
    sniffle_console_datasets:command(text, R).

ips([]) ->
    sniffle_console_ipranges:help(),
    ok;

ips(R) ->
    sniffle_console_ipranges:command(text, R).

%%compied from riak_kv

join([NodeStr]) ->
    join(NodeStr, fun riak_core:join/1,
         "Sent join request to ~s~n", [NodeStr]).

staged_join([NodeStr]) ->
    Node = list_to_atom(NodeStr),
    join(NodeStr, fun riak_core:staged_join/1,
         "Success: staged join request for ~p to ~p~n", [node(), Node]).

join(NodeStr, JoinFn, SuccessFmt, SuccessArgs) ->
    try
        case JoinFn(NodeStr) of
            ok ->
                io:format(SuccessFmt, SuccessArgs),
                ok;
            {error, not_reachable} ->
                io:format("Node ~s is not reachable!~n", [NodeStr]),
                error;
            {error, different_ring_sizes} ->
                io:format("Failed: ~s has a different ring_creation_size~n",
                          [NodeStr]),
                error;
            {error, unable_to_get_join_ring} ->
                io:format("Failed: Unable to get ring from ~s~n", [NodeStr]),
                error;
            {error, not_single_node} ->
                io:format("Failed: This node is already a member of a "
                          "cluster~n"),
                error;
            {error, self_join} ->
                io:format("Failed: This node cannot join itself in a "
                          "cluster~n"),
                error;
            {error, _} ->
                io:format("Join failed. Try again in a few moments.~n", []),
                error
        end
    catch
        Exception:Reason ->
            lager:error("Join failed ~p:~p", [Exception, Reason]),
            io:format("Join failed, see log for details~n"),
            error
    end.

leave([]) ->
    try
        case riak_core:leave() of
            ok ->
                io:format("Success: ~p will shutdown after handing off "
                          "its data~n", [node()]),
                ok;
            {error, already_leaving} ->
                io:format("~p is already in the process of leaving the "
                          "cluster.~n", [node()]),
                ok;
            {error, not_member} ->
                io:format("Failed: ~p is not a member of the cluster.~n",
                          [node()]),
                error;
            {error, only_member} ->
                io:format("Failed: ~p is the only member.~n", [node()]),
                error
        end
    catch
        Exception:Reason ->
            lager:error("Leave failed ~p:~p", [Exception, Reason]),
            io:format("Leave failed, see log for details~n"),
            error
    end.

remove([Node]) ->
    try
        case riak_core:remove(list_to_atom(Node)) of
            ok ->
                io:format("Success: ~p removed from the cluster~n", [Node]),
                ok;
            {error, not_member} ->
                io:format("Failed: ~p is not a member of the cluster.~n",
                          [Node]),
                error;
            {error, only_member} ->
                io:format("Failed: ~p is the only member.~n", [Node]),
                error
        end
    catch
        Exception:Reason ->
            lager:error("Remove failed ~p:~p", [Exception, Reason]),
            io:format("Remove failed, see log for details~n"),
            error
    end.

down([Node]) ->
    try
        case riak_core:down(list_to_atom(Node)) of
            ok ->
                io:format("Success: ~p marked as down~n", [Node]),
                ok;
            {error, legacy_mode} ->
                io:format("Cluster is currently in legacy mode~n"),
                ok;
            {error, is_up} ->
                io:format("Failed: ~s is up~n", [Node]),
                error;
            {error, not_member} ->
                io:format("Failed: ~p is not a member of the cluster.~n",
                          [Node]),
                error;
            {error, only_member} ->
                io:format("Failed: ~p is the only member.~n", [Node]),
                error
        end
    catch
        Exception:Reason ->
            lager:error("Down failed ~p:~p", [Exception, Reason]),
            io:format("Down failed, see log for details~n"),
            error
    end.

reip([OldNode, NewNode]) ->
    try
        %% reip is called when node is down (so riak_core_ring_manager is not running),
        %% so it has to use the basic ring operations.
        %%
        %% Do *not* convert to use riak_core_ring_manager:ring_trans.
        %%
        application:load(riak_core),
        RingStateDir = app_helper:get_env(riak_core, ring_state_dir),
        {ok, RingFile} = riak_core_ring_manager:find_latest_ringfile(),
        BackupFN = filename:join([RingStateDir, filename:basename(RingFile)++".BAK"]),
        {ok, _} = file:copy(RingFile, BackupFN),
        io:format("Backed up existing ring file to ~p~n", [BackupFN]),
        Ring = riak_core_ring_manager:read_ringfile(RingFile),
        NewRing = riak_core_ring:rename_node(Ring, OldNode, NewNode),
        riak_core_ring_manager:do_write_ringfile(NewRing),
        io:format("New ring file written to ~p~n",
                  [element(2, riak_core_ring_manager:find_latest_ringfile())])
    catch
        Exception:Reason ->
            lager:error("Reip failed ~p:~p", [Exception,
                                              Reason]),
            io:format("Reip failed, see log for details~n"),
            error
    end.

-spec(ringready([]) -> ok | error).
ringready([]) ->
    try riak_core_status:ringready() of
        {ok, Nodes} ->
            io:format("TRUE All nodes agree on the ring ~p\n", [Nodes]);
        {error, {different_owners, N1, N2}} ->
            io:format("FALSE Node ~p and ~p list different partition owners\n",
                      [N1, N2]),
            error;
        {error, {nodes_down, Down}} ->
            io:format("FALSE ~p down.  All nodes need to be up to check.\n",
                      [Down]),
            error
    catch
        Exception:Reason ->
            lager:error("Ringready failed ~p:~p", [Exception, Reason]),
            io:format("Ringready failed, see log for details~n"),
            error
    end.

pp_json(Obj) ->
    io:format("~s~n", [jsx:prettify(jsx:encode(Obj))]).
