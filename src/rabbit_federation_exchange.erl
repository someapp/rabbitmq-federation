%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_federation_exchange).

-rabbit_boot_step({?MODULE,
                   [{description, "federation exchange type"},
                    {mfa, {rabbit_registry, register,
                           [exchange, <<"x-federation">>,
                            rabbit_federation_exchange]}},
                    {requires, rabbit_registry},
                    {enables, exchange_recovery}]}).

-include_lib("rabbit_common/include/rabbit_exchange_type_spec.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-behaviour(rabbit_exchange_type).
-behaviour(gen_server).

-export([start/0]).

-export([description/0, route/2]).
-export([validate/1, create/2, recover/2, delete/3,
         add_binding/3, remove_bindings/3, assert_args_equivalence/2]).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%----------------------------------------------------------------------------

-define(ETS_NAME, ?MODULE).
-define(TX, false).
-record(state, { downstream_connection, downstream_channel,
                 downstream_exchange, upstreams }).
-record(upstream, {connection, channel, queue, properties, uri}).

%%----------------------------------------------------------------------------

start() ->
    %% TODO get rid of this ets table when bug 23825 lands.
    ?ETS_NAME = ets:new(?ETS_NAME, [public, set, named_table]).

description() ->
    [{name, <<"x-federation">>},
     {description, <<"Federation exchange">>}].

route(X, Delivery) ->
    with_module(X, fun (M) -> M:route(X, Delivery) end).

validate(X) ->
    %% TODO validate args
    with_module(X, fun (M) -> M:validate(X) end).

create(?TX, X = #exchange{ name = Downstream, arguments = Args }) ->
    {array, UpstreamURIs0} =
        rabbit_misc:table_lookup(Args, <<"upstreams">>),
    UpstreamURIs = [U || {longstr, U} <- UpstreamURIs0],
    rabbit_federation_sup:start_child(Downstream, UpstreamURIs),
    with_module(X, fun (M) -> M:create(?TX, X) end);
create(Tx, X) ->
    with_module(X, fun (M) -> M:create(Tx, X) end).

recover(X, Bs) ->
    with_module(X, fun (M) -> M:recover(X, Bs) end).

delete(?TX, X, Bs) ->
    call(X, stop),
    with_module(X, fun (M) -> M:delete(?TX, X, Bs) end);
delete(Tx, X, Bs) ->
    with_module(X, fun (M) -> M:delete(Tx, X, Bs) end).

add_binding(?TX, X, B) ->
    %% TODO add bindings only if needed.
    call(X, {add_binding, B}),
    with_module(X, fun (M) -> M:add_binding(?TX, X, B) end);
add_binding(Tx, X, B) ->
    with_module(X, fun (M) -> M:add_binding(Tx, X, B) end).

remove_bindings(?TX, X, Bs) ->
    %% TODO remove bindings only if needed.
    call(X, {remove_bindings, Bs}),
    with_module(X, fun (M) -> M:remove_bindings(?TX, X, Bs) end);
remove_bindings(Tx, X, Bs) ->
    with_module(X, fun (M) -> M:remove_bindings(Tx, X, Bs) end).

assert_args_equivalence(X = #exchange{name = Name, arguments = Args},
                        NewArgs) ->
    rabbit_misc:assert_args_equivalence(Args, NewArgs, Name,
                                        [<<"upstream">>, <<"type">>]),
    with_module(X, fun (M) -> M:assert_args_equivalence(X, Args) end).

%%----------------------------------------------------------------------------

call(#exchange{ name = Downstream }, Msg) ->
    [{_, Pid}] = ets:lookup(?ETS_NAME, Downstream),
    gen_server:call(Pid, Msg, infinity).

with_module(#exchange{ arguments = Args }, Fun) ->
    %% TODO should this be cached? It's on the publish path.
    {longstr, Type} = rabbit_misc:table_lookup(Args, <<"type">>),
    {ok, Module} = rabbit_registry:lookup_module(
                     exchange, rabbit_exchange:check_type(Type)),
    Fun(Module).

%%----------------------------------------------------------------------------

start_link(Downstream, UpstreamURIs) ->
    gen_server:start_link(?MODULE, {Downstream, UpstreamURIs},
                          [{timeout, infinity}]).

%%----------------------------------------------------------------------------

init({DownstreamX, UpstreamURIs}) ->
    {ok, DConn} = amqp_connection:start(direct),
    {ok, DCh} = amqp_connection:open_channel(DConn),
    %%erlang:monitor(process, DCh),
    true = ets:insert(?ETS_NAME, {DownstreamX, self()}),
    State0 = #state{downstream_connection = DConn, downstream_channel = DCh,
                    downstream_exchange = DownstreamX, upstreams = []},
    {ok, lists:foldl(fun (UpstreamURI, State) ->
                             connect_upstream(UpstreamURI, State)
                     end, State0, UpstreamURIs)}.

handle_call({add_binding, #binding{key = Key, args = Args} }, _From,
            State = #state{ upstreams = Upstreams }) ->
    [bind_upstream(U, Key, Args) || U <- Upstreams],
    {reply, ok, State};

handle_call({remove_bindings, Bs }, _From,
            State = #state{ upstreams = Upstreams }) ->
    [unbind_upstream(U, Key, Args) ||
        #binding{key = Key, args = Args} <- Bs,
        U                                <- Upstreams],
    {reply, ok, State};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(Msg, _From, State) ->
    {stop, {unexpected_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

handle_info({#'basic.deliver'{delivery_tag = _DTag,
                              %%redelivered = Redelivered,
                              %%exchange = Exchange,
                              routing_key = Key},
             Msg}, State = #state{downstream_exchange = #resource {name = X},
                                  downstream_channel = DCh}) ->
    amqp_channel:cast(DCh, #'basic.publish'{exchange = X,
                                            routing_key = Key}, Msg),
    {noreply, State};

handle_info({'DOWN', _Ref, process, Ch, _Reason},
            State = #state{ downstream_channel = DCh }) ->
    case Ch of
        DCh ->
            exit(todo_handle_downstream_channel_death);
        _ ->
            {noreply, restart_upstream_channel(Ch, State)}
    end;

handle_info({connect_upstream, URI}, State) ->
    {noreply, connect_upstream(URI, State)};

handle_info(Msg, State) ->
    {stop, {unexpected_info, Msg}, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state { downstream_channel = DCh,
                            downstream_connection = DConn,
                            downstream_exchange = DownstreamX,
                            upstreams = Upstreams }) ->
    ensure_closed(DConn, DCh),
    [ensure_closed(C, Ch) ||
        #upstream{ connection = C, channel = Ch } <- Upstreams],
    true = ets:delete(?ETS_NAME, DownstreamX),
    ok.

%%----------------------------------------------------------------------------

connect_upstream(UpstreamURI,
                 State = #state{ upstreams = Upstreams,
                                 downstream_exchange = DownstreamX}) ->
    %%io:format("Connecting to ~s...~n", [UpstreamURI]),
    Props = parse_uri(UpstreamURI),
    Params = #amqp_params{host         = proplists:get_value(host, Props),
                          port         = proplists:get_value(port, Props),
                          virtual_host = proplists:get_value(vhost, Props)},
    case amqp_connection:start(network, Params) of
        {ok, Conn} ->
            %%io:format("Done!~n", []),
            {ok, Ch} = amqp_connection:open_channel(Conn),
            erlang:monitor(process, Ch),
            Q = upstream_queue_name(Props, DownstreamX),
            %% TODO: The x-expires should be configurable.
            amqp_channel:call(
              Ch, #'queue.declare'{
                queue     = Q,
                durable   = true,
                arguments = [{<<"x-expires">>, long, 86400000}] }),
            amqp_channel:subscribe(Ch, #'basic.consume'{ queue = Q,
                                                         %% FIXME?
                                                         no_ack = true },
                                   self()),
            State#state{ upstreams =
                             [#upstream{ uri        = UpstreamURI,
                                         connection = Conn,
                                         channel    = Ch,
                                         queue      = Q,
                                         properties = Props } | Upstreams]};
        _E ->
            erlang:send_after(1000, self(), {connect_upstream, UpstreamURI}),
            State
    end.

upstream_queue_name(Props, #resource{ name         = DownstreamName,
                                      virtual_host = DownstreamVHost }) ->
    X = proplists:get_value(exchange, Props),
    Node = list_to_binary(atom_to_list(node())),
    <<"federation: ", X/binary, " -> ", Node/binary,
      "-", DownstreamVHost/binary, "-", DownstreamName/binary>>.

