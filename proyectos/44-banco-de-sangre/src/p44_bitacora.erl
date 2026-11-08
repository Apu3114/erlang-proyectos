%% Bitácora de trazabilidad: guarda cada cambio de estado de cada unidad.
%%
%% Vive en DOS lugares a la vez:
%%  - una tabla ETS pública (lecturas e inserciones rápidas, sin pasar por este proceso)
%%  - una tabla DETS en disco (sobrevive a que se caiga la BEAM completa, no solo el proceso)
%%
%% Al arrancar, si el archivo DETS ya existe, su contenido se vuelca a la ETS: así el
%% historial sobrevive a un reinicio del nodo, no solo a que kill a un proceso.
%% Esto resuelve el hallazgo de la prueba de caos (ver p44_caos, experimento 6): antes,
%% la bitácora vivía solo en memoria y era el punto único de falla del sistema.
%%
%% Ruta configurable con `p44_banco_de_sangre, dets_path` (default: priv/p44_bitacora.dets,
%% relativo al directorio desde donde se arrancó la VM/el nodo).
-module(p44_bitacora).
-behaviour(gen_server).

-export([start_link/0, registrar/2, historial/1, unidades/0, refrigeradores/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-define(ETS, p44_bitacora).
-define(DETS, p44_bitacora_dets).
-define(APP, p44_banco_de_sangre).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Agrega un evento al historial de la unidad Id. Escribe directo en ETS y en DETS,
%% sin pasar por el proceso: así nunca es un cuello de botella.
registrar(Id, Evento) when is_map(Evento) ->
  Clave = {Id, erlang:unique_integer([monotonic])},
  Registro = {Clave, erlang:system_time(millisecond), Evento},
  true = ets:insert(?ETS, Registro),
  ok = dets:insert(?DETS, Registro),
  ok.

%% Devuelve [{MarcaDeTiempoMs, Evento}] en orden cronológico.
historial(Id) ->
  ets:select(?ETS, [{{{Id, '_'}, '$1', '$2'}, [], [{{'$1', '$2'}}]}]).

%% Datos de todas las unidades que alguna vez se crearon (para repoblar tras una caída).
unidades() ->
  ets:select(?ETS, [{{{'$1', '_'}, '_', #{evento => creada, datos => '$2'}},
                     [{is_integer, '$1'}], ['$2']}]).

%% [{IdRefrigerador, Lote}] de todos los refrigeradores creados.
refrigeradores() ->
  ets:select(?ETS, [{{{{refrigerador, '$1'}, '_'}, '_', #{evento => creada, lote => '$2'}},
                     [], [{{'$1', '$2'}}]}]).

init([]) ->
  %% Sin esto, un apagado normal del supervisor mata el proceso sin pasar por
  %% terminate/2, y el dets no se cerraria limpio (ver dets:close/1 en terminate).
  process_flag(trap_exit, true),
  ?ETS = ets:new(?ETS, [named_table, public, ordered_set, {write_concurrency, true}]),
  Ruta = ruta_dets(),
  ok = filelib:ensure_dir(Ruta),
  {ok, ?DETS} = dets:open_file(?DETS, [{file, Ruta}, {type, set}]),
  %% Vuelca lo que ya había en disco (de una corrida anterior del nodo) a la ETS.
  %% dets:to_ets/2 devuelve el identificador de la tabla ETS (no el átomo `ok`).
  ?ETS = dets:to_ets(?DETS, ?ETS),
  {ok, #{}}.

ruta_dets() ->
  application:get_env(?APP, dets_path, "priv/p44_bitacora.dets").

handle_call(_Pedido, _From, Estado) ->
  {reply, {error, no_soportado}, Estado}.

handle_cast(_Msg, Estado) ->
  {noreply, Estado}.

terminate(_Razon, _Estado) ->
  _ = dets:sync(?DETS),
  _ = dets:close(?DETS),
  ok.
