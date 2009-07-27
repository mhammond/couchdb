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

% This module provides the smallest possible native view-server.
% With this module in-place, you can add the following to your couch INI files:
%  [native_query_servers]
%  erlang={couch_native_process, start_link, []}
%
% Which will then allow following example map function to be used:
%
%  fun({Doc}) ->
%    % The result must be a list of [key, value] pairs.
%    % See mochijson2.erl for proper ErlJSON formatting.
%    % Below, we emit a single record - the _id as key, null as value
%    [[proplists:get_value(Doc, <<"_id">>, null), null]]
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
-record(evstate, {funs=[], query_config=[]}).

start_link() ->
    {ok, self()}.

stop(_Pid) ->
    ok.

set_timeout(_Pid, _TimeOut) ->
    ok.

prompt(Pid, Data) when is_pid(Pid) ->
    case get(?STATE) of
    undefined ->
        State = #evstate{},
        put(?STATE, State);
    State ->
        State
    end,
    {NewState, Resp} = run(State, Data),
    put(?STATE, NewState),
    case Resp of
    {'EXIT', Reason} ->
        % Try and turn the error into a string.
        Msg = iolist_to_binary(io_lib:format("couch native server error: ~p", [Reason])),
        {[{<<"error">>, Msg}]};
    _ -> Resp
    end.

run(_, [<<"reset">>]) ->
    {#evstate{}, true};
run(_, [<<"reset">>, QueryConfig]) ->
    {#evstate{query_config=QueryConfig}, true};
run(#evstate{funs=Funs}=State, [<<"add_fun">> , BinFunc]) ->
    Fun = makefun(BinFunc),
    {State#evstate{funs=Funs ++ [Fun]}, true};
run(State, [<<"map_doc">> , Doc]) ->
    Resp = lists:map(fun(Fa) -> catch Fa(Doc) end, State#evstate.funs),
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
    Fun = makefun(BFun),
    {State, catch Fun(NDoc, ODoc, Ctx)};
run(State, [<<"show">>, BFun, Doc, Req]) ->
    Fun = makefun(BFun),
    {State, catch Fun(Doc, Req)};
run(State, [<<"list">>, Head, Req]) ->
    {State, catch (hd(State#evstate.funs))(Head, Req)}.

% thanks to erlview, via:
% http://erlang.org/pipermail/erlang-questions/2003-November/010544.html
makefun(Source) ->
    FunStr = binary_to_list(Source), 
    {ok, Tokens, _} = erl_scan:string(FunStr),
    {ok, [Form]} = erl_parse:parse_exprs(Tokens),
    Bindings = erl_eval:new_bindings(),
    {value, Fun, _} = erl_eval:expr(Form, Bindings),
    Fun.

reduce(BinFuns, Keys, Vals, ReReduce) ->
    Funs = case is_list(BinFuns) of
        true -> lists:map(fun makefun/1, BinFuns);
        _ -> [makefun(BinFuns)]
    end,
    Reds = lists:map(fun(F) -> F(Keys, Vals, ReReduce) end, Funs),
    [true, Reds].

