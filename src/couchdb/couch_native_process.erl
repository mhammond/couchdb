% Licensed under the Apache License, Version 2.0 (the "License"); 
% you may not use this file except in compliance with the License. 
%
% You may obtain a copy of the License at
% http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, 
% software distributed under the License is distributed on an 
% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
% either express or implied. 
%
% See the License for the specific language governing permissions
% and limitations under the License. 
%
% This file drew much inspiration from erlview, which was written by and
% copyright Michael McDaniel [http://autosys.us], and is also under APL 2.0
%
%
% This module provides the smallest possible native view-server.
% With this module in-place, you can add the following to your couch INI files:
%  [native_query_servers]
%  erlang={couch_native_process, start_link, []}
%
% Which will then allow following example map function to be used:
%
%  fun({Doc}) ->
%    % Below, we emit a single record - the _id as key, null as value
%    DocId = proplists:get_value(Doc, <<"_id">>, null),
%    Emit(DocId, null)
%  end.
%
% which should be roughly the same as the javascript:
%    emit(doc._id, null);
%
% As can be seen, it is *not* geared towards being the friendliest or easiest
% to use for authors of native view servers.  For such uses, this should be
% used as a building-block upon which friendlier, or 'higher-level' view
% servers can be built upon, and the sources of such 'helper' functions
% as used above, if
-module(couch_native_process).

-export([start_link/0]).
-export([set_timeout/2, prompt/2, stop/1]).

-define(STATE, native_proc_state).
-record(evstate, {funs=[], query_config=[], list_pid=nil}).

-include("couch_db.hrl").

start_link() ->
    {ok, self()}.

stop(_Pid) ->
    ok.

set_timeout(_Pid, _TimeOut) ->
    ok.

prompt(Pid, Data) when is_pid(Pid), is_list(Data) ->
    case get(?STATE) of
    undefined ->
        State = #evstate{},
        put(?STATE, State);
    State ->
        State
    end,
    case is_pid(State#evstate.list_pid) of
        true ->
            case lists:member(hd(Data), [<<"list_row">>, <<"list_end">>]) of
                true -> ok;
                _ -> throw({error, query_server_error})
            end;
        _ ->
            ok % Not listing
    end,
    {NewState, Resp} = run(State, Data),
    put(?STATE, NewState),
    case Resp of
        {error, Reason} ->
            Msg = io_lib:format("couch native server error: ~p", [Reason]),
            {[{<<"error">>, list_to_binary(Msg)}]};
        _ ->
            Resp
    end.

run(_, [<<"reset">>]) ->
    {#evstate{}, true};
run(_, [<<"reset">>, QueryConfig]) ->
    {#evstate{query_config=QueryConfig}, true};
run(#evstate{funs=Funs}=State, [<<"add_fun">> , BinFunc]) ->
    FunInfo = makefun(BinFunc),
    {State#evstate{funs=Funs ++ [FunInfo]}, true};
run(State, [<<"map_doc">> , Doc]) ->
    Resp = lists:map(fun({Sig, Fun}) ->
        Fun(Doc),
        Data = lists:reverse(erlang:get(Sig)),
        erlang:put(Sig, nil),
        Data
    end, State#evstate.funs),
    {State, Resp};
run(State, [<<"reduce">>, Funs, KVs]) ->
    {Keys, Vals} =
    lists:foldl(fun([K, V], {KAcc, VAcc}) ->
        {[K | KAcc], [V | VAcc]}
    end, {[], []}, KVs),
    Keys2 = lists:reverse(Keys),
    Vals2 = lists:reverse(Vals),
    {State, catch reduce(Funs, Keys2, Vals2, false)};
run(State, [<<"rereduce">>, Funs, Vals]) ->
    {State, catch reduce(Funs, null, Vals, true)};
run(State, [<<"validate">>, BFun, NDoc, ODoc, Ctx]) ->
    {_Sig, Fun} = makefun(BFun),
    {State, catch Fun(NDoc, ODoc, Ctx)};
run(State, [<<"filter">>, Docs, Req, Ctx]) ->
    {_Sig, Fun} = hd(State#evstate.funs),
    Resp = lists:map(fun(Doc) ->
        case (catch Fun(Doc, Req, Ctx)) of
            true -> true;
            _ -> false
        end
    end, Docs),
    {State, [true, Resp]};
run(State, [<<"show">>, BFun, Doc, Req]) ->
    {_Sig, Fun} = makefun(BFun),
    Resp = case (catch Fun(Doc, Req)) of
        FunResp when is_list(FunResp) ->
            FunResp;
        FunResp when is_tuple(FunResp), size(FunResp) == 1 ->
            [<<"resp">>, FunResp];
        FunResp ->
            FunResp
    end,
    {State, Resp};
run(State, [<<"list">>, Head, Req]) ->
    {Sig, Fun} = hd(State#evstate.funs),
    % This is kinda dirty
    case is_function(Fun, 2) of
        false -> throw({error, render_error});
        true -> ok
    end,
    Self = self(),
    SpawnFun = fun() ->
        LastChunk = (catch Fun(Head, Req)),
        case erlang:get(list_started) of
            undefined ->
                Headers =
                case erlang:get(list_headers) of
                    undefined -> [];
                    CurrHdrs -> CurrHdrs
                end,
                Chunks = 
                case erlang:get(Sig) of
                    undefined -> [];
                    CurrChunks -> CurrChunks
                end,
                Self ! {self(), start, lists:reverse(Chunks), Headers},
                erlang:put(Sig, []),
                receive
                    {Self, list_row, _Row} -> ignore;
                    {Self, list_end} -> ignore
                after 5000 ->
                    throw({timeout, list_cleanup_pid})
                end;
            _ ->
                ok
        end,
        LastChunks =
        case erlang:get(Sig) of
            undefined -> [LastChunk];
            OtherChunks -> [LastChunk | OtherChunks]
        end,
        Self ! {self(), list_end, lists:reverse(LastChunks)}
    end,
    erlang:put(do_trap, process_flag(trap_exit, true)),
    Pid = spawn_link(SpawnFun),
    Resp =
    receive
        {Pid, start, Chunks, JsonResp} ->
            [<<"start">>, Chunks, JsonResp]
    after 5000 ->
        throw({timeout, list_start})
    end,
    {State#evstate{list_pid=Pid}, Resp};
run(#evstate{list_pid=Pid}=State, [<<"list_row">>, Row]) when is_pid(Pid) ->
    Pid ! {self(), list_row, Row},
    receive
        {Pid, chunks, Data} ->
            {State, [<<"chunks">>, Data]};
        {Pid, list_end, Data} ->
            receive
                {'EXIT', Pid, normal} -> ok
            after 5000 ->
                throw({timeout, list_cleanup})
            end,
            process_flag(trap_exit, erlang:get(do_trap)),
            {State#evstate{list_pid=nil}, [<<"end">>, Data]}
    after 5000 ->
        throw({timeout, list_row})
    end;
run(#evstate{list_pid=Pid}=State, [<<"list_end">>]) when is_pid(Pid) ->
    Pid ! {self(), list_end},
    Resp =
    receive
        {Pid, list_end, Data} ->
            receive
                {'EXIT', Pid, normal} -> ok
            after 5000 ->
                throw({timeout, list_cleanup})
            end,
            [<<"end">>, Data]            
    after 5000 ->
        throw({timeout, list_end})
    end,
    process_flag(trap_exit, erlang:get(do_trap)),
    {State#evstate{list_pid=nil}, Resp};
run(_, Unknown) ->
    ?LOG_ERROR("Native Process: Unknown command: ~p~n", [Unknown]),
    throw({error, query_server_error}).

bindings(Sig) ->
    Self = self(),

    Log = fun(Msg) ->
        ?LOG_INFO(Msg, [])
    end,

    erlang:put(Sig, []),
    Emit = fun(Id, Value) ->
        Curr = erlang:get(Sig),
        erlang:put(Sig, [[Id, Value] | Curr])
    end,

    Start = fun(Headers) ->
        erlang:put(list_headers, Headers)
    end,

    Send = fun(Chunk) ->
        Curr =
        case erlang:get(Sig) of
            undefined -> [];
            Else -> Else
        end,
        erlang:put(Sig, [Chunk | Curr])
    end,

    GetRow = fun() ->
        case erlang:get(list_started) of
            undefined ->
                Headers =
                case erlang:get(list_headers) of
                    undefined -> {[{<<"headers">>, {[]}}]};
                    CurrHdrs -> CurrHdrs
                end,
                Chunks = 
                case erlang:get(Sig) of
                    undefined -> [];
                    CurrChunks -> CurrChunks
                end,
                Self ! {self(), start, lists:reverse(Chunks), Headers},
                erlang:put(list_started, true);
            _ ->
                Chunks =
                case erlang:get(Sig) of
                    undefined -> [];
                    CurrChunks -> CurrChunks
                end,
                Self ! {self(), chunks, lists:reverse(Chunks)}
        end,
        erlang:put(Sig, []),
        receive
            {Self, list_row, Row} ->
                Row;
            {Self, list_end} ->
                nil
        after 5000 ->
            throw({timeout, list_pid_getrow})
        end
    end,
   
    FoldRows = fun(Fun, Acc) -> foldrows(GetRow, Fun, Acc) end,

    [
        {'Log', Log},
        {'Emit', Emit},
        {'Start', Start},
        {'Send', Send},
        {'GetRow', GetRow},
        {'FoldRows', FoldRows}
    ].

% thanks to erlview, via:
% http://erlang.org/pipermail/erlang-questions/2003-November/010544.html
makefun(Source) ->
    Sig = erlang:md5(Source),
    BindFuns = bindings(Sig),
    {Sig, makefun(Source, BindFuns)}.

makefun(Source, BindFuns) ->
    FunStr = binary_to_list(Source),
    {ok, Tokens, _} = erl_scan:string(FunStr),
    Form = case (catch erl_parse:parse_exprs(Tokens)) of
        {ok, [ParsedForm]} ->
            ParsedForm;
        {error, {LineNum, _Mod, [Mesg, Params]}}=Error ->
            io:format(standard_error, "Syntax error on line: ~p~n", [LineNum]),
            io:format(standard_error, "~s~p~n", [Mesg, Params]),
            throw(Error)
    end,
    Bindings = lists:foldl(fun({Name, Fun}, Acc) ->
        erl_eval:add_binding(Name, Fun, Acc)
    end, erl_eval:new_bindings(), BindFuns),
    {value, Fun, _} = erl_eval:expr(Form, Bindings),
    Fun.

reduce(BinFuns, Keys, Vals, ReReduce) ->
    Funs = case is_list(BinFuns) of
        true ->
            lists:map(fun makefun/1, BinFuns);
        _ ->
            [makefun(BinFuns)]
    end,
    Reds = lists:map(fun({_Sig, Fun}) ->
        Fun(Keys, Vals, ReReduce)
    end, Funs),
    [true, Reds].

foldrows(GetRow, ProcRow, Acc) ->
    case GetRow() of
        nil ->
            {ok, Acc};
        Row ->
            case (catch ProcRow(Row, Acc)) of
                {ok, Acc2} ->
                    foldrows(GetRow, ProcRow, Acc2);
                {stop, Acc2} ->
                    {ok, Acc2}
            end
    end.

%write(Msg) ->
%    write(Msg, []).
%write(Msg, Args) ->
%    io:format(standard_error, Msg, Args).
