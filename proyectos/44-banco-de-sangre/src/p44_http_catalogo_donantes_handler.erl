-module(p44_http_catalogo_donantes_handler).
-export([init/2]).

init(Req0, State) ->
  {Codigo, Cuerpo, Req} = case {cowboy_req:method(Req0), cowboy_req:binding(id, Req0, undefined)} of
    {<<"GET">>, undefined} ->
      {N, R} = consultar(fun() -> {200, #{donantes => p44_catalogo:donantes()}} end),
      {N, R, Req0};
    {<<"GET">>, IdBin} ->
      {N, R} = consultar(fun() -> detalle(IdBin) end),
      {N, R, Req0};
    {<<"POST">>, undefined} -> registrar(Req0);
    _ -> {405, #{error => metodo_no_permitido}, Req0}
  end,
  {ok, p44_http_unidades_handler:responder(Codigo, Cuerpo, Req), State}.

consultar(Fun) ->
  try Fun() catch exit:_ -> {503, #{error => servicio_no_disponible}} end.

detalle(Bin) ->
  case numero(Bin) of
    {ok, Id} ->
      case [D || #{id := DId} = D <- p44_catalogo:donantes(), DId =:= Id] of
        [D] -> {200, D};
        [] -> {404, #{error => donante_no_encontrado}}
      end;
    error -> {400, #{error => id_invalido}}
  end.

registrar(Req0) ->
  {ok, Bin, Req} = cowboy_req:read_body(Req0),
  case p44_json:decode(Bin) of
    {ok, #{<<"alias">> := Alias, <<"tipo">> := TipoBin} = M}
      when is_binary(Alias), byte_size(Alias) > 0, byte_size(Alias) =< 80 ->
      case {tipo(TipoBin), entero_opcional(maps:get(<<"edad">>, M, null), 18, 65),
            entero_opcional(maps:get(<<"peso_kg">>, M, null), 50, 250)} of
        {{ok, Tipo}, {ok, Edad}, {ok, Peso}} ->
          {N, R} = consultar(fun() ->
            {ok, Datos} = p44_catalogo:registrar_donante(
              #{alias => Alias, tipo => Tipo, edad => Edad, peso_kg => Peso}),
            {201, Datos}
          end),
          {N, R, Req};
        _ -> {400, #{error => tipo_edad_o_peso_invalido}, Req}
      end;
    _ -> {400, #{error => alias_y_tipo_requeridos}, Req}
  end.

tipo(Bin) when is_binary(Bin) ->
  case [T || T <- p44_compatibilidad:tipos(), atom_to_binary(T, utf8) =:= Bin] of
    [T] -> {ok, T};
    _ -> error
  end;
tipo(_) -> error.

entero_opcional(null, _, _) -> {ok, null};
entero_opcional(N, Min, Max) when is_integer(N), N >= Min, N =< Max -> {ok, N};
entero_opcional(_, _, _) -> error.

numero(Bin) when is_binary(Bin), byte_size(Bin) =< 9 ->
  try N = binary_to_integer(Bin),
      if N > 0 -> {ok, N}; true -> error end
  catch error:_ -> error end;
numero(_) -> error.
