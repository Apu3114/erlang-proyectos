-module(p44_unidad_tests).
-include_lib("eunit/include/eunit.hrl").

-define(HORA, 3600000).

unidad_test_() ->
  {setup, fun arrancar/0, fun detener/1,
   fun(_) ->
     [{"reservar y asignar", fun reservar_y_asignar/0},
      {"no se reserva dos veces", fun no_se_reserva_dos_veces/0},
      {"reserva ajena no asigna", fun reserva_ajena_no_asigna/0},
      {"una unidad vencida nunca se reserva", fun vencida_nunca_se_reserva/0},
      {"caduca sola", fun caduca_sola/0},
      {"reserva no usada se libera", fun reserva_no_usada_se_libera/0},
      {"retirada no se reserva", fun retirada_no_se_reserva/0},
      {"asignada no se retira", fun asignada_no_se_retira/0},
      {"sobrevive a un crash", fun sobrevive_a_un_crash/0},
      {"trazabilidad", fun trazabilidad/0}]
   end}.

arrancar() ->
  esperar_sin_arbol(40),
  %% Bitacora en un DETS temporal propio de esta suite: la persistencia real es
  %% entre reinicios del NODO, no debe filtrarse entre modulos de prueba que
  %% reutilizan los mismos ids numericos.
  Ruta = "/tmp/p44_dets_test_" ++ integer_to_list(erlang:unique_integer([positive])) ++ "/",
  application:set_env(p44_banco_de_sangre, dets_path, Ruta ++ "bitacora.dets"),
  {ok, Pid} = p44_banco_de_sangre_sup:start_link(),
  {Pid, Ruta}.

detener({Pid, Ruta}) ->
  Ref = monitor(process, Pid),
  unlink(Pid),
  exit(Pid, shutdown),
  receive {'DOWN', Ref, process, Pid, _} -> ok
  after 5000 -> error(arbol_no_cerro)
  end,
  application:unset_env(p44_banco_de_sangre, dets_path),
  _ = file:del_dir_r(Ruta),
  ok.

esperar_sin_arbol(0) -> error(arbol_anterior_sigue_vivo);
esperar_sin_arbol(N) ->
  case whereis(p44_banco_de_sangre_sup) of
    undefined -> ok;
    _ -> timer:sleep(50), esperar_sin_arbol(N - 1)
  end.

nueva(Id, CaducaEn) ->
  Datos = #{id => Id, tipo => o_neg, componente => globulos_rojos,
            lote => 1, donante => 100 + Id, caduca_en => CaducaEn},
  {ok, _} = p44_unidades_sup:crear(Datos),
  Datos.

ahora() -> erlang:system_time(millisecond).

reservar_y_asignar() ->
  nueva(1, ahora() + ?HORA),
  ?assertEqual({ok, 1}, p44_unidad:reservar(1, cirugia_7, ?HORA)),
  ?assertMatch({reservada, _}, p44_unidad:estado(1)),
  ?assertEqual(ok, p44_unidad:asignar(1, cirugia_7, paciente_9)),
  ?assertMatch({asignada, #{receptor := paciente_9}}, p44_unidad:estado(1)).

no_se_reserva_dos_veces() ->
  nueva(2, ahora() + ?HORA),
  {ok, 2} = p44_unidad:reservar(2, a, ?HORA),
  ?assertEqual({error, {no_disponible, reservada}}, p44_unidad:reservar(2, b, ?HORA)).

reserva_ajena_no_asigna() ->
  nueva(3, ahora() + ?HORA),
  {ok, 3} = p44_unidad:reservar(3, a, ?HORA),
  ?assertEqual({error, no_es_tu_reserva}, p44_unidad:asignar(3, b, paciente)).

vencida_nunca_se_reserva() ->
  nueva(4, ahora() - 1),
  ?assertMatch({error, _}, p44_unidad:reservar(4, a, ?HORA)),
  ?assertMatch({caducada, _}, p44_unidad:estado(4)).

caduca_sola() ->
  nueva(5, ahora() + 60),
  timer:sleep(250),
  ?assertMatch({caducada, _}, p44_unidad:estado(5)).

reserva_no_usada_se_libera() ->
  nueva(6, ahora() + ?HORA),
  {ok, 6} = p44_unidad:reservar(6, a, 50),
  timer:sleep(250),
  ?assertMatch({disponible, _}, p44_unidad:estado(6)).

retirada_no_se_reserva() ->
  nueva(7, ahora() + ?HORA),
  ?assertEqual(ok, p44_unidad:retirar(7, donante_positivo)),
  ?assertEqual({error, {no_disponible, retirada}}, p44_unidad:reservar(7, a, ?HORA)).

asignada_no_se_retira() ->
  nueva(8, ahora() + ?HORA),
  {ok, 8} = p44_unidad:reservar(8, a, ?HORA),
  ok = p44_unidad:asignar(8, a, paciente),
  ?assertEqual({error, ya_asignada}, p44_unidad:retirar(8, donante_positivo)).

sobrevive_a_un_crash() ->
  nueva(9, ahora() + ?HORA),
  {ok, 9} = p44_unidad:reservar(9, cirugia_1, ?HORA),
  Pid = whereis(p44_unidad:nombre(9)),
  exit(Pid, kill),
  {reservada, #{solicitante := cirugia_1}} = esperar_estado(9, reservada),
  ?assertNotEqual(Pid, whereis(p44_unidad:nombre(9))).

trazabilidad() ->
  nueva(10, ahora() + ?HORA),
  {ok, 10} = p44_unidad:reservar(10, cirugia_2, ?HORA),
  ok = p44_unidad:asignar(10, cirugia_2, paciente_3),
  Estados = [maps:get(estado, E) || {_Ts, E} <- p44_bitacora:historial(10)],
  ?assertEqual([disponible, reservada, asignada], Estados).

esperar_estado(Id, Estado) -> esperar_estado(Id, Estado, 40).

esperar_estado(Id, Estado, 0) -> error({no_llego, Id, Estado});
esperar_estado(Id, Estado, N) ->
  try p44_unidad:estado(Id) of
    {Estado, _} = R -> R;
    _ -> timer:sleep(50), esperar_estado(Id, Estado, N - 1)
  catch
    exit:_ -> timer:sleep(50), esperar_estado(Id, Estado, N - 1)
  end.
