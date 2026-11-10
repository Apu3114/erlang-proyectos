%% Simulación del escenario del enunciado: 300 unidades (8 tipos x 3 componentes),
%% accidente múltiple (20 unidades de O negativo), pico de cirugías con reservas que no
%% se usan, retiro por donante positivo tardío y falla de un refrigerador.
%%
%% Desde `rebar3 shell`:  p44_simulador:reiniciar(), p44_simulador:correr().
%%
%% SUPUESTOS (ver README): la plantilla de inventario es una decisión de diseño, no un
%% dato oficial; se carga con O negativo suficiente para que el accidente de 20 unidades
%% sea posible y deje el nivel crítico. El tiempo se comprime: las 20 solicitudes del
%% accidente ocurren de inmediato, no repartidas en una hora real.
-module(p44_simulador).

-export([reiniciar/0, generar/1, cargar/1, correr/0, correr/1, imprimir/1,
         invariantes/0, resumen_existencias/0, conteo_estados/0]).

-define(APP, p44_banco_de_sangre).
-define(HORA_MS, 3600000).
-define(DIA_MS, 86400000).

%% ---------- Preparación ----------

%% Arranca la aplicación desde cero (útil en el shell para repetir la simulación).
%% Borra también la bitácora persistente: si no, el repoblador reconstruye las
%% unidades de la corrida anterior y `cargar/1` choca con ids ya registrados.
reiniciar() ->
  _ = application:stop(?APP),
  Ruta = application:get_env(?APP, dets_path, "priv/p44_bitacora.dets"),
  _ = file:delete(Ruta),
  {ok, _} = application:ensure_all_started(?APP),
  ok.

plantilla() ->
  #{globulos_rojos => [{o_pos, 62}, {a_pos, 40}, {b_pos, 14}, {ab_pos, 5},
                       {o_neg, 24}, {a_neg, 18}, {b_neg, 10}, {ab_neg, 7}],
    plasma => [{o_pos, 28}, {a_pos, 22}, {b_pos, 8}, {ab_pos, 8},
               {o_neg, 6}, {a_neg, 8}, {b_neg, 5}, {ab_neg, 5}],
    plaquetas => [{o_pos, 9}, {a_pos, 7}, {b_pos, 3}, {ab_pos, 2},
                  {o_neg, 3}, {a_neg, 3}, {b_neg, 2}, {ab_neg, 1}]}.

%% Vida útil de referencia en días (del enunciado; verificar fuente vigente).
vida_util_dias(globulos_rojos) -> 42;
vida_util_dias(plaquetas) -> 7;
vida_util_dias(plasma) -> 365.

%% Cada lote es un refrigerador: 1-3 rojos, 4 plaquetas, 5-6 plasma.
lotes(globulos_rojos) -> [1, 2, 3];
lotes(plaquetas) -> [4];
lotes(plasma) -> [5, 6].

%% Genera las 300 unidades, de forma reproducible según la semilla.
generar(Semilla) ->
  rand:seed(exsss, {Semilla, Semilla + 1, Semilla + 2}),
  Ahora = erlang:system_time(millisecond),
  Plantilla = plantilla(),
  Pedidos = [{C, T, K} || C <- [globulos_rojos, plasma, plaquetas],
                          {T, N} <- maps:get(C, Plantilla),
                          K <- lists:seq(1, N)],
  {Unidades, _} = lists:mapfoldl(fun({C, T, K}, Id) -> {unidad(Id, C, T, K, Ahora), Id + 1} end,
                                 1, Pedidos),
  Unidades.

unidad(Id, Comp, Tipo, K, Ahora) ->
  Vida = vida_util_dias(Comp) * ?DIA_MS,
  Restante = round((0.15 + 0.85 * rand:uniform()) * Vida),
  Lotes = lotes(Comp),
  Lote = lists:nth(rand:uniform(length(Lotes)), Lotes),
  #{id => Id, tipo => Tipo, componente => Comp, lote => Lote,
    donante => indice_tipo(Tipo) * 1000 + K, caduca_en => Ahora + Restante}.

indice_tipo(Tipo) ->
  length(lists:takewhile(fun(T) -> T =/= Tipo end, p44_compatibilidad:tipos())) + 1.

%% Crea las unidades y los 6 refrigeradores, y espera a que el inventario las vea.
cargar(Unidades) ->
  lists:foreach(fun(U) -> {ok, _} = p44_unidades_sup:crear(U) end, Unidades),
  lists:foreach(fun(L) -> {ok, _} = p44_refrigeradores_sup:crear(L, L) end, lists:seq(1, 6)),
  esperar_inventario(length(Unidades), 100).

esperar_inventario(N, 0) -> error({inventario_incompleto, N});
esperar_inventario(N, Intentos) ->
  case total(p44_inventario:existencias()) of
    N -> ok;
    _ -> timer:sleep(50), esperar_inventario(N, Intentos - 1)
  end.

