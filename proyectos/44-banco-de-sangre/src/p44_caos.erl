%% Prueba de caos: se mata a propósito a procesos clave MIENTRAS el banco atiende
%% solicitudes, y para cada uno se compara lo que se esperaba con lo que ocurrió.
%% Al final se revisan las invariantes de TODOS los historiales.
%%
%% Desde `rebar3 shell`:  p44_simulador:reiniciar(), p44_caos:correr().
%% Con incluir_bitacora => true (por defecto) el último experimento destruye el
%% inventario a propósito; después hay que volver a llamar a p44_simulador:reiniciar().
-module(p44_caos).

-export([correr/0, correr/1, imprimir/1]).

-define(HORA_MS, 3600000).

correr() -> correr(#{}).

%% Opts: semilla, cargar (default true), incluir_bitacora (default true)
correr(Opts) ->
  case maps:get(cargar, Opts, true) of
    true -> ok = p44_simulador:cargar(p44_simulador:generar(maps:get(semilla, Opts, 42)));
    false -> ok
  end,
  Carga = iniciar_carga(),
  E1 = matar_unidad_reservada(),
  E2 = matar_refrigerador(),
  E3 = matar_alertas(),
  {E4, Conteos} = matar_inventario(Carga),
  E5 = matar_supervisor_de_unidades(),
  Invariantes = p44_simulador:invariantes(),
  Todos = case maps:get(incluir_bitacora, Opts, true) of
            true -> [E1, E2, E3, E4, E5, matar_bitacora()];
            false -> [E1, E2, E3, E4, E5]
          end,
  Reporte = #{experimentos => Todos, carga => Conteos, invariantes => Invariantes},
  case maps:get(imprimir, Opts, false) of
    true -> imprimir(Reporte);
    false -> ok
  end,
  Reporte.

%% ---------- Carga de fondo ----------

%% Un proceso que pide y entrega sangre sin parar (40 solicitudes por segundo).
iniciar_carga() ->
  spawn(fun() -> carga(1, #{surtidas => 0, sin_existencias => 0, interrumpidas => 0}) end).

carga(N, Cont) ->
  receive
    {parar, De} -> De ! {carga, Cont}
  after 25 ->
    Receptor = lists:nth(rand:uniform(8), p44_compatibilidad:tipos()),
    Comp = lists:nth(rand:uniform(3), p44_compatibilidad:componentes()),
    carga(N + 1, sumar(pedir(Receptor, Comp, N), Cont))
  end.

pedir(Receptor, Comp, N) ->
  Sol = {carga, N},
  try p44_inventario:solicitar(Receptor, Comp, Sol, 500) of
    {ok, #{id := Id}} ->
      try p44_unidad:asignar(Id, Sol, {paciente, N}) of
        ok -> surtidas;
        _ -> interrumpidas
      catch
        exit:_ -> interrumpidas
      end;
    {error, sin_existencias} ->
      sin_existencias
  catch
    exit:_ -> interrumpidas
  end.

sumar(Clave, Cont) -> maps:update_with(Clave, fun(X) -> X + 1 end, Cont).

detener_carga(Pid) ->
  Pid ! {parar, self()},
  receive {carga, Cont} -> Cont
  after 5000 -> sin_respuesta
  end.

%% ---------- Experimentos ----------

%% 1. Una unidad con una reserva viva muere: debe volver con su reserva intacta.
matar_unidad_reservada() ->
  Id = reservar_alguna(),
  Antes = whereis(p44_unidad:nombre(Id)),
  exit(Antes, kill),
  Resultado = esperar(fun() ->
                          case catch p44_unidad:estado(Id) of
                            {reservada, #{solicitante := caos}} -> ok;
                            _ -> reintentar
                          end
                      end),
  Despues = whereis(p44_unidad:nombre(Id)),
  _ = catch p44_unidad:liberar(Id),
  experimento("una unidad con reserva viva (bajo carga)",
              "se reinicia sola y conserva su reserva (mismo solicitante)",
              case Resultado of
                ok -> "volvio con su reserva; proceso nuevo";
                timeout -> "NO recupero su reserva"
              end,
              Resultado =:= ok andalso Antes =/= Despues).

reservar_alguna() ->
  Opciones = [{R, C} || C <- [plasma, globulos_rojos, plaquetas], R <- p44_compatibilidad:tipos()],
  reservar_primera(Opciones).

reservar_primera([{R, C} | Resto]) ->
  case p44_inventario:solicitar(R, C, caos, ?HORA_MS) of
    {ok, #{id := Id}} -> Id;
    {error, _} -> reservar_primera(Resto)
  end.

%% 2. Un refrigerador que ya falló muere: debe seguir fallado y su lote comprometido.
matar_refrigerador() ->
  {ok, _} = p44_refrigerador:fallar(2),
  Antes = whereis(p44_refrigerador:nombre(2)),
  exit(Antes, kill),
  Resultado = esperar(fun() ->
                          case catch p44_refrigerador:estado(2) of
                            fallado -> ok;
                            _ -> reintentar
                          end
                      end),
  timer:sleep(300),
  Inutilizables = [E || Pid <- pg:get_members(p44_pg, {lote, 2}), {E, _} <- [p44_unidad:estado(Pid)]],
  Todas = lists:all(fun(E) -> lists:member(E, [comprometida, asignada, retirada, caducada]) end,
                    Inutilizables),
  experimento("un refrigerador que ya habia fallado (bajo carga)",
              "al reiniciarse sigue fallado y ninguna unidad de su lote queda utilizable",
              io_lib:format("estado ~p; ~p unidades en el lote, todas inutilizables: ~p",
                            [Resultado, length(Inutilizables), Todas]),
              Resultado =:= ok andalso Todas).

%% 3. El proceso de alertas muere: debe volver y seguir funcionando.
matar_alertas() ->
  Antes = whereis(p44_alertas),
  exit(Antes, kill),
  Resultado = esperar(fun() ->
                          case whereis(p44_alertas) of
                            Pid when is_pid(Pid), Pid =/= Antes -> ok;
                            _ -> reintentar
                          end
                      end),
  Avisos = try p44_alertas:evaluar() catch exit:_ -> error end,
  experimento("el vigilante de alertas (bajo carga)",
              "se reinicia, evalua de nuevo y re-notifica los niveles criticos vigentes (mejor repetir que callar)",
              case Avisos of
                error -> "no respondio";
                _ -> io_lib:format("reinicio ~p; re-notifico ~p niveles", [Resultado, length(Avisos)])
              end,
              Resultado =:= ok andalso is_list(Avisos)).

%% 4. El inventario muere en plena carga: el índice debe reconstruirse y coincidir con
%% lo que de verdad tienen las unidades.
matar_inventario(Carga) ->
  exit(whereis(p44_inventario), kill),
  timer:sleep(300),
  Conteos = detener_carga(Carga),
  %% Esperamos a que las reservas en vuelo (plazo 500 ms) se resuelvan.
  timer:sleep(1000),
  Resultado = esperar(fun() ->
                          case catch (indice() =:= disponibles_reales()) of
                            true -> ok;
                            _ -> reintentar
                          end
                      end),
  {experimento("el inventario, en plena carga",
               "mientras esta caido las solicitudes fallan limpio; al volver reconstruye el indice y coincide con las unidades",
               io_lib:format("indice == unidades disponibles: ~p; durante la carga: ~p", [Resultado =:= ok, Conteos]),
               Resultado =:= ok),
   Conteos}.

indice() ->
  maps:filter(fun(_, N) -> N > 0 end, p44_inventario:existencias()).

disponibles_reales() ->
  lists:foldl(fun({disponible, #{tipo := T, componente := C}}, Acc) ->
                  maps:update_with({T, C}, fun(X) -> X + 1 end, 1, Acc);
                 (_, Acc) -> Acc
              end, #{}, [p44_unidad:estado(Pid)
                         || {_, Pid, _, _} <- supervisor:which_children(p44_unidades_sup), is_pid(Pid)]).

%% 5. El supervisor de unidades muere y arrastra a TODAS sus unidades: el repoblador
%% debe recrearlas desde la bitácora, cada una en el estado en que estaba.
matar_supervisor_de_unidades() ->
  Antes = p44_simulador:conteo_estados(),
  exit(whereis(p44_unidades_sup), kill),
  Resultado = esperar(fun() ->
                          case catch p44_simulador:conteo_estados() of
                            Antes -> ok;
                            _ -> reintentar
                          end
                      end),
  experimento("el supervisor de unidades (se llevan a las 300 unidades)",
              "el repoblador las recrea desde la bitacora, cada una en su estado anterior",
              io_lib:format("estados antes: ~p; recuperados iguales: ~p", [Antes, Resultado =:= ok]),
              Resultado =:= ok).

%% 6. La bitácora muere. HIPOTESIS DE DISEÑO: es el unico punto de falla; si cae, se
%% pierde la trazabilidad y no hay de donde repoblar. Este experimento lo comprueba.
matar_bitacora() ->
  Antes = length([x || {_, Pid, _, _} <- supervisor:which_children(p44_unidades_sup), is_pid(Pid)]),
  exit(whereis(p44_bitacora), kill),
  timer:sleep(1000),
  Despues = try length([x || {_, Pid, _, _} <- supervisor:which_children(p44_unidades_sup), is_pid(Pid)])
            catch exit:_ -> sin_supervisor
            end,
  experimento("la bitacora (EXPERIMENTO DESTRUCTIVO)",
              "HALLAZGO ESPERADO: es el punto unico de falla; al caer se pierde el inventario y la trazabilidad",
              io_lib:format("unidades vivas antes: ~p, despues: ~p", [Antes, Despues]),
              Despues =:= 0).

%% ---------- Auxiliares ----------

esperar(Fun) -> esperar(Fun, 60).

esperar(_Fun, 0) -> timeout;
esperar(Fun, N) ->
  case Fun() of
    ok -> ok;
    _ -> timer:sleep(50), esperar(Fun, N - 1)
  end.

experimento(Matado, Esperado, Ocurrido, Ok) ->
  #{matado => Matado, esperado => Esperado,
    ocurrido => lists:flatten(io_lib:format("~s", [Ocurrido])), ok => Ok}.

imprimir(#{experimentos := Exps, carga := Carga, invariantes := Inv}) ->
  io:format("~n=== PRUEBA DE CAOS ===~n"),
  lists:foldl(fun(#{matado := M, esperado := E, ocurrido := O, ok := Ok}, N) ->
                  io:format("~n~p. Mate: ~s~n   Esperaba: ~s~n   Ocurrio: ~s~n   Resultado: ~s~n",
                            [N, M, E, O, case Ok of true -> "COMO SE ESPERABA"; false -> "FALLO" end]),
                  N + 1
              end, 1, Exps),
  io:format("~nCarga de fondo durante los experimentos: ~p~n", [Carga]),
  io:format("Invariantes de todos los historiales: ~p~n~n", [Inv]),
  ok.
