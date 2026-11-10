%% Una unidad de sangre = un proceso. Es la única dueña de su estado, así que
%% solo ella puede decir "sí" a una reserva: de ahí salen la garantía de no
%% asignar dos veces y la de no asignar nunca una unidad vencida.
%%
%% Estados: disponible | reservada | asignada | caducada | retirada | comprometida
-module(p44_unidad).
-behaviour(gen_statem).

-export([start_link/1, nombre/1]).
-export([reservar/3, asignar/3, liberar/1, retirar/2, comprometer/1, estado/1]).
-export([init/1, callback_mode/0, handle_event/4]).

%% Los temporizadores de Erlang no aceptan plazos de más de ~49 días y el plasma
%% dura un año: revisamos la caducidad como máximo cada día, re-armando el aviso.
-define(REVISION_MAX_MS, 86400000).

%% ---------- API ----------

%% Datos: #{id, tipo, componente, lote, donante, caduca_en (ms, tiempo del sistema)}
start_link(#{id := Id} = Datos) ->
  gen_statem:start_link({local, nombre(Id)}, ?MODULE, Datos, []).

%% Id entero generado por el sistema (acotado), por eso es seguro hacer un átomo.
nombre(Id) when is_integer(Id) ->
  list_to_atom("p44_unidad_" ++ integer_to_list(Id)).

reservar(Id, Solicitante, TtlMs) -> llamar(Id, {reservar, Solicitante, TtlMs}).
asignar(Id, Solicitante, Receptor) -> llamar(Id, {asignar, Solicitante, Receptor}).
liberar(Id) -> llamar(Id, liberar).
retirar(Id, Motivo) -> llamar(Id, {retirar, Motivo}).
comprometer(Id) -> llamar(Id, comprometer).
estado(Id) -> llamar(Id, estado).

%% Se puede llamar por Id o directamente por pid.
llamar(Pid, Pedido) when is_pid(Pid) ->
  gen_statem:call(Pid, Pedido);
llamar(Id, Pedido) ->
  gen_statem:call(nombre(Id), Pedido).

%% ---------- Arranque y recuperación ----------

callback_mode() -> handle_event_function.

init(#{id := Id} = Datos0) ->
  {Estado, Datos} =
    case restaurar(Id, Datos0) of
      sin_historial ->
        ok = p44_bitacora:registrar(Id, #{evento => creada, estado => disponible, datos => Datos0}),
        {disponible, Datos0};
      {E, D} ->
        {E, D}
    end,
  %% Grupo por lote: así un refrigerador encuentra a las unidades de su lote sin
  %% recorrer todas. pg quita solo a los procesos que mueren; al reiniciarse se re-une.
  ok = pg:join(p44_pg, {lote, maps:get(lote, Datos, sin_lote)}, self()),
  ok = pg:join(p44_pg, {donante, maps:get(donante, Datos, sin_donante)}, self()),
  notificar(Estado, Datos),
  {ok, Estado, Datos, acciones_iniciales(Estado, Datos)}.

%% Reconstruye estado y datos desde la bitácora (primer evento = datos base,
%% último evento = estado actual y sus extras).
restaurar(Id, Datos0) ->
  case p44_bitacora:historial(Id) of
    [] ->
      sin_historial;
    Historial ->
       %% La base no depende del orden en que ETS devolvio los eventos.
       Base = case [D || {_, #{evento := creada, datos := D}} <- Historial] of
         [D | _] -> D;
         [] -> Datos0
       end,
      {_, Ultimo} = lists:last(Historial),
      Extra = maps:with([solicitante, reserva_hasta, receptor], Ultimo),
      {maps:get(estado, Ultimo), maps:merge(Base, Extra)}
  end.

acciones_iniciales(disponible, Datos) ->
  [temporizador_caducidad(Datos)];
acciones_iniciales(reservada, #{reserva_hasta := Hasta} = Datos) ->
  [temporizador_caducidad(Datos), {state_timeout, max(0, Hasta - ahora()), vencio_reserva}];
acciones_iniciales(_, _) ->
  [].

%% ---------- Eventos ----------

handle_event({call, From}, estado, Estado, Datos) ->
  {keep_state_and_data, [{reply, From, {Estado, Datos}}]};

%% Aviso de caducidad: si ya venció pasa a caducada; si no, re-arma el aviso.
handle_event({timeout, caducidad}, revisar, Estado, Datos)
  when Estado =:= disponible; Estado =:= reservada ->
  case vencida(Datos) of
    true -> pasar(caducada, Datos, #{motivo => temporizador}, []);
    false -> {keep_state_and_data, [temporizador_caducidad(Datos)]}
  end;

%% Reservar: solo desde disponible, y verificando el reloj en este instante.
handle_event({call, From}, {reservar, Solicitante, TtlMs}, disponible, Datos) ->
  case vencida(Datos) of
    true ->
      pasar(caducada, Datos, #{motivo => verificada_al_reservar},
            [{reply, From, {error, caducada}}]);
    false ->
      Hasta = ahora() + TtlMs,
      pasar(reservada, Datos, #{solicitante => Solicitante, reserva_hasta => Hasta},
            [{state_timeout, TtlMs, vencio_reserva},
             {reply, From, {ok, maps:get(id, Datos)}}])
  end;
handle_event({call, From}, {reservar, _, _}, Estado, _Datos) ->
  {keep_state_and_data, [{reply, From, {error, {no_disponible, Estado}}}]};

%% Asignar: solo quien reservó, y solo si la unidad sigue vigente.
handle_event({call, From}, {asignar, Solicitante, Receptor}, reservada,
             #{solicitante := Solicitante} = Datos) ->
  case vencida(Datos) of
    true -> pasar(caducada, Datos, #{motivo => verificada_al_asignar},
                  [{reply, From, {error, caducada}}]);
    false -> pasar(asignada, Datos, #{receptor => Receptor}, [{reply, From, ok}])
  end;
handle_event({call, From}, {asignar, _, _}, reservada, _Datos) ->
  {keep_state_and_data, [{reply, From, {error, no_es_tu_reserva}}]};
handle_event({call, From}, {asignar, _, _}, Estado, _Datos) ->
  {keep_state_and_data, [{reply, From, {error, {no_reservada, Estado}}}]};

%% Liberar una reserva (a mano o porque se acabó su plazo).
handle_event({call, From}, liberar, reservada, Datos) ->
  volver_a_disponible(Datos, #{motivo => liberada}, [{reply, From, ok}]);
handle_event({call, From}, liberar, Estado, _Datos) ->
  {keep_state_and_data, [{reply, From, {error, {no_reservada, Estado}}}]};
handle_event(state_timeout, vencio_reserva, reservada, Datos) ->
  volver_a_disponible(Datos, #{motivo => reserva_no_usada}, []);

%% Retiro (donante positivo tardío) y falla de refrigeración.
handle_event({call, From}, {retirar, Motivo}, Estado, Datos) ->
  descartar(retirada, #{motivo => Motivo}, Estado, From, Datos);
handle_event({call, From}, comprometer, Estado, Datos) ->
  descartar(comprometida, #{motivo => falla_refrigeracion}, Estado, From, Datos);

handle_event(_Tipo, _Mensaje, _Estado, _Datos) ->
  keep_state_and_data.

%% ---------- Auxiliares ----------

descartar(_Nuevo, _Extra, asignada, From, _Datos) ->
  {keep_state_and_data, [{reply, From, {error, ya_asignada}}]};
descartar(Nuevo, _Extra, Nuevo, From, _Datos) ->
  {keep_state_and_data, [{reply, From, ok}]};
descartar(_Nuevo, _Extra, Estado, From, _Datos)
  when Estado =:= caducada; Estado =:= retirada ->
  {keep_state_and_data, [{reply, From, ok}]};
descartar(Nuevo, Extra, _Estado, From, Datos) ->
  pasar(Nuevo, Datos, Extra, [{reply, From, ok}]).

%% Una reserva que termina devuelve la unidad al inventario... salvo que ya venció.
volver_a_disponible(Datos, Extra, Acciones) ->
  case vencida(Datos) of
    true -> pasar(caducada, Datos, #{motivo => vencio_durante_reserva}, Acciones);
    false -> pasar(disponible, Datos, Extra, Acciones)
  end.

%% Toda transición pasa por aquí: se anota en la bitácora ANTES de cambiar de estado.
pasar(Nuevo, Datos, Extra, Acciones) ->
  ok = p44_bitacora:registrar(maps:get(id, Datos),
                              maps:merge(#{evento => cambio, estado => Nuevo}, Extra)),
  Campos = [solicitante, reserva_hasta, receptor],
  Datos1 = maps:merge(maps:without(Campos, Datos), maps:with(Campos, Extra)),
  notificar(Nuevo, Datos1),
  {next_state, Nuevo, Datos1, Acciones ++ cierre(Nuevo)}.

%% Avisa al inventario (cast: nunca bloquea, y si el inventario no existe se ignora).
notificar(Estado, Datos) ->
  gen_server:cast(p44_inventario, {estado_unidad, Estado, Datos}).

%% En estados finales ya no hace falta vigilar la caducidad.
cierre(Estado) when Estado =:= disponible; Estado =:= reservada -> [];
cierre(_) -> [{{timeout, caducidad}, cancel}].

temporizador_caducidad(#{caduca_en := CaducaEn}) ->
  Resta = max(0, CaducaEn - ahora()),
  {{timeout, caducidad}, min(Resta, ?REVISION_MAX_MS), revisar}.

vencida(#{caduca_en := CaducaEn}) -> ahora() >= CaducaEn.

ahora() -> erlang:system_time(millisecond).