total(Existencias) -> lists:sum(maps:values(Existencias)).

%% ---------- Escenario ----------

correr() -> correr(#{}).

correr(Opts) ->
  ok = cargar(generar(maps:get(semilla, Opts, 42))),
  Inicial = resumen_existencias(),
  AlertasIniciales = p44_alertas:evaluar(),
  Accidente = accidente(),
  AlertasAccidente = p44_alertas:evaluar(),
  Pico = pico_de_cirugias(),
  DonantePositivo = donante_positivo(maps:get(unidades, Accidente)),
  Falla = falla_refrigerador(1),
  AlertasFinales = p44_alertas:evaluar(),
  Reporte = #{inventario_inicial => Inicial,
              alertas_iniciales => AlertasIniciales,
              accidente => Accidente,
              alertas_tras_accidente => AlertasAccidente,
              pico_de_cirugias => Pico,
              donante_positivo => DonantePositivo,
              falla_refrigerador => Falla,
              alertas_finales => AlertasFinales,
              estados_finales => conteo_estados(),
              invariantes => invariantes()},
  case maps:get(imprimir, Opts, false) of
    true -> imprimir(Reporte);
    false -> ok
  end,
  Reporte.

%% 20 pacientes del accidente necesitan O negativo (sin tipificar) y se les entrega ya.
accidente() ->
  Resultados =
    [case p44_inventario:solicitar(o_neg, globulos_rojos, {accidente, N}, ?HORA_MS) of
       {ok, #{id := Id, exacto := Exacto}} ->
         ok = p44_unidad:asignar(Id, {accidente, N}, {paciente, N}),
         {ok, Id, Exacto};
       {error, Razon} ->
         {error, Razon}
     end || N <- lists:seq(1, 20)],
  Entregadas = [Id || {ok, Id, _} <- Resultados],
  #{pedidas => 20,
    surtidas => length(Entregadas),
    exactas => length([x || {ok, _, true} <- Resultados]),
    sin_existencias => length([x || {error, _} <- Resultados]),
    unidades => Entregadas}.

