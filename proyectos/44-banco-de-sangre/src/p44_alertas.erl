%% Vigila los niveles por tipo y componente. Avisa por TRANSICIÓN (no en cada revisión):
%% {alerta_critica, Info} cuando un nivel baja del umbral y {alerta_resuelta, Info}
%% cuando se recupera. Cualquier proceso puede suscribirse con suscribir/0.
%%
%% Configuración (application env de p44_banco_de_sangre):
%%   umbral_default :: integer()                 (default 5)
%%   umbrales       :: #{{Tipo, Comp} => integer()}
%%   intervalo_ms   :: integer()                 (default 5000)
-module(p44_alertas).
-behaviour(gen_server).

-export([start_link/0, suscribir/0, evaluar/0, criticos/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(APP, p44_banco_de_sangre).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% El proceso que llama recibirá los avisos como mensajes.
suscribir() -> pg:join(p44_pg, alertas, self()).

%% Revisa ahora mismo; devuelve los avisos nuevos.
evaluar() -> gen_server:call(?MODULE, evaluar).

%% #{{Tipo, Comp} => existencias} de lo que está bajo el umbral.
criticos() -> gen_server:call(?MODULE, criticos).

init([]) ->
  {ok, programar(#{criticos => #{}})}.

handle_call(evaluar, _From, Estado) ->
  {Avisos, Estado1} = revisar(Estado),
  {reply, Avisos, Estado1};
handle_call(criticos, _From, #{criticos := Criticos} = Estado) ->
  {reply, Criticos, Estado}.

handle_cast(_Msg, Estado) ->
  {noreply, Estado}.

handle_info(revisar, Estado) ->
  {_Avisos, Estado1} = revisar(Estado),
  {noreply, programar(Estado1)};
handle_info(_Otro, Estado) ->
  {noreply, Estado}.

programar(Estado) ->
  erlang:send_after(application:get_env(?APP, intervalo_ms, 5000), self(), revisar),
  Estado.

revisar(#{criticos := Previos} = Estado) ->
  try p44_inventario:existencias() of
    Existencias ->
      Actuales = maps:from_list(
                   [{Clave, N}
                    || T <- p44_compatibilidad:tipos(),
                       C <- p44_compatibilidad:componentes(),
                       Clave <- [{T, C}],
                       N <- [maps:get(Clave, Existencias, 0)],
                       N < umbral(Clave)]),
      Nuevos = [aviso(alerta_critica, K, N) || {K, N} <- maps:to_list(Actuales),
                                                not maps:is_key(K, Previos)],
      Resueltos = [aviso(alerta_resuelta, K, maps:get(K, Existencias, 0))
                   || K <- maps:keys(Previos), not maps:is_key(K, Actuales)],
      Avisos = Nuevos ++ Resueltos,
      lists:foreach(fun emitir/1, Avisos),
      {Avisos, Estado#{criticos := Actuales}}
  catch
    exit:_ -> {[], Estado}
  end.

aviso(Tipo, {T, C} = Clave, N) ->
  {Tipo, #{tipo => T, componente => C, existencias => N, umbral => umbral(Clave)}}.

emitir({Nombre, Info} = Aviso) ->
  logger:warning("~p ~p", [Nombre, Info]),
  lists:foreach(fun(Pid) -> Pid ! Aviso end, pg:get_members(p44_pg, alertas)).

umbral(Clave) ->
  Mapa = application:get_env(?APP, umbrales, #{}),
  maps:get(Clave, Mapa, application:get_env(?APP, umbral_default, 5)).
