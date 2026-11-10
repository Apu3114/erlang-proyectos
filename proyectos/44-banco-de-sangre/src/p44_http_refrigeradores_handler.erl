%% Inyección educativa de falla de un refrigerador/lote.
-module(p44_http_refrigeradores_handler).
-export([init/2]).

init(Req0, State) ->
  {Codigo, Cuerpo} = case {cowboy_req:method(Req0), cowboy_req:binding(id, Req0)} of
    {<<"POST">>, Bin} -> fallar(Bin);
    _ -> {405, #{error => metodo_no_permitido}}
  end,
  {ok, p44_http_unidades_handler:responder(Codigo, Cuerpo, Req0), State}.

fallar(Bin) when is_binary(Bin), byte_size(Bin) =< 9 ->
  try
    Id = binary_to_integer(Bin),
    case lists:keymember(Id, 1, p44_bitacora:refrigeradores()) of
      false -> {404, #{error => refrigerador_no_encontrado}};
      true ->
        {ok, Resultado} = p44_refrigerador:fallar(Id),
        {200, Resultado#{ok => true, refrigerador => Id}}
    end
  catch error:_ -> {400, #{error => id_invalido}};
        exit:_ -> {503, #{error => servicio_no_disponible}}
  end;
fallar(_) -> {400, #{error => id_invalido}}.