%% 50 cirugías programadas de A+ reservan sangre; se opera a 30 y las otras 20 reservas
%% no se usan: vencen su plazo y las unidades vuelven al inventario.
pico_de_cirugias() ->
  Ttl = 500,
  Resultados = [{N, p44_inventario:solicitar(a_pos, globulos_rojos, {cirugia, N}, Ttl)}
                || N <- lists:seq(1, 50)],
  Reservadas = [{N, M} || {N, {ok, M}} <- Resultados],
  {Operadas, NoUsadas} = lists:split(min(30, length(Reservadas)), Reservadas),
  lists:foreach(fun({N, #{id := Id}}) ->
                    ok = p44_unidad:asignar(Id, {cirugia, N}, {paciente_quirurgico, N})
                end, Operadas),
  timer:sleep(Ttl * 2),
  Liberadas = length([x || {_, #{id := Id}} <- NoUsadas,
                           {disponible, _} <- [p44_unidad:estado(Id)]]),
  PorTipo = lists:foldl(fun({_, #{tipo := T}}, Acc) ->
                            maps:update_with(T, fun(X) -> X + 1 end, 1, Acc)
                        end, #{}, Reservadas),
  #{pedidas => 50,
    reservadas => length(Reservadas),
    operadas => length(Operadas),
    reservas_no_usadas => length(NoUsadas),
    liberadas_por_no_uso => Liberadas,
    por_tipo_entregado => PorTipo}.

%% Un donante del accidente resulta positivo tarde: se retira todo lo suyo de inmediato.
donante_positivo(UnidadesEntregadas) ->
  Donante = elegir_donante(UnidadesEntregadas),
  #{donante => Donante,
    resultado => p44_donantes:retirar(Donante, prueba_positiva_tardia)}.

%% Preferimos un donante con varias unidades (rojos + plasma + plaquetas de una donación).
elegir_donante(Ids) ->
  Donantes = [D || Id <- Ids, {_, #{donante := D}} <- [p44_unidad:estado(Id)]],
  Varias = [D || D <- Donantes, length(pg:get_members(p44_pg, {donante, D})) >= 2],
  case Varias of
    [D | _] -> D;
    [] -> hd(Donantes)
  end.

falla_refrigerador(Id) ->
  {ok, Resultado} = p44_refrigerador:fallar(Id),
  #{refrigerador => Id, resultado => Resultado}.

%% ---------- Consultas y verificaciones ----------

resumen_existencias() ->
  Existencias = p44_inventario:existencias(),
  #{total => total(Existencias),
    por_componente => maps:fold(fun({_, C}, N, Acc) ->
                                    maps:update_with(C, fun(X) -> X + N end, N, Acc)
                                end, #{}, Existencias),
    rojos_por_tipo => maps:from_list([{T, N} || {{T, globulos_rojos}, N} <- maps:to_list(Existencias)])}.

%% #{Estado => cuántas unidades}
conteo_estados() ->
  lists:foldl(fun({Estado, _}, Acc) -> maps:update_with(Estado, fun(X) -> X + 1 end, 1, Acc) end,
              #{}, estados_de_unidades()).

estados_de_unidades() ->
  [p44_unidad:estado(Pid)
   || {_, Pid, _, _} <- supervisor:which_children(p44_unidades_sup), is_pid(Pid)].

%% Revisa el historial completo de cada unidad. Debe cumplirse, pase lo que pase:
%%  - nace disponible y solo hace transiciones permitidas;
%%  - jamás se asigna después de su caducidad;
%%  - un estado final (asignada, caducada, retirada) no vuelve atrás.
invariantes() ->
  Ids = [Id || {_, #{id := Id}} <- estados_de_unidades()],
  case lists:append([validar_historial(Id) || Id <- Ids]) of
    [] -> ok;
    Violaciones -> {error, Violaciones}
  end.

validar_historial(Id) ->
  case p44_bitacora:historial(Id) of
    [{_, #{evento := creada, estado := disponible, datos := #{caduca_en := Caduca}}} | Resto] ->
      transiciones(Id, disponible, Resto, Caduca, []);
    _ ->
      [{Id, historial_sin_creacion}]
  end.

transiciones(_Id, _Previo, [], _Caduca, Acc) ->
  Acc;
transiciones(Id, Previo, [{Ts, #{estado := Nuevo}} | Resto], Caduca, Acc) ->
  Invalida = case permitida(Previo, Nuevo) of
               true -> [];
               false -> [{Id, {transicion_invalida, Previo, Nuevo}}]
             end,
  Vencida = case Nuevo =:= asignada andalso Ts > Caduca of
              true -> [{Id, asignada_vencida}];
              false -> []
            end,
  transiciones(Id, Nuevo, Resto, Caduca, Acc ++ Invalida ++ Vencida).

permitida(disponible, N) -> lists:member(N, [reservada, caducada, retirada, comprometida]);
permitida(reservada, N) -> lists:member(N, [asignada, disponible, caducada, retirada, comprometida]);
permitida(comprometida, retirada) -> true;
permitida(_, _) -> false.

%% ---------- Presentación ----------

imprimir(R) ->
  #{inventario_inicial := Ini, accidente := Acc, pico_de_cirugias := Pico,
    donante_positivo := #{donante := Don, resultado := ResDon},
    falla_refrigerador := #{refrigerador := Fr, resultado := ResFr}} = R,
  io:format("~n=== INVENTARIO INICIAL ===~n  total: ~p  por componente: ~p~n  rojos por tipo: ~p~n",
            [maps:get(total, Ini), maps:get(por_componente, Ini), maps:get(rojos_por_tipo, Ini)]),
  io:format("~n=== ALERTAS INICIALES ===~n  ~p niveles bajo el umbral al arrancar~n",
            [length(maps:get(alertas_iniciales, R))]),
  io:format("~n=== ACCIDENTE MULTIPLE (20 x O negativo) ===~n  surtidas: ~p  exactas: ~p  sin existencias: ~p~n",
            [maps:get(surtidas, Acc), maps:get(exactas, Acc), maps:get(sin_existencias, Acc)]),
  io:format("  alertas nuevas: ~p~n", [[Info || {alerta_critica, Info} <- maps:get(alertas_tras_accidente, R)]]),
  io:format("~n=== PICO DE CIRUGIAS (50 x A positivo) ===~n  reservadas: ~p  operadas: ~p  reservas no usadas: ~p  liberadas al vencer el plazo: ~p~n  entregado por tipo: ~p~n",
            [maps:get(reservadas, Pico), maps:get(operadas, Pico), maps:get(reservas_no_usadas, Pico),
             maps:get(liberadas_por_no_uso, Pico), maps:get(por_tipo_entregado, Pico)]),
  io:format("~n=== DONANTE POSITIVO TARDIO (donante ~p) ===~n  retiradas a tiempo: ~p  ya transfundidas (avisar a receptores): ~p~n",
            [Don, maps:get(retiradas, ResDon), maps:get(ya_entregadas, ResDon)]),
  io:format("~n=== FALLA DEL REFRIGERADOR ~p ===~n  unidades comprometidas: ~p  ya entregadas (seguimiento clinico): ~p~n",
            [Fr, maps:get(comprometidas, ResFr), maps:get(ya_asignadas, ResFr)]),
  io:format("~n=== ESTADO FINAL ===~n  unidades por estado: ~p~n  invariantes: ~p~n~n",
            [maps:get(estados_finales, R), maps:get(invariantes, R)]),
  ok.
