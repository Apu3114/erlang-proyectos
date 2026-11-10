%% Altas serializadas de donantes ficticios, lotes y unidades. La bitacora DETS
%% es la fuente persistente: al reiniciar se reconstruyen IDs y metadatos.
-module(p44_catalogo).
-behaviour(gen_server).

-export([start_link/0, donantes/0, lotes/0, registrar_donante/1,
         crear_lote/1, agregar_unidad/2]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
donantes() -> gen_server:call(?MODULE, donantes).
lotes() -> gen_server:call(?MODULE, lotes).
registrar_donante(Datos) -> gen_server:call(?MODULE, {registrar_donante, Datos}).
crear_lote(Datos) -> gen_server:call(?MODULE, {crear_lote, Datos}).
agregar_unidad(Lote, Donante) -> gen_server:call(?MODULE, {agregar_unidad, Lote, Donante}).

init([]) -> {ok, #{}}.

handle_call(donantes, _From, Estado) -> {reply, listar_donantes(), Estado};
handle_call(lotes, _From, Estado) -> {reply, listar_lotes(), Estado};
handle_call({registrar_donante, Datos}, _From, Estado) ->
  Ids = [maps:get(donante, U) || U <- p44_bitacora:unidades()] ++
        [Id || {Id, _} <- p44_bitacora:donantes()],
  Id = siguiente(Ids),
  Registro = Datos#{id => Id, registro_ms => erlang:system_time(millisecond)},
  ok = p44_bitacora:registrar({donante, Id}, #{evento => registrado, datos => Registro}),
  {reply, {ok, Registro}, Estado};
handle_call({crear_lote, Datos}, _From, Estado) ->
  Id = siguiente([N || {N, _} <- p44_bitacora:refrigeradores()]),
  case p44_refrigeradores_sup:crear(Id, Id) of
    {ok, _} ->
      Registro = Datos#{id => Id, registro_ms => erlang:system_time(millisecond)},
      ok = p44_bitacora:registrar({lote, Id}, #{evento => registrado, datos => Registro}),
      {reply, {ok, Registro}, Estado};
    {error, Razon} -> {reply, {error, Razon}, Estado}
  end;
handle_call({agregar_unidad, Lote, Donante}, _From, Estado) ->
  Resultado = agregar(Lote, Donante),
  {reply, Resultado, Estado}.

handle_cast(_, Estado) -> {noreply, Estado}.

siguiente([]) -> 1;
siguiente(Ids) -> lists:max(Ids) + 1.

listar_donantes() ->
  Inicial = maps:from_list([{Id, Datos#{unidades => []}}
                             || {Id, Datos} <- p44_bitacora:donantes()]),
  Grupos = lists:foldl(fun(U, Acc) ->
    #{id := Id, donante := D, tipo := Tipo, componente := Comp, lote := Lote} = U,
    Base = maps:get(D, Acc, #{id => D, tipo => Tipo,
                              alias => <<"Donante #", (integer_to_binary(D))/binary>>,
                              edad => null, peso_kg => null, registro_ms => null,
                              unidades => []}),
    Estado = estado_unidad(Id),
    Unidad = #{id => Id, componente => Comp, lote => Lote, estado => Estado},
    Acc#{D => Base#{unidades := [Unidad | maps:get(unidades, Base)]}}
  end, Inicial, p44_bitacora:unidades()),
  lists:sort(fun(A, B) -> maps:get(id, A) < maps:get(id, B) end,
    [D#{total => length(maps:get(unidades, D)),
        bloqueado => bloqueado(D),
        disponibles => length([U || U <- maps:get(unidades, D),
                                   maps:get(estado, U) =:= disponible])}
     || D <- maps:values(Grupos)]).

estado_unidad(Id) ->
  try {Estado, _} = p44_unidad:estado(Id), Estado
  catch exit:_ -> desconocido
  end.

bloqueado(#{id := Id, unidades := Unidades}) ->
  lists:any(fun(#{estado := E}) -> E =:= retirada end, Unidades) orelse
  lists:any(fun({_, Evento}) -> maps:get(evento, Evento, undefined) =:= bloqueado end,
            p44_bitacora:historial({donante, Id})).

listar_lotes() ->
  Metadatos = maps:from_list(p44_bitacora:lotes()),
  Unidades = p44_bitacora:unidades(),
  [begin
     DelLote = [U || U <- Unidades, maps:get(lote, U) =:= Id],
     Meta = maps:get(Id, Metadatos, #{}),
     Componente = case DelLote of
       [#{componente := C} | _] -> C;
       [] -> maps:get(componente, Meta, null)
     end,
     #{id => Id, nombre => maps:get(nombre, Meta,
                                     <<"Lote #", (integer_to_binary(Id))/binary>>),
       componente => Componente, estado => estado_refrigerador(Id),
       registro_ms => maps:get(registro_ms, Meta, null),
       total => length(DelLote),
       disponibles => length([U || #{id := UId} = U <- DelLote,
                                  estado_unidad(UId) =:= disponible])}
   end || {Id, _} <- lists:sort(p44_bitacora:refrigeradores())].

estado_refrigerador(Id) ->
  try p44_refrigerador:estado(Id)
  catch exit:_ -> desconocido
  end.

agregar(Lote, Donante) ->
  case {lists:keymember(Lote, 1, p44_bitacora:refrigeradores()),
        lists:keyfind(Donante, 1, [{maps:get(id, D), D} || D <- listar_donantes()])} of
    {false, _} -> {error, lote_no_encontrado};
    {_, false} -> {error, donante_no_encontrado};
    {true, {_, D}} -> agregar_de_donante(Lote, Donante, D)
  end.

agregar_de_donante(Lote, Donante, DonanteDatos) ->
  LoteDatos = lists:keyfind(Lote, 1, [{maps:get(id, L), L} || L <- listar_lotes()]),
  {_, #{componente := Comp, estado := Estado}} = LoteDatos,
  MismoDonante = lists:any(fun(#{donante := D, lote := L, componente := C}) ->
                              D =:= Donante andalso L =:= Lote andalso C =:= Comp
                          end, p44_bitacora:unidades()),
  case {Estado, Comp, MismoDonante, maps:get(bloqueado, DonanteDatos)} of
    {_, _, _, true} -> {error, donante_bloqueado};
    {fallado, _, _, _} -> {error, refrigerador_fallado};
    {_, null, _, _} -> {error, lote_sin_componente};
    {_, _, true, _} -> {error, donante_ya_en_lote};
    {operando, _, false, false} -> crear_unidad(Lote, Donante, maps:get(tipo, DonanteDatos), Comp);
    _ -> {error, refrigerador_no_disponible}
  end.

crear_unidad(Lote, Donante, Tipo, Componente) ->
  Id = siguiente([maps:get(id, U) || U <- p44_bitacora:unidades()]),
  Vida = case Componente of
    globulos_rojos -> 42;
    plaquetas -> 7;
    plasma -> 365
  end,
  Datos = #{id => Id, lote => Lote, donante => Donante, tipo => Tipo,
            componente => Componente,
            caduca_en => erlang:system_time(millisecond) + Vida * 86400000},
  case p44_unidades_sup:crear(Datos) of
    {ok, _} -> {ok, Datos};
    {error, Razon} -> {error, Razon}
  end.
