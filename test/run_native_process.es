#! /usr/bin/env escript

read() ->
    case io:get_line('') of
        eof -> stop;
        Data -> mochijson2:decode(Data)
    end.

send(Data) when is_binary(Data) ->
    send(binary_to_list(Data));
send(Data) when is_list(Data) ->
    io:format(Data ++ "\n", []).

write(Data) ->
    send(mochijson2:encode(Data)).

loop(Pid) ->
    case read() of
        stop -> ok;
        Json ->
            Resp = couch_native_process:prompt(Pid, Json),
            ok = write(Resp),
            loop(Pid)
    end.

main([]) ->
    code:add_pathz("src/couchdb"),
    code:add_pathz("src/mochiweb"),
    {ok, Pid} = couch_native_process:start_link(),
    loop(Pid).

