%% Índice de unidades disponibles y política de asignación.
%%
%% El índice es solo una PISTA: la autoridad sobre una unidad es la unidad misma.
%% Si el índice está desactualizado, la unidad rechaza la reserva y se prueba con la
%% siguiente; nunca se asigna algo inválido. Las unidades avisan sus cambios de estado
%% con un cast. Si este proceso se cae, se reconstruye preguntándole a las unidades.
-module(p44_inventario).
-behaviour(gen_server).

-export([start_link/0, solicitar/4, existencias/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2]).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Pide una unidad para un receptor de tipo Receptor.
%% {ok, #{id, tipo, exacto}} | {error, sin_existencias}
solicitar(Receptor, Componente, Solicitante, TtlMs) ->
  gen_server:call(?MODULE, {solicitar, Receptor, Componente, Solicitante, TtlMs}).

%% #{{Tipo, Componente} => unidades disponibles}
existencias() ->
  gen_server:call(?MODULE, existencias).

init([]) ->
  {ok, #{}, {continue, reconstruir}}.

handle_continue(reconstruir, _Indice) ->
  Hijos = supervisor:which_children(p44_unidades_sup),
  Indice = lists:foldl(fun leer_hijo/2, #{}, Hijos),
  {noreply, Indice}.

leer_hijo({_, Pid, _, _}, Indice) when is_pid(Pid) ->
  try gen_statem:call(Pid, estado) of
    {Estado, Datos} -> aplicar(Estado, Datos, Indice)
  catch
    exit:_ -> Indice
  end;
leer_hijo(_, Indice) ->
  Indice.

handle_call({solicitar, Receptor, Componente, Solicitante, TtlMs}, _From, Indice) ->
  Donantes = p44_compatibilidad:donantes_en_orden(Componente, Receptor),
  {Resultado, Indice1} = reservar_de(Donantes, Componente, Solicitante, TtlMs, Indice),
  Respuesta =
    case Resultado of
      {ok, Id, Donante} -> {ok, #{id => Id, tipo => Donante, exacto => Donante =:= Receptor}};
      sin_existencias -> {error, sin_existencias}
    end,
  {reply, Respuesta, Indice1};
handle_call(existencias, _From, Indice) ->
  {reply, maps:map(fun(_, Set) -> gb_sets:size(Set) end, Indice), Indice}.

handle_cast({estado_unidad, Estado, Datos}, Indice) ->
  {noreply, aplicar(Estado, Datos, Indice)}.

%% ---------- Auxiliares ----------

aplicar(Estado, #{id := Id, tipo := Tipo, componente := Comp, caduca_en := Caduca}, Indice) ->
  Clave = {Tipo, Comp},
  Elemento = {Caduca, Id},
  Set = maps:get(Clave, Indice, gb_sets:new()),
  Set1 =
    case Estado of
      disponible -> gb_sets:add_element(Elemento, Set);
      _ -> gb_sets:delete_any(Elemento, Set)
    end,
  Indice#{Clave => Set1}.

reservar_de([], _Comp, _Solicitante, _Ttl, Indice) ->
  {sin_existencias, Indice};
reservar_de([Donante | Resto], Comp, Solicitante, Ttl, Indice) ->
  case reservar_fefo({Donante, Comp}, Solicitante, Ttl, Indice) of
    {ok, Id, Indice1} -> {{ok, Id, Donante}, Indice1};
    {vacio, Indice1} -> reservar_de(Resto, Comp, Solicitante, Ttl, Indice1)
  end.

%% FEFO: primero la que caduca antes. Si la unidad rechaza, se descarta del índice y se sigue.
reservar_fefo(Clave, Solicitante, Ttl, Indice) ->
  Set = maps:get(Clave, Indice, gb_sets:new()),
  case gb_sets:is_empty(Set) of
    true ->
      {vacio, Indice};
    false ->
      {{_Caduca, Id}, Set1} = gb_sets:take_smallest(Set),
      Indice1 = Indice#{Clave => Set1},
      case intentar(Id, Solicitante, Ttl) of
        ok -> {ok, Id, Indice1};
        rechazada -> reservar_fefo(Clave, Solicitante, Ttl, Indice1)
      end
  end.

intentar(Id, Solicitante, Ttl) ->
  try p44_unidad:reservar(Id, Solicitante, Ttl) of
    {ok, _} -> ok;
    {error, _} -> rechazada
  catch
    exit:_ -> rechazada
  end.
