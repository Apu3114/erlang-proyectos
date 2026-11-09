-module(p44_http_tests).
-include_lib("eunit/include/eunit.hrl").

-define(HORA, 3600000).
-define(PUERTO, 18080).
-define(BASE, "http://127.0.0.1:18080").

http_test_() ->
  {timeout, 60,
   {setup, fun arrancar/0, fun detener/1,
    fun(_) ->
      [{"GET /api/inventario responde 200 con existencias", fun inventario_vacio/0},
       {"POST /api/solicitudes atiende y descuenta del inventario", fun solicitud_exitosa/0},
       {"POST /api/solicitudes sustituye cuando se agota el tipo exacto", fun solicitud_sustituye/0},
       {"POST /api/solicitudes responde 404 sin existencias", fun solicitud_sin_existencias/0},
       {"POST /api/solicitudes responde 400 con un tipo invalido", fun solicitud_tipo_invalido/0},
       {"POST /api/solicitudes responde 400 con JSON invalido", fun solicitud_json_invalido/0},
       {"GET /metrics responde 200 con conteos coherentes", fun metricas/0},
       {"GET /api/alertas transmite un evento por SSE", {timeout, 20, fun alertas_sse/0}}]
    end}}.

arrancar() ->
  esperar_sin_arbol(40),
  {ok, _} = application:ensure_all_started(inets),
  %% cowboy:start_clear/3 exige que ranch (y cowboy) ya esten corriendo como
  %% aplicaciones OTP. En la app real esto lo hace el boot del release (estan en
  %% la lista 'applications' del .app.src); en este test hay que arrancarlos a mano.
  {ok, _} = application:ensure_all_started(cowboy),
  Ruta = "/tmp/p44_dets_test_" ++ integer_to_list(erlang:unique_integer([positive])) ++ "/",
  application:set_env(p44_banco_de_sangre, dets_path, Ruta ++ "bitacora.dets"),
  application:set_env(p44_banco_de_sangre, http_port, ?PUERTO),
  Dispatch = cowboy_router:compile([
    {'_', [
      {"/api/inventario", p44_http_inventario_handler, []},
      {"/api/solicitudes", p44_http_solicitudes_handler, []},
      {"/api/alertas", p44_http_alertas_handler, []},
      {"/metrics", p44_http_metricas_handler, []}
    ]}
  ]),
  {ok, _} = cowboy:start_clear(p44_http_listener, [{port, ?PUERTO}], #{env => #{dispatch => Dispatch}}),
  {ok, SupPid} = p44_banco_de_sangre_sup:start_link(),
  {SupPid, Ruta}.

detener({SupPid, Ruta}) ->
  ok = cowboy:stop_listener(p44_http_listener),
  Ref = monitor(process, SupPid),
  unlink(SupPid),
  exit(SupPid, shutdown),
  receive {'DOWN', Ref, process, SupPid, _} -> ok after 5000 -> error(arbol_no_cerro) end,
  application:unset_env(p44_banco_de_sangre, dets_path),
  application:unset_env(p44_banco_de_sangre, http_port),
  _ = file:del_dir_r(Ruta),
  ok.

esperar_sin_arbol(0) -> error(arbol_anterior_sigue_vivo);
esperar_sin_arbol(N) ->
  case whereis(p44_banco_de_sangre_sup) of
    undefined -> ok;
    _ -> timer:sleep(50), esperar_sin_arbol(N - 1)
  end.

ahora() -> erlang:system_time(millisecond).

nueva(Id, Tipo, Comp) ->
  {ok, _} = p44_unidades_sup:crear(#{id => Id, tipo => Tipo, componente => Comp,
                                     lote => 1, donante => 1000 + Id, caduca_en => ahora() + ?HORA}),
  ok.

esperar_existencias(Clave, N) -> esperar_existencias(Clave, N, 40).
esperar_existencias(Clave, N, 0) -> error({existencias_no_llegaron, Clave, N});
esperar_existencias(Clave, N, Intentos) ->
  Actual = try maps:get(Clave, p44_inventario:existencias(), 0) catch exit:_ -> sin_respuesta end,
  case Actual of
    N -> ok;
    _ -> timer:sleep(50), esperar_existencias(Clave, N, Intentos - 1)
  end.

%% ---------- peticiones ----------

http_get(Ruta) ->
  {ok, {{_, Codigo, _}, _Headers, Cuerpo}} =
    httpc:request(get, {?BASE ++ Ruta, []}, [], [{body_format, binary}]),
  {Codigo, p44_json:decode(Cuerpo)}.

post(Ruta, MapaJson) ->
  Cuerpo = iolist_to_binary(p44_json:encode(MapaJson)),
  {ok, {{_, Codigo, _}, _Headers, RCuerpo}} =
    httpc:request(post, {?BASE ++ Ruta, [], "application/json", Cuerpo}, [], [{body_format, binary}]),
  {Codigo, p44_json:decode(RCuerpo)}.

%% ---------- tests ----------