restart_upstream_channel(OldPid, State = #state{ upstreams = Upstreams }) ->
    {[#upstream{ uri = URI }], Rest} =
        lists:partition(fun (#upstream{ channel = Ch }) ->
                                OldPid == Ch
                        end, Upstreams),
    connect_upstream(URI, State#state{ upstreams = Rest }).

bind_upstream(#upstream{ channel = Ch, queue = Q, properties = Props },
              Key, Args) ->
    X = proplists:get_value(exchange, Props),
    amqp_channel:call(Ch, #'queue.bind'{queue       = Q,
                                        exchange    = X,
                                        routing_key = Key,
                                        arguments   = Args}).

unbind_upstream(#upstream{ channel = Ch, queue = Q, properties = Props },
                Key, Args) ->
    X = proplists:get_value(exchange, Props),
    %% We may already be unbound if e.g. someone has deleted the upstream
    %% exchange
    try amqp_channel:call(Ch, #'queue.unbind'{queue       = Q,
                                              exchange    = X,
                                              routing_key = Key,
                                              arguments   = Args})
    catch exit:{{server_initiated_close, ?NOT_FOUND, _}, _} ->
            %% TODO this is inadequate. The channel will die.
            ok
    end.

parse_uri(URI) ->
    Props = uri_parser:parse(
              binary_to_list(URI), [{host, undefined}, {path, "/"},
                                    {port, 5672},      {'query', []}]),
    [VHostEnc, XEnc] = string:tokens(
                         proplists:get_value(path, Props), "/"),
    VHost = httpd_util:decode_hex(VHostEnc),
    X = httpd_util:decode_hex(XEnc),
    [{vhost,    list_to_binary(VHost)},
     {exchange, list_to_binary(X)}] ++ Props.

ensure_closed(Conn, Ch) ->
    try amqp_channel:close(Ch)
    catch exit:{noproc, _} -> ok
    end,
    try amqp_connection:close(Conn)
    catch exit:{noproc, _} -> ok
    end.