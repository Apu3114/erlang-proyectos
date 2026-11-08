-module(p44_caos_tests).
-include_lib("eunit/include/eunit.hrl").

caos_test_() ->
  {timeout, 180,
   {setup, fun arrancar/0, fun detener/1,
    fun(_) -> [{"matar procesos bajo carga", fun caos/0}] end}}.

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

%% El experimento destructivo de la bitácora no entra en eunit: se corre a mano.
caos() ->
  #{experimentos := Exps, invariantes := Inv} =
    p44_caos:correr(#{semilla => 11, incluir_bitacora => false}),
  [?assertMatch(#{ok := true}, E) || E <- Exps],
  ?assertEqual(ok, Inv).
