-module(gateway_config_worker).

-behavior(ebus_object).

-define(WORKER, gateway_config).

-include("gateway_config.hrl").
-include_lib("ebus/include/ebus.hrl").


%% ebus_object
-export([start_link/2, init/1, handle_call/3, handle_info/2, handle_message/3, terminate/2]).
%% api
-export([handle_qr_code/1, gps_info/0, gps_sat_info/0]).


-record(state, {
                ubx_handle :: pid() | undefined,
                gps_lock=false :: boolean(),
                gps_info=#{} :: ubx:nav_pvt()| #{},
                gps_sat_info=[] :: [ubx:nav_sat()]
               }).

%% API
handle_qr_code(Map) ->
    ?WORKER ! {handle_qr_code, Map}.

gps_info() ->
    gen_server:call(?WORKER, gps_info).

gps_sat_info() ->
    gen_server:call(?WORKER, gps_sat_info).


%% ebus_object

start_link(Bus, Args) ->
    ok = ebus:request_name(Bus, ?CONFIG_APPLICATION_NAME),
    ebus_object:start_link(Bus, ?CONFIG_OBJECT_PATH, ?MODULE, Args, []).

init(Args) ->
    erlang:register(?WORKER, self()),
    Filename = proplists:get_value(filename, Args),
    case (file:read_file_info("/dev/"++Filename)) of
        {ok, _} ->
            Gpio = proplists:get_value(gpio, Args, 68),
            {ok, Pid} = ubx:start_link(Filename, Gpio, [], self()),
            ubx:enable_message(Pid, nav_pvt, 5),
            ubx:enable_message(Pid, nav_sat, 5),
            {ok, #state{ubx_handle=Pid}};
        _ ->
            lager:warning("No UBX filename or device found, running in stub mode"),
            {ok, #state{ubx_handle=undefined}}
    end.


handle_message(?CONFIG_OBJECT(?CONFIG_MEMBER_POSITION), _Msg, State=#state{}) ->
    Position = navmap_to_position(State#state.gps_info),
    {reply,
     [bool, {dict, string, double}],
     [State#state.gps_lock, Position], State};
handle_message(Member, _Msg, State) ->
    lager:warning("Unhandled config message ~p", [Member]),
    {reply_error, ?DBUS_ERROR_NOT_SUPPORTED, Member, State}.


handle_call(gps_info, _From, State=#state{}) ->
    {reply, State#state.gps_info, State};
handle_call(gps_sat_info, _From, State=#state{}) ->
    {reply, State#state.gps_sat_info, State};

handle_call(Msg, _From, State=#state{}) ->
    lager:warning("Unhandled call ~p", [Msg]),
    {reply, ok, State}.


handle_info({nav_pvt, NavMap}, State=#state{}) ->
    FixType = maps:get(fix_type, NavMap, 0),
    case update_gps_lock(FixType, State) of
        {true, NewState} ->
            lager:debug("Signaling GPS lock ~p", [NewState#state.gps_lock]),
            maybe_signal_position(NewState),
            {noreply, State#state{gps_info=NavMap},
             {signal, ?CONFIG_OBJECT_PATH, ?CONFIG_OBJECT_INTERFACE, ?CONFIG_MEMBER_POSITION_LOCK,
              [bool], [NewState#state.gps_lock]}};
        {false, NewState} ->
            maybe_signal_position(NewState),
            {noreply, State#state{gps_info=NavMap}}
    end;
handle_info({nav_sats, NavSats}, State=#state{}) ->
    {noreply, State#state{gps_sat_info=NavSats}};
handle_info(signal_position, State=#state{}) ->
    Position = navmap_to_position(State#state.gps_info),
    lager:debug("Signaling locked GPS position ~p", [Position]),
    {noreply, State,
     {signal, ?CONFIG_OBJECT_PATH, ?CONFIG_OBJECT_INTERFACE, ?CONFIG_MEMBER_POSITION,
      [{dict, string, double}], [Position]}};
handle_info({packet, Packet}, State=#state{}) ->
    lager:notice("Ignoring unrequested ubx packet: ~p", [Packet]),
    {noreply, State};
handle_info({handle_qr_code, Map}, State=#state{}) ->
    lager:info("Signaling Add Gateway with: ~p", [Map]),
    {noreply, State,
     {signal, ?CONFIG_OBJECT_PATH, ?CONFIG_OBJECT_INTERFACE, ?CONFIG_MEMBER_ADD_GW,
      [{dict, string, string}], [Map]
     }
    };

handle_info(_Msg, State) ->
    lager:warning("unhandled info message ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, #state{ubx_handle=Handle}) ->
    case is_pid(Handle) of
        true -> ubx:stop(Handle, normal);
        _ -> ok
    end.


%%
%% Internal
%%

update_gps_lock(3, State=#state{gps_lock=false}) ->
    %% If we get a lock signal lock
    {true, State#state{gps_lock=true}};
update_gps_lock(_, State=#state{gps_lock=false}) ->
    %% No lock and fix, don't signal lock
    {false, State};
update_gps_lock(3, State=#state{gps_lock=true}) ->
    %% We maintain a lock, don't signal lock, signal posiiton
    {false, State};
update_gps_lock(_, State=#state{gps_lock=true}) ->
    %% We lost a lock, signal lock
    {true, State#state{gps_lock=false}}.

navmap_to_position(#{
                     lat := Lat,
                     lon := Lon,
                     height := Height,
                     h_acc := HorizontalAcc,
                     v_acc := VerticalAcc
                    }) ->
    #{
      "lat" => Lat,
      "lon" => Lon,
      "height" => Height,
      "h_accuracy" => HorizontalAcc,
      "v_accuracy" => VerticalAcc
     }.

maybe_signal_position(#state{gps_lock=true}) ->
    self() ! signal_position;
maybe_signal_position(_) ->
    ok.
