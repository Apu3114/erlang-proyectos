%% Los supervisores dinámicos (unidades, refrigeradores) pierden a sus hijos si ELLOS
%% se caen. Este proceso arranca después de ambos y los vuelve a crear desde la bitácora:
%% cada unidad, al nacer, recupera su estado desde el historial. Si todo está en pie
%% (arranque limpio, o ya existen) no hace nada. Si se cae la bitácora no hay de dónde
%% recuperar: es el punto único de falla conocido (ver README).
-module(p44_repoblador).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2]).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  {ok, #{}, {continue, repoblar}}.

%% Primero las unidades y después los refrigeradores: un refrigerador que quedó
%% "fallado" re-aplica el compromiso al nacer, y necesita ver a sus unidades.
handle_continue(repoblar, Estado) ->
  lists:foreach(fun(Datos) -> tolerar(p44_unidades_sup:crear(Datos)) end,
                p44_bitacora:unidades()),
  lists:foreach(fun({Id, Lote}) -> tolerar(p44_refrigeradores_sup:crear(Id, Lote)) end,
                p44_bitacora:refrigeradores()),
  {noreply, Estado}.

handle_call(_Pedido, _From, Estado) ->
  {reply, {error, no_soportado}, Estado}.

handle_cast(_Msg, Estado) ->
  {noreply, Estado}.

tolerar({ok, _}) -> ok;
tolerar({error, {already_started, _}}) -> ok;
tolerar({error, _}) -> ok.
