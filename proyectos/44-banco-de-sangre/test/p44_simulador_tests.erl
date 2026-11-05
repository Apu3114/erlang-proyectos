-module(p44_simulador_tests).
-include_lib("eunit/include/eunit.hrl").

simulador_test_() ->
  {timeout, 120,
   {setup, fun arrancar/0, fun detener/1,
    fun(_) -> [{"escenario completo", fun escenario/0}] end}}.

arrancar() ->
  esperar_sin_arbol(40),
  {ok, Pid} = p44_banco_de_sangre_sup:start_link(),
  Pid.

detener(Pid) ->
  Ref = monitor(process, Pid),
  unlink(Pid),
  exit(Pid, shutdown),
  receive {'DOWN', Ref, process, Pid, _} -> ok
  after 5000 -> error(arbol_no_cerro)
  end.

esperar_sin_arbol(0) -> error(arbol_anterior_sigue_vivo);
esperar_sin_arbol(N) ->
  case whereis(p44_banco_de_sangre_sup) of
    undefined -> ok;
    _ -> timer:sleep(50), esperar_sin_arbol(N - 1)
  end.

escenario() ->
  R = p44_simulador:correr(#{semilla => 7}),
  %% Inventario del enunciado
  ?assertEqual(300, maps:get(total, maps:get(inventario_inicial, R))),
  %% Accidente: las 20 unidades de O negativo se surten, todas exactas
  Acc = maps:get(accidente, R),
  ?assertEqual(20, maps:get(surtidas, Acc)),
  ?assertEqual(20, maps:get(exactas, Acc)),
  %% ... y el nivel de O negativo (24 - 20 = 4) queda bajo el umbral: alerta crítica
  ?assert(lists:any(fun({alerta_critica, #{tipo := o_neg, componente := globulos_rojos}}) -> true;
                       (_) -> false
                    end, maps:get(alertas_tras_accidente, R))),
  %% Pico de cirugías: 40 A+ exactos y 10 sustituidos por el compatible menos valioso
  Pico = maps:get(pico_de_cirugias, R),
  ?assertEqual(50, maps:get(reservadas, Pico)),
  ?assertEqual(#{a_pos => 40, a_neg => 10}, maps:get(por_tipo_entregado, Pico)),
  %% Las reservas que no se usaron vuelven al inventario
  ?assertEqual(20, maps:get(reservas_no_usadas, Pico)),
  ?assertEqual(20, maps:get(liberadas_por_no_uso, Pico)),
  %% Todas las unidades siguen existiendo y el historial cumple las invariantes
  ?assertEqual(300, lists:sum(maps:values(maps:get(estados_finales, R)))),
  ?assertEqual(ok, maps:get(invariantes, R)),
  %% La falla del refrigerador afectó a su lote
  #{resultado := ResFr} = maps:get(falla_refrigerador, R),
  ?assert(maps:get(comprometidas, ResFr) + length(maps:get(ya_asignadas, ResFr)) > 0).
