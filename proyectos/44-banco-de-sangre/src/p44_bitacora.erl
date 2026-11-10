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

-export([start_link/0, registrar/2, registrar_en/3, historial/1, unidades/0, refrigeradores/0,
         donantes/0, lotes/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-define(ETS, p44_bitacora).
-define(DETS, p44_bitacora_dets).
-define(APP, p44_banco_de_sangre).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Agrega un evento al historial de la unidad Id. Escribe directo en ETS y en DETS,
%% sin pasar por el proceso: así nunca es un cuello de botella.
registrar(Id, Evento) when is_map(Evento) ->
  registrar_en(Id, erlang:system_time(millisecond), Evento).

%% El unique_integer de la VM vuelve a empezar tras un reinicio y sobrescribia
%% eventos antiguos con la misma clave DETS (incluidas algunas altas). Una marca
%% de tiempo de nanosegundos y un sufijo aleatorio evitan esa colision.
registrar_en(Id, FechaMs, Evento) when is_integer(FechaMs), is_map(Evento) ->
  Clave = {Id, {erlang:system_time(nanosecond), crypto:strong_rand_bytes(8)}},
  Registro = {Clave, FechaMs, Evento},
  true = ets:insert(?ETS, Registro),
  ok = dets:insert(?DETS, Registro),
  ok.

%% Devuelve [{MarcaDeTiempoMs, Evento}] en orden cronológico.
historial(Id) ->
  Registros = ets:select(?ETS, [{{{Id, '$1'}, '$2', '$3'}, [], [{{'$1', '$2', '$3'}}]}]),
  Ordenados = lists:sort(fun({K1, T1, _}, {K2, T2, _}) -> {T1, K1} =< {T2, K2} end,
                         Registros),
  [{Fecha, Evento} || {_, Fecha, Evento} <- Ordenados].

%% Datos de todas las unidades que alguna vez se crearon (para repoblar tras una caída).
unidades() ->
  ets:select(?ETS, [{{{'$1', '_'}, '_', #{evento => creada, datos => '$2'}},
                     [{is_integer, '$1'}], ['$2']}]).

%% [{IdRefrigerador, Lote}] de todos los refrigeradores creados.
refrigeradores() ->
  ets:select(?ETS, [{{{{refrigerador, '$1'}, '_'}, '_', #{evento => creada, lote => '$2'}},
                      [], [{{'$1', '$2'}}]}]).

%% Metadatos nuevos. Los donantes/lotes de la simulación original se infieren
%% desde las unidades y los refrigeradores; no se inventan datos personales.
donantes() ->
  ets:select(?ETS, [{{{{donante, '$1'}, '_'}, '_', #{evento => registrado, datos => '$2'}},
                      [], [{{'$1', '$2'}}]}]).

lotes() ->
  ets:select(?ETS, [{{{{lote, '$1'}, '_'}, '_', #{evento => registrado, datos => '$2'}},
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
