%% Un refrigerador vigila un lote. Si falla, compromete todas las unidades de ese lote.
%% Su estado (operando | fallado) se anota en la bitácora, así que si ESTE proceso se
%% cae después de la falla, al reiniciarse vuelve a aplicar el compromiso: la operación
%% es idempotente y cubre unidades que hayan llegado al lote mientras tanto.
-module(p44_refrigerador).
-behaviour(gen_server).

-export([start_link/2, nombre/1, fallar/1, estado/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2]).

start_link(Id, Lote) ->
  gen_server:start_link({local, nombre(Id)}, ?MODULE, {Id, Lote}, []).

nombre(Id) when is_integer(Id) ->
  list_to_atom("p44_refrigerador_" ++ integer_to_list(Id)).

%% {ok, #{comprometidas => N, ya_asignadas => [IdUnidad]}}
%% ya_asignadas: unidades del lote que ya se entregaron; requieren seguimiento clínico.
fallar(Id) -> gen_server:call(nombre(Id), fallar).

estado(Id) -> gen_server:call(nombre(Id), estado).

init({Id, Lote0}) ->
  Clave = {refrigerador, Id},
  case p44_bitacora:historial(Clave) of
    [] ->
      ok = p44_bitacora:registrar(Clave, #{evento => creada, estado => operando, lote => Lote0}),
      {ok, #{id => Id, lote => Lote0, estado => operando}};
    Historial ->
      [{_, #{lote := Lote}} | _] = Historial,
      {_, Ultimo} = lists:last(Historial),
      case maps:get(estado, Ultimo) of
        fallado -> {ok, #{id => Id, lote => Lote, estado => fallado}, {continue, reaplicar}};
        Otro -> {ok, #{id => Id, lote => Lote, estado => Otro}}
      end
  end.

handle_continue(reaplicar, Estado) ->
  _ = comprometer_lote(Estado),
  {noreply, Estado}.

handle_call(estado, _From, #{estado := E} = Estado) ->
  {reply, E, Estado};
handle_call(fallar, _From, #{estado := fallado} = Estado) ->
  {reply, {ok, comprometer_lote(Estado)}, Estado};
handle_call(fallar, _From, #{id := Id} = Estado) ->
  ok = p44_bitacora:registrar({refrigerador, Id}, #{evento => cambio, estado => fallado}),
  Estado1 = Estado#{estado := fallado},
  {reply, {ok, comprometer_lote(Estado1)}, Estado1}.

handle_cast(_Msg, Estado) ->
  {noreply, Estado}.

comprometer_lote(#{lote := Lote}) ->
  Pids = pg:get_members(p44_pg, {lote, Lote}),
  lists:foldl(fun afectar/2, #{comprometidas => 0, ya_asignadas => []}, Pids).

afectar(Pid, #{comprometidas := N, ya_asignadas := Asignadas} = Acc) ->
  try p44_unidad:comprometer(Pid) of
    ok ->
      Acc#{comprometidas := N + 1};
    {error, ya_asignada} ->
      {_, #{id := Id}} = p44_unidad:estado(Pid),
      Acc#{ya_asignadas := [Id | Asignadas]}
  catch
    exit:_ -> Acc
  end.
