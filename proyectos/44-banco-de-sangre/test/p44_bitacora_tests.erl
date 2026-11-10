-module(p44_bitacora_tests).
-include_lib("eunit/include/eunit.hrl").

-define(APP, p44_banco_de_sangre).

%% Usa un archivo temporal propio para no pisar el DETS real del proyecto.
persistencia_test_() ->
  {setup, fun preparar/0, fun limpiar/1,
   fun(_) ->
      [{"el historial sobrevive a reiniciar el proceso (y re-leer desde disco)",
        fun sobrevive_a_reiniciar_desde_disco/0},
       {"varios eventos con el mismo milisegundo conservan su orden y sus claves",
        fun marcas_iguales/0}]
   end}.

preparar() ->
  Ruta = "/tmp/p44_bitacora_test_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets",
  application:set_env(?APP, dets_path, Ruta),
  Ruta.

limpiar(Ruta) ->
  application:unset_env(?APP, dets_path),
  _ = file:delete(Ruta),
  ok.

sobrevive_a_reiniciar_desde_disco() ->
  esperar_libre(40),
  {ok, Pid1} = p44_bitacora:start_link(),
  ok = p44_bitacora:registrar(999, #{evento => creada, estado => disponible,
                                     datos => #{id => 999, tipo => a_pos}}),
  ok = p44_bitacora:registrar(999, #{evento => cambio, estado => reservada}),
  %% Simula que se cae TODO el nodo: tumbamos el proceso (que cierra el dets al
  %% terminar, por el trap_exit) y arrancamos uno nuevo. Si la persistencia
  %% funciona, el historial vuelve a estar completo sin que nadie lo haya
  %% vuelto a escribir. unlink/1 ANTES de matarlo: sin esto, la señal de salida
  %% se propaga al proceso que corre este test (mismo patron que los demas
  %% archivos de prueba de este proyecto).
  Ref = monitor(process, Pid1),
  unlink(Pid1),
  exit(Pid1, shutdown),
  receive {'DOWN', Ref, process, Pid1, _} -> ok after 2000 -> error(no_cerro) end,
  esperar_libre(40),
  {ok, _Pid2} = p44_bitacora:start_link(),
  Historial = p44_bitacora:historial(999),
  Estados = [maps:get(estado, E) || {_Ts, E} <- Historial],
  ?assertEqual([disponible, reservada], Estados).

marcas_iguales() ->
  ok = p44_bitacora:registrar_en(1001, 1000, #{evento => creada, estado => disponible,
                                               datos => #{id => 1001}}),
  ok = p44_bitacora:registrar_en(1001, 1000, #{evento => cambio, estado => reservada}),
  ok = p44_bitacora:registrar_en(1001, 1000, #{evento => cambio, estado => asignada}),
  ?assertEqual([disponible, reservada, asignada],
               [maps:get(estado, E) || {_, E} <- p44_bitacora:historial(1001)]),
  ?assertEqual(1, length([U || #{id := 1001} = U <- p44_bitacora:unidades()])).

esperar_libre(0) -> error(bitacora_anterior_sigue_viva);
esperar_libre(N) ->
  case whereis(p44_bitacora) of
    undefined -> ok;
    _ -> timer:sleep(50), esperar_libre(N - 1)
  end.
