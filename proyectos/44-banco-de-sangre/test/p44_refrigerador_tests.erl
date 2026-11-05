-module(p44_refrigerador_tests).
-include_lib("eunit/include/eunit.hrl").

-define(HORA, 3600000).

refrigerador_test_() ->
  {setup, fun arrancar/0, fun detener/1,
   fun(_) ->
     [{"la falla compromete solo su lote", fun falla_compromete_su_lote/0},
      {"tras un crash sigue fallado y re-aplica", fun sobrevive_a_un_crash/0}]
   end}.

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

ahora() -> erlang:system_time(millisecond).

nueva(Id, Tipo, Lote) ->
  {ok, _} = p44_unidades_sup:crear(#{id => Id, tipo => Tipo, componente => globulos_rojos,
                                     lote => Lote, donante => 1000 + Id,
                                     caduca_en => ahora() + ?HORA}),
  ok.

esperar_existencias(Clave, N) -> esperar_existencias(Clave, N, 40).

esperar_existencias(Clave, N, 0) -> error({existencias_no_llegaron, Clave, N});
esperar_existencias(Clave, N, Intentos) ->
  Actual = try maps:get(Clave, p44_inventario:existencias(), 0)
           catch exit:_ -> sin_respuesta
           end,
  case Actual of
    N -> ok;
    _ -> timer:sleep(50), esperar_existencias(Clave, N, Intentos - 1)
  end.

esperar_estado(Id, Estado) -> esperar_estado(Id, Estado, 40).

esperar_estado(Id, Estado, 0) -> error({no_llego, Id, Estado});
esperar_estado(Id, Estado, N) ->
  try p44_unidad:estado(Id) of
    {Estado, _} -> ok;
    _ -> timer:sleep(50), esperar_estado(Id, Estado, N - 1)
  catch
    exit:_ -> timer:sleep(50), esperar_estado(Id, Estado, N - 1)
  end.

falla_compromete_su_lote() ->
  nueva(201, a_pos, 7),
  nueva(202, a_pos, 7),
  nueva(203, a_pos, 7),
  nueva(211, b_pos, 8),
  %% Una de las unidades del lote 7 ya se entregó antes de la falla.
  {ok, 201} = p44_unidad:reservar(201, cirugia, ?HORA),
  ok = p44_unidad:asignar(201, cirugia, paciente),
  {ok, _} = p44_refrigeradores_sup:crear(1, 7),
  esperar_existencias({a_pos, globulos_rojos}, 2),
  ?assertEqual({ok, #{comprometidas => 2, ya_asignadas => [201]}}, p44_refrigerador:fallar(1)),
  ?assertMatch({comprometida, _}, p44_unidad:estado(202)),
  ?assertMatch({comprometida, _}, p44_unidad:estado(203)),
  ?assertMatch({asignada, _}, p44_unidad:estado(201)),
  ?assertMatch({disponible, _}, p44_unidad:estado(211)),
  esperar_existencias({a_pos, globulos_rojos}, 0),
  ?assertEqual({error, sin_existencias},
               p44_inventario:solicitar(a_pos, globulos_rojos, urgencia, ?HORA)).

sobrevive_a_un_crash() ->
  nueva(221, o_pos, 9),
  nueva(222, o_pos, 9),
  {ok, _} = p44_refrigeradores_sup:crear(2, 9),
  {ok, _} = p44_refrigerador:fallar(2),
  esperar_estado(221, comprometida),
  %% Llega una unidad nueva al lote DESPUÉS de la falla, y se cae el refrigerador.
  nueva(223, o_pos, 9),
  Pid = whereis(p44_refrigerador:nombre(2)),
  exit(Pid, kill),
  %% Al reiniciarse recuerda que estaba fallado y la compromete también.
  esperar_estado(223, comprometida),
  ?assertEqual(fallado, p44_refrigerador:estado(2)),
  ?assertNotEqual(Pid, whereis(p44_refrigerador:nombre(2))).
