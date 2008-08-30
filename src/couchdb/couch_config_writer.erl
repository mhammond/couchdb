% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License.  You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
% License for the specific language governing permissions and limitations under
% the License.

%% @doc Saves a Key/Value pair to a ini file. The Key consists of a Section
%%      and Option combination. If that combination is found in the ini file
%%      the new value replaces the old value. If only the Section is found the
%%      Option and value combination is appended to the Section. If the Section
%%      does not yet exist in the ini file, it is added and the Option/Value
%%      pair is appended.
%% @see couch_config

-module(couch_config_writer).
-include("couch_db.hrl").

-export([save_to_file/2]).

%% @spec save_to_file(
%%           Config::{{Section::string(), Option::string()}, Value::string()},
%%           File::filename()) -> ok
%% @doc Saves a Section/Key/Value triple to the ini file File::filename()
save_to_file({{Section, Option}, Value}, File) ->

    ?LOG_DEBUG("saving to file '~s', Config: '~p'", [File, {{Section, Option}, Value}]),

    % open file and create a list of lines
    {ok, Stream} = file:read_file(File),
    OldFileContents = binary_to_list(Stream),
    {ok, Lines} = regexp:split(OldFileContents, "\r\n|\n|\r|\032"),

    % prepare input variables
    SectionName = "[" ++ Section ++ "]",
    OptionList = Option,

    % produce the contents for the config file
    NewFileContents =
    case NewFileContents2 = save_loop({{SectionName, OptionList}, Value}, Lines, "", "", []) of
        % we didn't change anything, that means we couldn't find a matching
        % [ini section] in which case we just append a new one.
        OldFileContents ->
            append_new_ini_section({{SectionName, OptionList}, Value}, OldFileContents);
        _ ->
            NewFileContents2
    end,

    % do the save, close the config file and get out
    save_file(File, NewFileContents),
    file:close(Stream),
    ok.

%% @doc Iterates over the lines of an ini file and replaces or adds a new
%%      configuration directive.
save_loop({{Section, Option}, Value}, [Line|Rest], OldCurrentSection, Contents, DoneOptions) ->

    % if we find a new [ini section] (Section), save that for reference
    NewCurrentSection = parse_module(Line, OldCurrentSection),

    % if the current Section is the one we want to change, try to match
    % each line with the Option
    NewContents = case Section of
        NewCurrentSection ->
            % see if the current line matches the variable we want to substitute
            case parse_variable(Line, Option, Value) of
                % nope, return original line
                nomatch ->
                    DoneOptions2 = DoneOptions,
                    Line;
                % got em! return new line
                NewLine ->
                    DoneOptions2 = [Option|DoneOptions],
                    NewLine
            end;
        % if the variable we want to change couldn't be replaced, we append it
        % in the proper module section
        OldCurrentSection ->
            case lists:member(Option, DoneOptions) of
                false ->
                    DoneOptions2 = [Option|DoneOptions],
                    Option ++ " = " ++ Value ++ "\n" ++ Line;
                true ->
                    DoneOptions2 = DoneOptions,
                    Line
            end;
        % otherwise we just print out the original line
        _ ->
            DoneOptions2 = DoneOptions,
            Line
        end,
    % clumsy way to only append a newline character
    % if the line is not empty. We need this to not
    % avoid haveing a newline inserted at the top
    % of the target file each time we save it.
    Contents2 = case Contents of "" -> ""; _ -> Contents ++ "\n" end,

    % go to next line
    save_loop({{Section, Option}, Value}, Rest, NewCurrentSection, Contents2 ++ NewContents, DoneOptions2);

save_loop(_Config, [], _OldSection, NewFileContents, _DoneOption) ->
    % we're out of new lines, just return the new file's contents
    NewFileContents.

append_new_ini_section({{SectionName, Option}, Value}, OldFileContents) ->
    OldFileContents ++ "\n\n" ++ SectionName ++ "\n" ++  Option ++ " = " ++ Value ++ "\n".

%% @spec parse_module(Lins::string(), OldSection::string()) -> string()
%% @doc Tries to match a line against a pattern specifying a ini module or
%%      section ("[Section]"). Returns OldSection if no match is found.
parse_module(Line, OldSection) ->
    case regexp:match(Line, "^\\[([a-zA-Z0-9_-]*)\\]$") of
        nomatch ->
            OldSection;
        {error, Error} ->
            io:format("ini file regex error module: '~s'~n", [Error]),
            OldSection;
        {match, Start, Length} ->
            string:substr(Line, Start, Length)
    end.

%% @spec parse_variable(Line::string(), Option::string(), Value::string()) ->
%%         string() | nomatch
%% @doc Tries to match a variable assignment in Line. Returns nomatch if the
%%      Option is not found. Returns a new line composed of the Option and
%%      Value otherwise.
parse_variable(Line, Option, Value) ->
    case regexp:match(Line, "^" ++ Option ++ "\s?=") of
        nomatch ->
            nomatch;
        {error, Error}->
            io:format("ini file regex error variable: '~s'~n", [Error]),
            nomatch;
        {match, _Start, _Length} ->
            Option ++ " = " ++ Value
    end.

%% @spec save_file(File::filename(), Contents::string()) ->
%%           ok | {error, Reason::string()}
%% @doc Writes Contents to File
save_file(File, Contents) ->
    file:write_file(File, list_to_binary(Contents)).