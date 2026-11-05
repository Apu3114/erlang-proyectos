-module(p44_inventario_tests).
-include_lib("eunit/include/eunit.hrl").

-define(HORA, 3600000).

inventario_test_() ->
  {setup, fun arrancar/0, fun detener/1,
   fun(_) ->
     [{"surte el tipo exacto", fun tipo_exacto/0},
      {"FEFO: sale primero la que caduca antes", fun fefo/0},
      {"sustituye por compatible sin gastar O negativo", fun sustituye_sin_gastar_o_neg/0},
      {"sin existencias", fun sin_existencias/0},
      {"una unidad retirada sale del inventario", fun retirada_sale_del_inventario/0},
      {"una unidad caducada sale del inventario", fun caducada_sale_del_inventario/0},
      {"el indice se reconstruye si el inventario se cae", fun se_reconstruye/0}]
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

nueva(Id, Tipo, Comp, CaducaEn) ->
  {ok, _} = p44_unidades_sup:crear(#{id => Id, tipo => Tipo, componente => Comp,
                                     lote => 1, donante => 1000 + Id, caduca_en => CaducaEn}),
  ok.

%% Las unidades avisan al inventario con un cast: esperamos a que el índice lo refleje.
esperar_existencias(Clave, N) -> esperar_existencias(Clave, N, 40).

esperar_existencias(Clave, N, 0) ->
  error({existencias_no_llegaron, Clave, N});
esperar_existencias(Clave, N, Intentos) ->
  %% Si el inventario se está reiniciando, la consulta falla: se reintenta.
  Actual = try maps:get(Clave, p44_inventario:existencias(), 0)
           catch exit:_ -> sin_respuesta
           end,
  case Actual of
    N -> ok;
    _ -> timer:sleep(50), esperar_existencias(Clave, N, Intentos - 1)
  end.

tipo_exacto() ->
  nueva(101, a_pos, globulos_rojos, ahora() + ?HORA),
  esperar_existencias({a_pos, globulos_rojos}, 1),
  ?assertMatch({ok, #{id := 101, tipo := a_pos, exacto := true}},
               p44_inventario:solicitar(a_pos, globulos_rojos, cirugia_1, ?HORA)),
  esperar_existencias({a_pos, globulos_rojos}, 0).

fefo() ->
  nueva(111, b_pos, globulos_rojos, ahora() + 3 * ?HORA),
  nueva(112, b_pos, globulos_rojos, ahora() + 1 * ?HORA),
  nueva(113, b_pos, globulos_rojos, ahora() + 2 * ?HORA),
  esperar_existencias({b_pos, globulos_rojos}, 3),
  Ids = [begin
           {ok, #{id := Id}} = p44_inventario:solicitar(b_pos, globulos_rojos, urgencia, ?HORA),
           Id
         end || _ <- [1, 2, 3]],
  ?assertEqual([112, 113, 111], Ids).

sustituye_sin_gastar_o_neg() ->
  %% Piden A+, no hay A+; hay O+ y O-. Debe salir O+ y dejar el O- intacto.
  nueva(121, o_pos, globulos_rojos, ahora() + ?HORA),
  nueva(122, o_neg, globulos_rojos, ahora() + ?HORA),
  esperar_existencias({o_pos, globulos_rojos}, 1),
  esperar_existencias({o_neg, globulos_rojos}, 1),
  ?assertMatch({ok, #{id := 121, tipo := o_pos, exacto := false}},
               p44_inventario:solicitar(a_pos, globulos_rojos, cirugia_2, ?HORA)),
  %% Ya no hay O+: ahora sí recurre al O negativo.
  ?assertMatch({ok, #{id := 122, tipo := o_neg, exacto := false}},
               p44_inventario:solicitar(a_pos, globulos_rojos, cirugia_3, ?HORA)).

sin_existencias() ->
  ?assertEqual({error, sin_existencias},
               p44_inventario:solicitar(ab_neg, plaquetas, cirugia_4, ?HORA)).

retirada_sale_del_inventario() ->
  nueva(131, ab_pos, plasma, ahora() + ?HORA),
  esperar_existencias({ab_pos, plasma}, 1),
  ok = p44_unidad:retirar(131, donante_positivo),
  esperar_existencias({ab_pos, plasma}, 0),
  ?assertEqual({error, sin_existencias},
               p44_inventario:solicitar(ab_pos, plasma, cirugia_5, ?HORA)).

caducada_sale_del_inventario() ->
  nueva(141, b_neg, globulos_rojos, ahora() + 80),
  esperar_existencias({b_neg, globulos_rojos}, 1),
  timer:sleep(250),
  esperar_existencias({b_neg, globulos_rojos}, 0).

se_reconstruye() ->
  nueva(151, o_pos, plasma, ahora() + ?HORA),
  nueva(152, o_pos, plasma, ahora() + ?HORA),
  esperar_existencias({o_pos, plasma}, 2),
  Pid = whereis(p44_inventario),
  exit(Pid, kill),
  esperar_existencias({o_pos, plasma}, 2),
  ?assertNotEqual(Pid, whereis(p44_inventario)).
