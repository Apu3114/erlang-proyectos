%% GET /api/alertas -- Server-Sent Events con los avisos de p44_alertas, en vivo.
%% Cada evento llega como: data: {"tipo":"alerta_critica","tipo_sangre":"o_neg",...}\n\n
-module(p44_http_alertas_handler).
-behaviour(cowboy_loop).

-export([init/2, info/3, terminate/3]).

init(Req0, State) ->
  Req = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>,
                                       <<"cache-control">> => <<"no-cache">>}, Req0),
  %% suscribir/0 une self() (este mismo proceso, el de la conexion) al grupo pg de
  %% alertas; cuando la conexion muera, pg lo quita solo, sin limpieza manual aqui.
  ok = p44_alertas:suscribir(),
  {cowboy_loop, Req, State}.

info({Nombre, Info}, Req, State) when Nombre =:= alerta_critica; Nombre =:= alerta_resuelta ->
  Cuerpo = p44_json:encode(Info#{tipo => Nombre}),
  ok = cowboy_req:stream_events(#{data => Cuerpo}, nofin, Req),
  {ok, Req, State};
info(_Otro, Req, State) ->
  {ok, Req, State}.

terminate(_Razon, _Req, _State) -> ok.
