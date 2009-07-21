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
% --------
%  fun(Doc) ->
%    % The result must be a list of {key, value} tuples.
%    % 'value' itself may be a tuple of {key, value} tuples to emit an 'object'
%    % Below, we emit a single record - the _id as key, null as value
%    [ {proplists:get_value(Doc, <<"_id">>), null} ]
%    end.
% -------
% which should be roughly the same as the javascript:
%    emit(doc._id, null);
% As can be seen, it is *not* geared towards being the friendliest or easiest
% to use for authors of native view servers.  For such uses, this should be
% used as a building-block upon which friendlier, or 'higher-level' view
% servers can be built upon, and the sources of such 'helper' functions
% as used above, if

-module(couch_native_process).
-behaviour(gen_server).

-export([start_link/0]).
-export([set_timeout/2, prompt/2, stop/1]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-include("couch_db.hrl").

-record(evstate, {fun_was="everywhere", funs=[], query_config=[]}).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

stop(Pid) ->
    gen_server:cast(Pid, stop).


set_timeout(_Pid, _TimeOut) ->
    ok.

prompt(Pid, Data) ->
    case gen_server:call(Pid, {prompt, Data}, infinity) of
        {ok, Result} ->
            Result;
        Error ->
            %?LOG_ERROR("Native Server Error :: ~p",[Error]),
            throw(Error)
    end.

init([]) ->
    {ok, #evstate{fun_was="init"}}.

terminate(_Reason, _State) ->
    ok.

handle_call({prompt, [<<"reset">>]}, _From, _State) ->
    {reply, {ok, true}, #evstate{fun_was="reset", funs=[]}};
handle_call({prompt, [<<"reset">>, QueryConfig]}, _From, _State) ->
    {reply, {ok, true},
        #evstate{
            fun_was="reset",
            funs=[],
            query_config=QueryConfig
        }
    };
handle_call({prompt, [<<"add_fun">> , BinFunc]}, _From, State) ->
    BinFunctions =
    case is_list(BinFunc) of
        true -> BinFunc;
        _ -> [BinFunc]
    end,

    % thanks to erlview, via:
    % http://erlang.org/pipermail/erlang-questions/2003-November/010544.html
    % for the scan/parse/eval
    NewFuns = lists:map(fun makefun/1, BinFunctions),
    NewState = #evstate{
        fun_was="add_fun",
        funs=State#evstate.funs ++ NewFuns,
        query_config=State#evstate.query_config
    },
    {reply, {ok, true}, NewState};
handle_call({prompt, [<<"map_doc">> , Doc]} , _From , State) ->
    L = lists:map(fun(Fa) ->
        Fa(Doc)
    end, State#evstate.funs),
    {reply, {ok, L}, State#evstate{fun_was="map_doc"}};
handle_call({prompt, [<<"reduce">>, Funs, KVs]}, _From, State) ->
    {Keys, Vals} =
    lists:foldl(fun([K, V], {KAcc, VAcc}) ->
        {[K | KAcc], [V | VAcc]}
    end, {[], []}, KVs),
    Keys2 = lists:reverse(Keys),
    Vals2 = lists:reverse(Vals),
    Resp = reduce(Funs, Keys2, Vals2, false),
    {reply, {ok, Resp}, State#evstate{fun_was="reduce"}};
handle_call({prompt, [<<"rereduce">>, Funs, Vals]}, _From, State) ->
    Resp = reduce(Funs, null, Vals, true),
    {reply, {ok, Resp}, State#evstate{fun_was="rereduce"}};
handle_call({prompt, [<<"validate">>, BFun, NDoc, ODoc, Ctx]}, _From, State) ->
    Fun = makefun(BFun),
    Resp = (catch Fun(NDoc, ODoc, Ctx)),
    {reply, {ok, Resp}, State#evstate{fun_was="validate"}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

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

