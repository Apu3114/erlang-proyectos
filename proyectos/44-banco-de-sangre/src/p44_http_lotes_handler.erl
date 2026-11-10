-module(p44_http_lotes_handler).
-export([init/2]).

init(Req0, State) ->
  {Codigo, Cuerpo, Req} = case {cowboy_req:method(Req0), cowboy_req:binding(id, Req0, undefined)} of
    {<<"GET">>, undefined} ->
      {N, R} = consultar(fun() -> {200, #{lotes => p44_catalogo:lotes()}} end),
      {N, R, Req0};
    {<<"GET">>, Bin} ->
      {N, R} = consultar(fun() -> detalle(Bin) end),
      {N, R, Req0};
    {<<"POST">>, undefined} -> crear(Req0);
    _ -> {405, #{error => metodo_no_permitido}, Req0}
  end,
  {ok, p44_http_unidades_handler:responder(Codigo, Cuerpo, Req), State}.

consultar(Fun) ->
  try Fun() catch exit:_ -> {503, #{error => servicio_no_disponible}} end.

detalle(Bin) ->
  case numero(Bin) of
    {ok, Id} ->
      case [L || #{id := LId} = L <- p44_catalogo:lotes(), LId =:= Id] of
        [L] -> {200, L};
        [] -> {404, #{error => lote_no_encontrado}}
      end;
    error -> {400, #{error => id_invalido}}
  end.

crear(Req0) ->
  {ok, Bin, Req} = cowboy_req:read_body(Req0),
  case p44_json:decode(Bin) of
    {ok, #{<<"nombre">> := Nombre, <<"componente">> := CompBin}}
      when is_binary(Nombre), byte_size(Nombre) > 0, byte_size(Nombre) =< 80 ->
      case [C || C <- p44_compatibilidad:componentes(),
                 atom_to_binary(C, utf8) =:= CompBin] of
        [Comp] ->
          {N, R} = consultar(fun() ->
            case p44_catalogo:crear_lote(#{nombre => Nombre, componente => Comp}) of
              {ok, Datos} -> {201, Datos};
              {error, _} -> {503, #{error => lote_no_creado}}
            end
          end),
          {N, R, Req};
        _ -> {400, #{error => componente_invalido}, Req}
      end;
    _ -> {400, #{error => nombre_y_componente_requeridos}, Req}
  end.

numero(Bin) when is_binary(Bin), byte_size(Bin) =< 9 ->
  try N = binary_to_integer(Bin),
      if N > 0 -> {ok, N}; true -> error end
  catch error:_ -> error end;
numero(_) -> error.
