-module(p44_banco_de_sangre_app).
-behaviour(application).

-export([start/2, stop/1]).

-define(LISTENER, p44_http_listener).

start(_StartType, _StartArgs) ->
  ok = iniciar_http(),
  p44_banco_de_sangre_sup:start_link().

stop(_State) ->
  _ = cowboy:stop_listener(?LISTENER),
  ok.

iniciar_http() ->
  Dispatch = cowboy_router:compile([
    {'_', [
      {"/api/inventario", p44_http_inventario_handler, []},
      {"/api/solicitudes", p44_http_solicitudes_handler, []},
      {"/api/alertas", p44_http_alertas_handler, []},
      {"/api/unidades", p44_http_unidades_handler, []},
      {"/api/unidades/:id", p44_http_unidades_handler, []},
      {"/api/unidades/:id/acciones", p44_http_acciones_handler, []},
      {"/api/bitacora", p44_http_bitacora_handler, []},
      {"/api/refrigeradores/:id/falla", p44_http_refrigeradores_handler, []},
      {"/api/donantes/:id/retirar", p44_http_donantes_handler, []},
      {"/metrics", p44_http_metricas_handler, []}
    ]}
  ]),
  Puerto = application:get_env(p44_banco_de_sangre, http_port, 8080),
  %% El proxy HTTP publica el sitio; Cowboy solo recibe conexiones locales.
  Ip = application:get_env(p44_banco_de_sangre, http_ip, {127, 0, 0, 1}),
  case cowboy:start_clear(?LISTENER, [{ip, Ip}, {port, Puerto}], #{env => #{dispatch => Dispatch}}) of
    {ok, _Pid} -> ok;
    {error, {already_started, _Pid}} -> ok;
    {error, eaddrinuse} ->
      logger:error("No se pudo abrir el puerto ~p: ya esta en uso. "
                   "Revisa si hay otra instancia corriendo (otro rebar3 shell, "
                   "otro release, u otra app) y detenla primero.", [Puerto]),
      {error, {puerto_ocupado, Puerto}};
    {error, Razon} ->
      logger:error("No se pudo arrancar el servidor HTTP en el puerto ~p: ~p",
                   [Puerto, Razon]),
      {error, {http_no_arranco, Razon}}
  end.
