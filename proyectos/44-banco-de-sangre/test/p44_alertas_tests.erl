-module(p44_alertas_tests).
-include_lib("eunit/include/eunit.hrl").

-define(HORA, 3600000).
-define(APP, p44_banco_de_sangre).

alertas_test_() ->
  {setup, fun arrancar/0, fun detener/1,
   fun(_) ->
     [{"avisa al bajar del umbral y al recuperarse, sin repetir", fun avisa_por_transicion/0}]
   end}.

arrancar() ->
  esperar_sin_arbol(40),
  application:set_env(?APP, umbral_default, 0),
  application:set_env(?APP, umbrales, #{{o_neg, globulos_rojos} => 2}),
  {ok, Pid} = p44_banco_de_sangre_sup:start_link(),
  Pid.

detener(Pid) ->
  application:unset_env(?APP, umbral_default),
  application:unset_env(?APP, umbrales),
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

nueva(Id) ->
  {ok, _} = p44_unidades_sup:crear(#{id => Id, tipo => o_neg, componente => globulos_rojos,
                                     lote => 1, donante => 1000 + Id,
                                     caduca_en => ahora() + ?HORA}),
  ok.

esperar_existencias(N) -> esperar_existencias(N, 40).

esperar_existencias(N, 0) -> error({existencias_no_llegaron, N});
esperar_existencias(N, Intentos) ->
  case maps:get({o_neg, globulos_rojos}, p44_inventario:existencias(), 0) of
    N -> ok;
    _ -> timer:sleep(50), esperar_existencias(N, Intentos - 1)
  end.

avisa_por_transicion() ->
  ok = p44_alertas:suscribir(),
  [nueva(Id) || Id <- [301, 302, 303]],
  esperar_existencias(3),
  ?assertEqual([], p44_alertas:evaluar()),
  %% Baja a 1 (umbral 2): alerta crítica, una sola vez.
  {ok, _} = p44_inventario:solicitar(o_neg, globulos_rojos, a, ?HORA),
  {ok, _} = p44_inventario:solicitar(o_neg, globulos_rojos, b, ?HORA),
  esperar_existencias(1),
  ?assertMatch([{alerta_critica, #{tipo := o_neg, componente := globulos_rojos,
                                   existencias := 1, umbral := 2}}],
               p44_alertas:evaluar()),
  receive {alerta_critica, #{tipo := o_neg}} -> ok
  after 1000 -> error(el_suscriptor_no_recibio_el_aviso)
  end,
  ?assertEqual([], p44_alertas:evaluar()),
  ?assertMatch(#{{o_neg, globulos_rojos} := 1}, p44_alertas:criticos()),
  %% Llegan donaciones y se recupera.
  [nueva(Id) || Id <- [304, 305]],
  esperar_existencias(3),
  ?assertMatch([{alerta_resuelta, #{tipo := o_neg, existencias := 3}}], p44_alertas:evaluar()),
  ?assertEqual(#{}, p44_alertas:criticos()).
