%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_protocol).

-include("emqx.hrl").
-include("emqx_mqtt.hrl").

-export([init/2, info/1, caps/1, stats/1]).
-export([credentials/1]).
-export([client/1, client_id/1]).
-export([session/1]).
-export([parser/1]).
-export([received/2, process/2, deliver/2, send/2]).
-export([shutdown/2]).

-record(pstate, {
          zone,
          sendfun,
          peername,
          peercert,
          proto_ver,
          proto_name,
          ackprops,
          client_id,
          client_pid,
          conn_props,
          ack_props,
          username,
          session,
          clean_start,
          packet_size,
          will_msg,
          keepalive,
          mountpoint,
          is_super,
          is_bridge,
          enable_acl,
          recv_stats,
          send_stats,
          connected,
          connected_at
         }).

-type(state() :: #pstate{}).

-export_type([state/0]).

-define(LOG(Level, Format, Args, PState),
        emqx_logger:Level([{client, PState#pstate.client_id}], "Client(~s@~s): " ++ Format,
                          [PState#pstate.client_id, esockd_net:format(PState#pstate.peername) | Args])).

%%------------------------------------------------------------------------------
%% Init
%%------------------------------------------------------------------------------

-spec(init(map(), list()) -> state()).
init(#{peername := Peername, peercert := Peercert, sendfun := SendFun}, Options) ->
    Zone = proplists:get_value(zone, Options),
    #pstate{zone         = Zone,
            sendfun      = SendFun,
            peername     = Peername,
            peercert     = Peercert,
            proto_ver    = ?MQTT_PROTO_V4,
            proto_name   = <<"MQTT">>,
            client_id    = <<>>,
            client_pid   = self(),
            username     = init_username(Peercert, Options),
            is_super     = false,
            clean_start  = false,
            packet_size  = emqx_zone:get_env(Zone, max_packet_size),
            mountpoint   = emqx_zone:get_env(Zone, mountpoint),
            is_bridge    = false,
            enable_acl   = emqx_zone:get_env(Zone, enable_acl),
            recv_stats   = #{msg => 0, pkt => 0},
            send_stats   = #{msg => 0, pkt => 0},
            connected    = fasle}.

init_username(Peercert, Options) ->
    case proplists:get_value(peer_cert_as_username, Options) of
        cn -> esockd_peercert:common_name(Peercert);
        dn -> esockd_peercert:subject(Peercert);
        _  -> undefined
    end.

set_username(Username, PState = #pstate{username = undefined}) ->
    PState#pstate{username = Username};
set_username(_Username, PState) ->
    PState.

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

info(#pstate{zone         = Zone,
             peername     = Peername,
             proto_ver    = ProtoVer,
             proto_name   = ProtoName,
             conn_props   = ConnProps,
             client_id    = ClientId,
             username     = Username,
             clean_start  = CleanStart,
             keepalive    = Keepalive,
             mountpoint   = Mountpoint,
             is_super     = IsSuper,
             is_bridge    = IsBridge,
             connected    = Connected,
             connected_at = ConnectedAt}) ->
    [{zone, Zone},
     {peername, Peername},
     {proto_ver, ProtoVer},
     {proto_name, ProtoName},
     {conn_props, ConnProps},
     {client_id, ClientId},
     {username, Username},
     {clean_start, CleanStart},
     {keepalive, Keepalive},
     {mountpoint, Mountpoint},
     {is_super, IsSuper},
     {is_bridge, IsBridge},
     {connected, Connected},
     {connected_at, ConnectedAt}].

caps(#pstate{zone = Zone}) ->
    emqx_mqtt_caps:get_caps(Zone).

credentials(#pstate{zone       = Zone,
                    client_id  = ClientId,
                    username   = Username,
                    peername   = Peername}) ->
    #{zone      => Zone,
      client_id => ClientId,
      username  => Username,
      peername  => Peername}.

client(#pstate{zone       = Zone,
               client_id  = ClientId,
               client_pid = ClientPid,
               peername   = Peername,
               username   = Username}) ->
    #client{id       = ClientId,
            pid      = ClientPid,
            zone     = Zone,
            peername = Peername,
            username = Username}.

client_id(#pstate{client_id = ClientId}) ->
    ClientId.

stats(#pstate{recv_stats = #{pkt := RecvPkt, msg := RecvMsg},
              send_stats = #{pkt := SendPkt, msg := SendMsg}}) ->
    [{recv_pkt, RecvPkt},
     {recv_msg, RecvMsg},
     {send_pkt, SendPkt},
     {send_msg, SendMsg}].

session(#pstate{session = SPid}) ->
    SPid.

parser(#pstate{packet_size = Size, proto_ver = Ver}) ->
    emqx_frame:initial_state(#{packet_size => Size, version => Ver}).

%%------------------------------------------------------------------------------
%% Packet Received
%%------------------------------------------------------------------------------

-spec(received(mqtt_packet(), state())
      -> {ok, state()} | {error, term()} | {error, term(), state()}).
received(?PACKET(Type), PState = #pstate{connected = false})
    when Type =/= ?CONNECT ->
    {error, proto_not_connected, PState};

received(?PACKET(?CONNECT), PState = #pstate{connected = true}) ->
    {error, proto_bad_connect, PState};

received(Packet = ?PACKET(Type), PState) ->
    trace(recv, Packet, PState),
    case catch emqx_packet:validate(Packet) of
        true ->
            process(Packet, inc_stats(recv, Type, PState));
        {'EXIT', {ReasonCode, _Stacktrace}} when is_integer(ReasonCode) ->
            deliver({disconnect, ReasonCode}, PState),
            {error, protocol_error, PState};
        {'EXIT', {Reason, _Stacktrace}} ->
            deliver({disconnect, ?RC_MALFORMED_PACKET}, PState),
            {error, Reason, PState}
    end.

%%------------------------------------------------------------------------------
%% Process Packet
%%------------------------------------------------------------------------------

process(?CONNECT_PACKET(
           #mqtt_packet_connect{proto_name  = ProtoName,
                                proto_ver   = ProtoVer,
                                is_bridge   = IsBridge,
                                clean_start = CleanStart,
                                keepalive   = Keepalive,
                                properties  = ConnProps,
                                client_id   = ClientId,
                                username    = Username,
                                password    = Password} = Connect), PState) ->

    io:format("~p~n", [Connect]),

    PState1 = set_username(Username,
                           PState#pstate{client_id    = ClientId,
                                         proto_ver    = ProtoVer,
                                         proto_name   = ProtoName,
                                         clean_start  = CleanStart,
                                         keepalive    = Keepalive,
                                         conn_props   = ConnProps,
                                         will_msg     = willmsg(Connect, PState),
                                         is_bridge    = IsBridge,
                                         connected    = true,
                                         connected_at = os:timestamp()}),

    connack(
      case check_connect(Connect, PState1) of
          {ok, PState2} ->
              case authenticate(credentials(PState2), Password) of
                  {ok, IsSuper} ->
                      %% Maybe assign a clientId
                      PState3 = maybe_assign_client_id(PState2#pstate{is_super = IsSuper}),
                      %% Open session
                      case try_open_session(PState3) of
                          {ok, SPid, SP} ->
                              PState4 = PState3#pstate{session = SPid},
                              ok = emqx_cm:register_client({client_id(PState4), self()}, info(PState4)),
                              %% Start keepalive
                              start_keepalive(Keepalive, PState4),
                              %% TODO: 'Run hooks' before open_session?
                              emqx_hooks:run('client.connected', [?RC_SUCCESS], client(PState4)),
                              %% Success
                              {?RC_SUCCESS, SP, replvar(PState4)};
                          {error, Error} ->
                              ?LOG(error, "Failed to open session: ~p", [Error], PState1),
                              {?RC_UNSPECIFIED_ERROR, PState1}
                    end;
                  {error, Reason} ->
                      ?LOG(error, "Username '~s' login failed for ~p", [Username, Reason], PState2),
                      {?RC_NOT_AUTHORIZED, PState1}
              end;
          {error, ReasonCode} ->
              {ReasonCode, PState1}
      end);

process(Packet = ?PUBLISH_PACKET(?QOS_0, Topic, _PacketId, _Payload), PState) ->
    case check_publish(Packet, PState) of
        {ok, PState1} ->
            do_publish(Packet, PState1);
        {error, ReasonCode} ->
            ?LOG(warning, "Cannot publish qos0 message to ~s for ~s", [Topic, ReasonCode], PState),
            {ok, PState}
    end;

process(Packet = ?PUBLISH_PACKET(?QOS_1, PacketId), PState) ->
    case check_publish(Packet, PState) of
        {ok, PState1} ->
            do_publish(Packet, PState1);
        {error, ReasonCode} ->
            deliver({puback, PacketId, ReasonCode}, PState)
    end;

process(Packet = ?PUBLISH_PACKET(?QOS_2, PacketId), PState) ->
    case check_publish(Packet, PState) of
        {ok, PState1} ->
            do_publish(Packet, PState1);
        {error, ReasonCode} ->
            deliver({pubrec, PacketId, ReasonCode}, PState)
    end;

process(?PUBACK_PACKET(PacketId, ReasonCode), PState = #pstate{session = SPid}) ->
    ok = emqx_session:puback(SPid, PacketId, ReasonCode),
    {ok, PState};

process(?PUBREC_PACKET(PacketId, ReasonCode), PState = #pstate{session = SPid}) ->
    ok = emqx_session:pubrec(SPid, PacketId, ReasonCode),
    send(?PUBREL_PACKET(PacketId), PState);

process(?PUBREL_PACKET(PacketId, ReasonCode), PState = #pstate{session = SPid}) ->
    ok = emqx_session:pubrel(SPid, PacketId, ReasonCode),
    send(?PUBCOMP_PACKET(PacketId), PState);

process(?PUBCOMP_PACKET(PacketId, ReasonCode), PState = #pstate{session = SPid}) ->
    ok = emqx_session:pubcomp(SPid, PacketId, ReasonCode),
    {ok, PState};

process(?SUBSCRIBE_PACKET(PacketId, Properties, RawTopicFilters),
        PState = #pstate{client_id = ClientId, session = SPid}) ->
    case check_subscribe(
           parse_topic_filters(?SUBSCRIBE, RawTopicFilters), PState) of
        {ok, TopicFilters} ->
            case emqx_hooks:run('client.subscribe', [ClientId], TopicFilters) of
                {ok, TopicFilters1} ->
                    ok = emqx_session:subscribe(SPid, PacketId, Properties, mount(TopicFilters1, PState)),
                    {ok, PState};
                {stop, _} ->
                    ReasonCodes = lists:duplicate(length(TopicFilters),
                                                  ?RC_IMPLEMENTATION_SPECIFIC_ERROR),
                    deliver({suback, PacketId, ReasonCodes}, PState)
            end;
        {error, TopicFilters} ->
            ReasonCodes = lists:map(fun({_, #{rc := ?RC_SUCCESS}}) ->
                                            ?RC_IMPLEMENTATION_SPECIFIC_ERROR;
                                       ({_, #{rc := ReasonCode}}) ->
                                            ReasonCode
                                    end, TopicFilters),
            deliver({suback, PacketId, ReasonCodes}, PState)
    end;

process(?UNSUBSCRIBE_PACKET(PacketId, Properties, RawTopicFilters),
        PState = #pstate{client_id = ClientId, session = SPid}) ->
    case emqx_hooks:run('client.unsubscribe', [ClientId],
                        parse_topic_filters(?UNSUBSCRIBE, RawTopicFilters)) of
        {ok, TopicFilters} ->
            ok = emqx_session:unsubscribe(SPid, PacketId, Properties, mount(TopicFilters, PState)),
            {ok, PState};
        {stop, _Acc} ->
            ReasonCodes = lists:duplicate(length(RawTopicFilters),
                                          ?RC_IMPLEMENTATION_SPECIFIC_ERROR),
            deliver({unsuback, PacketId, ReasonCodes}, PState)
    end;

process(?PACKET(?PINGREQ), PState) ->
    send(?PACKET(?PINGRESP), PState);

process(?PACKET(?DISCONNECT), PState) ->
    %% Clean willmsg
    {stop, normal, PState#pstate{will_msg = undefined}}.

%%------------------------------------------------------------------------------
%% ConnAck -> Client
%%------------------------------------------------------------------------------

connack({?RC_SUCCESS, SP, PState}) ->
    deliver({connack, ?RC_SUCCESS, sp(SP)}, PState);

connack({ReasonCode, PState = #pstate{proto_ver = ProtoVer}}) ->
    _ = deliver({connack, if ProtoVer =:= ?MQTT_PROTO_V5 ->
                                 ReasonCode;
                             true ->
                                 emqx_reason_codes:compat(connack, ReasonCode)
                          end}, PState),
    {error, emqx_reason_codes:name(ReasonCode), PState}.

%%------------------------------------------------------------------------------
%% Publish Message -> Broker
%%------------------------------------------------------------------------------

do_publish(Packet = ?PUBLISH_PACKET(QoS, PacketId),
           PState = #pstate{client_id = ClientId, session = SPid}) ->
    Msg = mount(emqx_packet:to_message(ClientId, Packet), PState),
    _ = emqx_session:publish(SPid, PacketId, Msg),
    puback(QoS, PacketId, PState).

%%------------------------------------------------------------------------------
%% Puback -> Client
%%------------------------------------------------------------------------------

puback(?QOS_0, _PacketId, PState) ->
    {ok, PState};
puback(?QOS_1, PacketId, PState) ->
    deliver({puback, PacketId, ?RC_SUCCESS}, PState);
puback(?QOS_2, PacketId, PState) ->
    deliver({pubrec, PacketId, ?RC_SUCCESS}, PState).

%%------------------------------------------------------------------------------
%% Deliver Packet -> Client
%%------------------------------------------------------------------------------

deliver({connack, ReasonCode}, PState) ->
    send(?CONNACK_PACKET(ReasonCode), PState);

deliver({connack, ReasonCode, SP}, PState) ->
    send(?CONNACK_PACKET(ReasonCode, SP), PState);

deliver({publish, PacketId, Msg}, PState = #pstate{client_id = ClientId,
                                                        is_bridge = IsBridge}) ->
    _ = emqx_hooks:run('message.delivered', [ClientId], Msg),
    Msg1 = unmount(clean_retain(IsBridge, Msg), PState),
    send(emqx_packet:from_message(PacketId, Msg1), PState);

deliver({puback, PacketId, ReasonCode}, PState) ->
    send(?PUBACK_PACKET(PacketId, ReasonCode), PState);

deliver({pubrel, PacketId}, PState) ->
    send(?PUBREL_PACKET(PacketId), PState);

deliver({pubrec, PacketId, ReasonCode}, PState) ->
    send(?PUBREC_PACKET(PacketId, ReasonCode), PState);

deliver({suback, PacketId, ReasonCodes}, PState = #pstate{proto_ver = ProtoVer}) ->
    send(?SUBACK_PACKET(PacketId,
                        if ProtoVer =:= ?MQTT_PROTO_V5 ->
                               ReasonCodes;
                           true ->
                               [emqx_reason_codes:compat(suback, RC) || RC <- ReasonCodes]
                        end), PState);

deliver({unsuback, PacketId, ReasonCodes}, PState) ->
    send(?UNSUBACK_PACKET(PacketId, ReasonCodes), PState);

%% Deliver a disconnect for mqtt 5.0
deliver({disconnect, ReasonCode}, PState = #pstate{proto_ver = ?MQTT_PROTO_V5}) ->
    send(?DISCONNECT_PACKET(ReasonCode), PState);

deliver({disconnect, _ReasonCode}, PState) ->
    {ok, PState}.

%%------------------------------------------------------------------------------
%% Send Packet to Client

-spec(send(mqtt_packet(), state()) -> {ok, state()} | {error, term()}).
send(Packet = ?PACKET(Type), PState = #pstate{proto_ver = Ver, sendfun = SendFun}) ->
    trace(send, Packet, PState),
    case SendFun(emqx_frame:serialize(Packet, #{version => Ver})) of
        ok ->
            emqx_metrics:sent(Packet),
            {ok, inc_stats(send, Type, PState)};
        {error, Reason} ->
            {error, Reason}
    end.

%%------------------------------------------------------------------------------
%% Assign a clientid

maybe_assign_client_id(PState = #pstate{client_id = <<>>, ackprops = AckProps}) ->
    ClientId = emqx_guid:to_base62(emqx_guid:gen()),
    AckProps1 = set_property('Assigned-Client-Identifier', ClientId, AckProps),
    PState#pstate{client_id = ClientId, ackprops = AckProps1};
maybe_assign_client_id(PState) ->
    PState.

try_open_session(#pstate{zone        = Zone,
                         client_id   = ClientId,
                         client_pid  = ClientPid,
                         conn_props  = ConnProps,
                         username    = Username,
                         clean_start = CleanStart}) ->
    case emqx_sm:open_session(#{zone        => Zone,
                                client_id   => ClientId,
                                client_pid  => ClientPid,
                                username    => Username,
                                clean_start => CleanStart,
                                conn_props  => ConnProps}) of
        {ok, SPid} -> {ok, SPid, false};
        Other -> Other
    end.

authenticate(Credentials, Password) ->
    case emqx_access_control:authenticate(Credentials, Password) of
        ok             -> {ok, false};
        {ok, IsSuper}  -> {ok, IsSuper};
        {error, Error} -> {error, Error}
    end.

set_property(Name, Value, undefined) ->
    #{Name => Value};
set_property(Name, Value, Props) ->
    Props#{Name => Value}.

%%------------------------------------------------------------------------------
%% Check Packet
%%------------------------------------------------------------------------------

check_connect(Packet, PState) ->
    run_check_steps([fun check_proto_ver/2,
                     fun check_client_id/2], Packet, PState).

check_proto_ver(#mqtt_packet_connect{proto_ver  = Ver,
                                     proto_name = Name}, _PState) ->
    case lists:member({Ver, Name}, ?PROTOCOL_NAMES) of
        true  -> ok;
        false -> {error, ?RC_PROTOCOL_ERROR}
    end.

%% MQTT3.1 does not allow null clientId
check_client_id(#mqtt_packet_connect{proto_ver = ?MQTT_PROTO_V3,
                                     client_id = <<>>}, _PState) ->
    {error, ?RC_CLIENT_IDENTIFIER_NOT_VALID};

%% Issue#599: Null clientId and clean_start = false
check_client_id(#mqtt_packet_connect{client_id   = <<>>,
                                     clean_start = false}, _PState) ->
    {error, ?RC_CLIENT_IDENTIFIER_NOT_VALID};

check_client_id(#mqtt_packet_connect{client_id   = <<>>,
                                     clean_start = true}, _PState) ->
    ok;

check_client_id(#mqtt_packet_connect{client_id = ClientId}, #pstate{zone = Zone}) ->
    Len = byte_size(ClientId),
    MaxLen = emqx_zone:get_env(Zone, max_clientid_len),
    case (1 =< Len) andalso (Len =< MaxLen) of
        true  -> ok;
        false -> {error, ?RC_CLIENT_IDENTIFIER_NOT_VALID}
    end.

check_publish(Packet, PState) ->
    run_check_steps([fun check_pub_caps/2,
                     fun check_pub_acl/2], Packet, PState).

check_pub_caps(#mqtt_packet{header = #mqtt_packet_header{qos = QoS, retain = R}},
               #pstate{zone = Zone}) ->
    emqx_mqtt_caps:check_pub(Zone, #{qos => QoS, retain => R}).

check_pub_acl(_Packet, #pstate{is_super = IsSuper, enable_acl = EnableAcl})
    when IsSuper orelse (not EnableAcl) ->
    ok;

check_pub_acl(#mqtt_packet{variable = #mqtt_packet_publish{topic_name = Topic}}, PState) ->
    case emqx_access_control:check_acl(credentials(PState), publish, Topic) of
        allow -> ok;
        deny  -> {error, ?RC_NOT_AUTHORIZED}
    end.

run_check_steps([], _Packet, PState) ->
    {ok, PState};
run_check_steps([Check|Steps], Packet, PState) ->
    case Check(Packet, PState) of
        ok ->
            run_check_steps(Steps, Packet, PState);
        {ok, PState1} ->
            run_check_steps(Steps, Packet, PState1);
        Error = {error, _RC} ->
            Error
    end.

check_subscribe(TopicFilters, PState = #pstate{zone = Zone}) ->
    case emqx_mqtt_caps:check_sub(Zone, TopicFilters) of
        {ok, TopicFilter1} ->
            check_sub_acl(TopicFilter1, PState);
        {error, TopicFilter1} ->
            {error, TopicFilter1}
    end.

check_sub_acl(TopicFilters, #pstate{is_super = IsSuper, enable_acl = EnableAcl})
    when IsSuper orelse (not EnableAcl) ->
    {ok, TopicFilters};

check_sub_acl(TopicFilters, PState) ->
    Credentials = credentials(PState),
    lists:foldr(
      fun({Topic, SubOpts}, {Ok, Acc}) ->
              case emqx_access_control:check_acl(Credentials, subscribe, Topic) of
                  allow -> {Ok, [{Topic, SubOpts}|Acc]};
                  deny  -> {error, [{Topic, SubOpts#{rc := ?RC_NOT_AUTHORIZED}}|Acc]}
              end
      end, {ok, []}, TopicFilters).

trace(recv, Packet, PState) ->
    ?LOG(debug, "RECV ~s", [emqx_packet:format(Packet)], PState);
trace(send, Packet, PState) ->
    ?LOG(debug, "SEND ~s", [emqx_packet:format(Packet)], PState).

inc_stats(recv, Type, PState = #pstate{recv_stats = Stats}) ->
    PState#pstate{recv_stats = inc_stats(Type, Stats)};

inc_stats(send, Type, PState = #pstate{send_stats = Stats}) ->
    PState#pstate{send_stats = inc_stats(Type, Stats)}.

inc_stats(Type, Stats = #{pkt := PktCnt, msg := MsgCnt}) ->
    Stats#{pkt := PktCnt + 1, msg := case Type =:= ?PUBLISH of
                                         true  -> MsgCnt + 1;
                                         false -> MsgCnt
                                     end}.

shutdown(_Error, #pstate{client_id = undefined}) ->
    ignore;
shutdown(conflict, #pstate{client_id = ClientId}) ->
    emqx_cm:unregister_client(ClientId),
    ignore;
shutdown(mnesia_conflict, #pstate{client_id = ClientId}) ->
    emqx_cm:unregister_client(ClientId),
    ignore;
shutdown(Error, PState = #pstate{client_id = ClientId, will_msg = WillMsg}) ->
    ?LOG(info, "Shutdown for ~p", [Error], PState),
    %% TODO: Auth failure not publish the will message
    case Error =:= auth_failure of
        true -> ok;
        false -> send_willmsg(WillMsg)
    end,
    emqx_hooks:run('client.disconnected', [Error], client(PState)),
    emqx_cm:unregister_client(ClientId).

willmsg(Packet, PState = #pstate{client_id = ClientId})
    when is_record(Packet, mqtt_packet_connect) ->
    case emqx_packet:to_message(ClientId, Packet) of
        undefined -> undefined;
        Msg -> mount(Msg, PState)
    end.

send_willmsg(undefined) ->
    ignore;
send_willmsg(WillMsg) ->
    emqx_broker:publish(WillMsg).

start_keepalive(0, _PState) ->
    ignore;
start_keepalive(Secs, #pstate{zone = Zone}) when Secs > 0 ->
    Backoff = emqx_zone:get_env(Zone, keepalive_backoff, 0.75),
    self() ! {keepalive, start, round(Secs * Backoff)}.

%%-----------------------------------------------------------------------------
%% Parse topic filters
%%-----------------------------------------------------------------------------

parse_topic_filters(?SUBSCRIBE, TopicFilters) ->
    [begin
         {Topic, TOpts} = emqx_topic:parse(RawTopic),
         {Topic, maps:merge(SubOpts, TOpts)}
     end || {RawTopic, SubOpts} <- TopicFilters];

parse_topic_filters(?UNSUBSCRIBE, TopicFilters) ->
    lists:map(fun emqx_topic:parse/1, TopicFilters).

%%-----------------------------------------------------------------------------
%% The retained flag should be propagated for bridge.
%%-----------------------------------------------------------------------------

clean_retain(false, Msg = #message{flags = #{retain := true}, headers = Headers}) ->
    case maps:get(retained, Headers, false) of
        true  -> Msg;
        false -> emqx_message:set_flag(retain, false, Msg)
    end;
clean_retain(_IsBridge, Msg) ->
    Msg.

%%-----------------------------------------------------------------------------
%% Mount Point
%%-----------------------------------------------------------------------------

mount(Any, #pstate{mountpoint = undefined}) ->
    Any;
mount(Msg = #message{topic = Topic}, #pstate{mountpoint = MountPoint}) ->
    Msg#message{topic = <<MountPoint/binary, Topic/binary>>};
mount(TopicFilters, #pstate{mountpoint = MountPoint}) when is_list(TopicFilters) ->
    [{<<MountPoint/binary, Topic/binary>>, SubOpts} || {Topic, SubOpts} <- TopicFilters].

unmount(Any, #pstate{mountpoint = undefined}) ->
    Any;
unmount(Msg = #message{topic = Topic}, #pstate{mountpoint = MountPoint}) ->
    case catch split_binary(Topic, byte_size(MountPoint)) of
        {MountPoint, Topic1} -> Msg#message{topic = Topic1};
        _Other -> Msg
    end.

replvar(PState = #pstate{mountpoint = undefined}) ->
    PState;
replvar(PState = #pstate{client_id = ClientId, username = Username, mountpoint = MountPoint}) ->
    Vars = [{<<"%c">>, ClientId}, {<<"%u">>, Username}],
    PState#pstate{mountpoint = lists:foldl(fun feed_var/2, MountPoint, Vars)}.

feed_var({<<"%c">>, ClientId}, MountPoint) ->
    emqx_topic:feed_var(<<"%c">>, ClientId, MountPoint);
feed_var({<<"%u">>, undefined}, MountPoint) ->
    MountPoint;
feed_var({<<"%u">>, Username}, MountPoint) ->
    emqx_topic:feed_var(<<"%u">>, Username, MountPoint).

sp(true)  -> 1;
sp(false) -> 0.

