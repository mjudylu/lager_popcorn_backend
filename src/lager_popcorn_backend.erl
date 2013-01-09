-module(lager_popcorn_backend).
-author('marc.e.campbell@gmail.com').
-behaviour(gen_event).

-export([init/1,
         handle_call/2,
         handle_event/2,
         handle_info/2,
         terminate/2,
         code_change/3
]).

-include_lib("lager/include/lager.hrl").

-record(state, {socket,
                level         :: atom(),
                popcorn_host  :: string(),
                popcorn_port  :: number(),
                node_role     :: string(),
                node_version  :: string()
}).

-record(message, {message_id                   :: string(),
                  is_group            = false  :: boolean(),
                  is_gae              = false  :: boolean(),
                  sender_token                 :: string(),
                  recipient_token              :: string(),
                  created_time_client          :: string(),
                  created_time_server          :: string(),
                  body                         :: string(),
                  ttl                          :: pos_integer(),
                  dor                 = false  :: boolean(),
                  status                       :: string(),
                  attachment                   :: xmpp_message:attach_content(),
                  attachment_count    = 0      :: non_neg_integer(),
                  attachment_size     = 0      :: non_neg_integer(),
                              attachment_message_id        :: string(),
                  is_recalled         = false  :: boolean(),
                  sort_number                  :: pos_integer(),
                  sort_series                  :: pos_integer(),
                  push_alert          = opaque :: atom()
                 }).

init(Params) ->
    Level        = proplists:get_value(level, Params, debug),
    Popcorn_Host = proplists:get_value(popcorn_host, Params, "localhost"),
    Popcorn_Port = proplists:get_value(popcorn_port, Params, 9125),
    Node_Role    = proplists:get_value(node_role, Params, "no_role"),
    Node_Version = proplists:get_value(node_version, Params, "no_version"),
    
    {ok, Socket} = gen_udp:open(0, [list]),

    {ok, #state{socket       = Socket,
                level        = Level,
                popcorn_host = Popcorn_Host,
                popcorn_port = Popcorn_Port,
                node_role    = Node_Role,
                node_version = Node_Version}}.

handle_call({set_loglevel, Level}, State) ->
    {ok, ok, State#state{level=lager_util:level_to_num(Level)}};

handle_call(get_loglevel, State) ->
    {ok, State#state.level, State};

handle_call(_Request, State) ->
   io:format("Other call3~n"),
    {ok, ok, State}.

handle_event({lager_event, #lager_event{module=Module, function=Function, line=Line,
                                        pid=Pid, message=Message, level=Level}}, State) ->
    Msg = [filter_msg_obj(E) || E <- Message],
    Encoded_Message = encode_protobuffs_message(node(), State#state.node_role, State#state.node_version, Level, "", "", Msg,
                                                Module, Function, Line, Pid),

    gen_udp:send(State#state.socket,
                 State#state.popcorn_host,
                 State#state.popcorn_port,
                 Encoded_Message),

    {ok, State};

handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) ->
   io:format("Other info~n"),
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    %% TODO version number should be read here, or else we don't support upgrades
    {ok, State}.

encode_protobuffs_message(Node, Node_Role, Node_Version, Severity, _Date, _Time, Message,
        Module, Function, Line, Pid) ->
    erlang:iolist_to_binary([
        protobuffs:encode(1, atom_to_list(Node), string),
        protobuffs:encode(2, Node_Role, string),
        protobuffs:encode(3, Node_Version, string),
        protobuffs:encode(4, lager_util:level_to_num(Severity), uint32),
        protobuffs:encode(5, Message, string),
        protobuffs:encode(6, opt(Module, <<"">>), string),
        protobuffs:encode(7, opt(Function, <<"">>), string),
        protobuffs:encode(8, opt(Line, <<"">>), string),
        protobuffs:encode(9, opt(Pid, <<"">>), string)
    ]).

%% Return the protobufs data for optional fields
opt(undefined, Default) -> Default;
opt(Value, _) when is_integer(Value) -> list_to_binary(integer_to_list(Value));
opt(Value, _) when is_pid(Value)     -> list_to_binary(pid_to_list(Value));
opt(Value, _) when is_atom(Value)    -> list_to_binary(atom_to_list(Value));
opt(Value, _) when is_binary(Value)  -> Value;
opt(Value, _) when is_list(Value)    -> list_to_binary(Value);
opt(_, Default) -> Default.

%% Filter out plain msg text
filter_msg_obj(Arg) when is_list(Arg) ->
    case string:str(Arg, "{message,") of
        0 -> Arg;
        Begin_Idx ->
            {Prefix, Rest} = lists:split(Begin_Idx-1, Arg),
            End_Idx = string:chr(Rest, $}),
            {Msg_Str, Suffix} = lists:split(End_Idx, Rest),
            Msg = string:tokens(Msg_Str, ","),
            case length(Msg) of
                #message.push_alert ->
                    {Left, [Body|Right]} = lists:split(#message.body-1, Msg),
                    {true, Prefix ++ string:join(Left ++ ["\"" ++ string:chars($x, 5) ++ integer_to_list(length(Body)-2) ++ "\""] ++ Right, ",") ++ Suffix};
                _ -> Arg
            end
    end;
filter_msg_obj(Arg) -> Arg.
