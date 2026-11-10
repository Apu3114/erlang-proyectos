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
        {"GET /api/alertas transmite un evento por SSE", {timeout, 20, fun alertas_sse/0}},
        {"Listado, despacho, liberacion, retiro y bitacora HTTP", fun flujo_interfaz/0},
        {"Falla de refrigerador HTTP compromete el lote", fun falla_http/0},
        {"Retiro por donante HTTP afecta a todas sus unidades", fun retiro_donante_http/0},
        {"Registrar donante, crear lote y cargar unidad desde HTTP", fun altas_http/0}]
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
       {"/api/unidades", p44_http_unidades_handler, []},
       {"/api/unidades/:id", p44_http_unidades_handler, []},
       {"/api/unidades/:id/acciones", p44_http_acciones_handler, []},
       {"/api/bitacora", p44_http_bitacora_handler, []},
       {"/api/refrigeradores/:id/falla", p44_http_refrigeradores_handler, []},
       {"/api/donantes/:id/retirar", p44_http_donantes_handler, []},
       {"/api/donantes", p44_http_catalogo_donantes_handler, []},
       {"/api/donantes/:id", p44_http_catalogo_donantes_handler, []},
       {"/api/lotes", p44_http_lotes_handler, []},
       {"/api/lotes/:id", p44_http_lotes_handler, []},
       {"/api/lotes/:id/unidades", p44_http_lote_unidades_handler, []},
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

flujo_interfaz() ->
  nueva(201, a_pos, globulos_rojos),
  esperar_existencias({a_pos, globulos_rojos}, 1),
  {200, {ok, #{<<"unidades">> := Lista}}} = http_get("/api/unidades"),
  ?assert(lists:any(fun(#{<<"id">> := Id}) -> Id =:= 201 end, Lista)),
  {200, {ok, #{<<"id">> := 201}}} = http_get("/api/unidades/201"),
  {400, _} = http_get("/api/unidades/no-es-id"),
  {200, {ok, #{<<"id">> := 201}}} = post("/api/solicitudes",
                                            #{receptor => a_pos, componente => globulos_rojos,
                                              solicitante => <<"cirugia_test">>}),
  {409, _} = post("/api/unidades/201/acciones",
                  #{accion => despachar, solicitante => <<"otro">>, receptor => <<"paciente_demo">>}),
  {200, {ok, #{<<"estado">> := <<"reservada">>}}} = http_get("/api/unidades/201"),
  {200, _} = post("/api/unidades/201/acciones", #{accion => despachar,
                      solicitante => <<"cirugia_test">>, receptor => <<"paciente_demo">>}),
  {409, _} = post("/api/unidades/201/acciones", #{accion => liberar}),
  {200, {ok, #{<<"estado">> := <<"asignada">>}}} = http_get("/api/unidades/201"),
  {200, {ok, #{<<"eventos">> := Eventos}}} = http_get("/api/bitacora?unidad=201"),
  ?assert(lists:any(fun(#{<<"estado">> := E}) -> E =:= <<"asignada">> end, Eventos)),
  nueva(202, ab_pos, plaquetas),
  esperar_existencias({ab_pos, plaquetas}, 1),
  {200, {ok, #{<<"id">> := 202}}} = post("/api/solicitudes",
                                             #{receptor => ab_pos, componente => plaquetas}),
  {200, _} = post("/api/unidades/202/acciones", #{accion => liberar}),
  {200, _} = post("/api/unidades/202/acciones", #{accion => retirar, motivo => <<"prueba tardia">>}),
  {200, {ok, #{<<"estado">> := <<"retirada">>}}} = http_get("/api/unidades/202").

falla_http() ->
  {ok, _} = p44_refrigeradores_sup:crear(99, 99),
  {ok, _} = p44_unidades_sup:crear(#{id => 203, tipo => o_pos, componente => plasma,
                                    lote => 99, donante => 1203, caduca_en => ahora() + ?HORA}),
  esperar_existencias({o_pos, plasma}, 1),
  {200, {ok, #{<<"comprometidas">> := N}}} = post("/api/refrigeradores/99/falla", #{}),
  ?assert(N >= 1),
  {200, {ok, #{<<"estado">> := <<"comprometida">>}}} = http_get("/api/unidades/203").

retiro_donante_http() ->
  {ok, _} = p44_unidades_sup:crear(#{id => 204, tipo => o_neg, componente => plasma,
                                    lote => 1, donante => 4444, caduca_en => ahora() + ?HORA}),
  {200, {ok, #{<<"retiradas">> := 1}}} = post("/api/donantes/4444/retirar",
                                              #{motivo => <<"prueba positiva tardia">>}),
  {200, {ok, #{<<"estado">> := <<"retirada">>}}} = http_get("/api/unidades/204").

altas_http() ->
  {200, {ok, #{<<"donantes">> := Antes}}} = http_get("/api/donantes"),
  ?assert(lists:any(fun(#{<<"id">> := D}) -> D =:= 1203 end, Antes)),
  {400, _} = post("/api/donantes", #{alias => <<"Prueba">>, tipo => <<"no_existe">>}),
  {201, {ok, #{<<"id">> := Donante}}} = post("/api/donantes",
    #{alias => <<"Donante ficticio">>, tipo => o_neg, edad => 25, peso_kg => 70}),
  {200, {ok, #{<<"edad">> := 25, <<"total">> := 0}}} =
    http_get("/api/donantes/" ++ integer_to_list(Donante)),
  {201, {ok, #{<<"id">> := Lote}}} = post("/api/lotes",
    #{nombre => <<"Lote nuevo de prueba">>, componente => plasma}),
  {200, {ok, #{<<"estado">> := <<"operando">>, <<"total">> := 0}}} =
    http_get("/api/lotes/" ++ integer_to_list(Lote)),
  Ruta = "/api/lotes/" ++ integer_to_list(Lote) ++ "/unidades",
  {201, {ok, #{<<"id">> := IdUnidad}}} = post(Ruta, #{donante => Donante}),
  ?assertMatch({disponible, _}, p44_unidad:estado(IdUnidad)),
  {409, {ok, #{<<"error">> := <<"donante_ya_en_lote">>}}} =
    post(Ruta, #{donante => Donante}),
  {409, {ok, #{<<"error">> := <<"donante_bloqueado">>}}} =
    post(Ruta, #{donante => 4444}),
  {200, {ok, #{<<"disponibles">> := 1, <<"total">> := 1}}} =
    http_get("/api/lotes/" ++ integer_to_list(Lote)),
  {200, {ok, #{<<"total">> := 1}}} =
    http_get("/api/donantes/" ++ integer_to_list(Donante)),
  Viejo = whereis(p44_catalogo),
  exit(Viejo, kill),
  esperar_catalogo(Viejo, 40),
  {200, {ok, #{<<"total">> := 1}}} =
    http_get("/api/donantes/" ++ integer_to_list(Donante)),
  {200, {ok, #{<<"total">> := 1}}} =
    http_get("/api/lotes/" ++ integer_to_list(Lote)),
  {200, _} = post("/api/refrigeradores/" ++ integer_to_list(Lote) ++ "/falla", #{}),
  {409, {ok, #{<<"error">> := <<"refrigerador_fallado">>}}} =
    post(Ruta, #{donante => 1203}).

esperar_catalogo(_, 0) -> error(catalogo_no_reinicio);
esperar_catalogo(Viejo, N) ->
  case whereis(p44_catalogo) of
    Pid when is_pid(Pid), Pid =/= Viejo -> ok;
    _ -> timer:sleep(50), esperar_catalogo(Viejo, N - 1)
  end.

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