inventario_vacio() ->
  {200, {ok, Mapa}} = http_get("/api/inventario"),
  ?assertMatch(#{<<"existencias">> := _}, Mapa).

solicitud_exitosa() ->
  nueva(101, a_pos, globulos_rojos),
  esperar_existencias({a_pos, globulos_rojos}, 1),
  {200, {ok, R}} = post("/api/solicitudes", #{receptor => a_pos, componente => globulos_rojos}),
  ?assertEqual(#{<<"ok">> => true, <<"id">> => 101, <<"tipo">> => <<"a_pos">>,
                 <<"exacto">> => true}, R),
  esperar_existencias({a_pos, globulos_rojos}, 0).

solicitud_sustituye() ->
  nueva(111, o_pos, globulos_rojos),
  esperar_existencias({o_pos, globulos_rojos}, 1),
  {200, {ok, R}} = post("/api/solicitudes", #{receptor => a_pos, componente => globulos_rojos}),
  ?assertEqual(#{<<"ok">> => true, <<"id">> => 111, <<"tipo">> => <<"o_pos">>,
                 <<"exacto">> => false}, R).

solicitud_sin_existencias() ->
  {404, {ok, R}} = post("/api/solicitudes", #{receptor => ab_neg, componente => plaquetas}),
  ?assertEqual(#{<<"ok">> => false, <<"error">> => <<"sin_existencias">>}, R).

solicitud_tipo_invalido() ->
  {400, {ok, R}} = post("/api/solicitudes", #{receptor => <<"no_existe">>, componente => plasma}),
  ?assertEqual(#{<<"ok">> => false, <<"error">> => <<"receptor_invalido">>}, R).

solicitud_json_invalido() ->
  {ok, {{_, Codigo, _}, _H, Cuerpo}} =
    httpc:request(post, {?BASE ++ "/api/solicitudes", [], "application/json", <<"{esto no es json">>},
                  [], [{body_format, binary}]),
  ?assertEqual(400, Codigo),
  ?assertMatch({ok, #{<<"ok">> := false}}, p44_json:decode(Cuerpo)).

metricas() ->
  nueva(121, b_pos, plasma),
  esperar_existencias({b_pos, plasma}, 1),
  {200, {ok, M}} = http_get("/metrics"),
  ?assertMatch(#{<<"unidades_por_estado">> := #{<<"disponible">> := N}} when N >= 1, M),
  ?assertMatch(#{<<"proximas_a_caducar_48h">> := _,
                 <<"unidades_asignadas_historico">> := _}, M).

%% Suscribe este MISMO proceso de test via SSE (httpc en modo streaming), fuerza
%% una alerta critica solicitando toda la sangre de un tipo, y confirma que el
%% evento llega por el socket, no solo que la funcion interna lo calculo.
alertas_sse() ->
  %% Umbral alto SOLO para este tipo/componente, para no disparar alertas de
  %% los otros 23 combinaciones (serian puro ruido en el log de la prueba).
  application:set_env(p44_banco_de_sangre, umbrales, #{{ab_neg, globulos_rojos} => 2}),
  nueva(131, ab_neg, globulos_rojos),
  esperar_existencias({ab_neg, globulos_rojos}, 1),
  %% Perfil de httpc propio para esta prueba: el perfil default ya trae conexiones
  %% en su pool por las peticiones sincronas de las pruebas anteriores de este mismo
  %% modulo, y eso retrasaba la entrega del stream_start de esta peticion async.
  {ok, _} = inets:start(httpc, [{profile, p44_sse_test}]),
  %% {self, once}, no solo 'self': ese modo (flujo controlado, con stream_next/1)
  %% es el que entrega el Pid del manejador en stream_start/stream; con 'self' a
  %% secas (automatico) el mensaje es de 3 elementos, sin Pid.
  {ok, _} = httpc:request(get, {?BASE ++ "/api/alertas", []}, [],
                           [{sync, false}, {stream, {self, once}}, {body_format, binary}],
                           p44_sse_test),
  HandlerPid = receive {http, {_Ref, stream_start, _Headers, Pid}} -> Pid
               after 8000 -> error(sin_conexion_sse)
               end,
  httpc:stream_next(HandlerPid),
  {200, {ok, _}} = post("/api/solicitudes", #{receptor => ab_neg, componente => globulos_rojos}),
  Resultado = esperar_evento_sse(HandlerPid, 60),
  ok = inets:stop(httpc, p44_sse_test),
  application:unset_env(p44_banco_de_sangre, umbrales),
  ?assertMatch({ok, #{<<"tipo">> := <<"alerta_critica">>}}, Resultado).

esperar_evento_sse(_HandlerPid, 0) -> error(sin_evento_sse);
esperar_evento_sse(HandlerPid, N) ->
  receive
    {http, {_Ref, stream, Chunk}} ->
      httpc:stream_next(HandlerPid),
      case extraer_data(Chunk) of
        {ok, _} = R -> R;
        none -> esperar_evento_sse(HandlerPid, N - 1)
      end
  after 200 -> esperar_evento_sse(HandlerPid, N - 1)
  end.

extraer_data(Chunk) ->
  Texto = binary_to_list(Chunk),
  case string:find(Texto, "data: ") of
    nomatch -> none;
    "data: " ++ _ = Resto0 ->
      Resto = string:prefix(Resto0, "data: "),
      [Linea | _] = string:split(Resto, "\n"),
      p44_json:decode(list_to_binary(Linea))
  end.
