%% Bitácora de trazabilidad: guarda cada cambio de estado de cada unidad.
%% La tabla ETS es pública (las unidades escriben directo, sin cuello de botella)
%% pero su dueño es este proceso, que casi no hace nada y por eso casi no falla:
%% si una unidad se cae, su historial sobrevive aquí.
-module(p44_bitacora).
-behaviour(gen_server).

-export([start_link/0, registrar/2, historial/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(TABLA, p44_bitacora).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Agrega un evento al historial de la unidad Id.
registrar(Id, Evento) when is_map(Evento) ->
  Clave = {Id, erlang:unique_integer([monotonic])},
  true = ets:insert(?TABLA, {Clave, erlang:system_time(millisecond), Evento}),
  ok.

%% Devuelve [{MarcaDeTiempoMs, Evento}] en orden cronológico.
historial(Id) ->
  ets:select(?TABLA, [{{{Id, '_'}, '$1', '$2'}, [], [{{'$1', '$2'}}]}]).

init([]) ->
  ?TABLA = ets:new(?TABLA, [named_table, public, ordered_set, {write_concurrency, true}]),
  {ok, #{}}.

handle_call(_Pedido, _From, Estado) ->
  {reply, {error, no_soportado}, Estado}.

handle_cast(_Msg, Estado) ->
  {noreply, Estado}.
