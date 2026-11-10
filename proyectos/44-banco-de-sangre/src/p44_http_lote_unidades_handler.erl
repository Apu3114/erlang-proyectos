-module(p44_http_lote_unidades_handler).
-export([init/2]).

init(Req0, State) ->
  {Codigo, Cuerpo, Req} = case cowboy_req:method(Req0) of
    <<"POST">> -> agregar(Req0);
    _ -> {405, #{error => metodo_no_permitido}, Req0}
  end,
  {ok, p44_http_unidades_handler:responder(Codigo, Cuerpo, Req), State}.

agregar(Req0) ->
  {ok, Bin, Req} = cowboy_req:read_body(Req0),
  case {numero(cowboy_req:binding(id, Req)), p44_json:decode(Bin)} of
    {{ok, Lote}, {ok, #{<<"donante">> := Donante}}}
      when is_integer(Donante), Donante > 0, Donante =< 999999999 ->
      Res = try p44_catalogo:agregar_unidad(Lote, Donante)
            catch exit:_ -> {error, servicio_no_disponible}
            end,
      case Res of
        {ok, Datos} -> {201, Datos, Req};
        {error, R} when is_atom(R) -> {409, #{error => R}, Req};
        _ -> {503, #{error => servicio_no_disponible}, Req}
      end;
    _ -> {400, #{error => lote_o_donante_invalido}, Req}
  end.

numero(Bin) when is_binary(Bin), byte_size(Bin) =< 9 ->
  try N = binary_to_integer(Bin),
      if N > 0 -> {ok, N}; true -> error end
  catch error:_ -> error end;
numero(_) -> error.
