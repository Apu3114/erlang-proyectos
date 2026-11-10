%% Retiro de todas las unidades de un donante con resultado tardio positivo.
-module(p44_http_donantes_handler).
-export([init/2]).

init(Req0, State) ->
  {Codigo, Cuerpo, Req1} = case cowboy_req:method(Req0) of
    <<"POST">> -> procesar(Req0);
    _ -> {405, #{error => metodo_no_permitido}, Req0}
  end,
  {ok, p44_http_unidades_handler:responder(Codigo, Cuerpo, Req1), State}.

procesar(Req0) ->
  {ok, Bin, Req} = cowboy_req:read_body(Req0),
  IdBin = cowboy_req:binding(id, Req),
  case {IdBin, p44_json:decode(Bin)} of
    {IdBin1, {ok, #{<<"motivo">> := Motivo}}}
      when is_binary(IdBin1), byte_size(IdBin1) =< 9, is_binary(Motivo),
           byte_size(Motivo) > 0, byte_size(Motivo) =< 200 ->
      try
        Id = binary_to_integer(IdBin1),
        case Id > 0 andalso lists:any(fun(#{donante := D}) -> D =:= Id end,
                                      p44_bitacora:unidades()) of
          true ->
            Resultado = p44_donantes:retirar(Id, Motivo),
            %% El dominio usa pares {IdUnidad, Receptor}; JSON requiere listas/mapas.
            Entregadas = [#{unidad => U, receptor => texto(R)}
                          || {U, R} <- maps:get(ya_entregadas, Resultado)],
            {200, #{ok => true, retiradas => maps:get(retiradas, Resultado),
                    ya_entregadas => Entregadas}, Req};
          false -> {404, #{error => donante_no_encontrado}, Req}
        end
      catch error:_ -> {400, #{error => id_invalido}, Req};
            exit:_ -> {503, #{error => servicio_no_disponible}, Req}
      end;
    _ -> {400, #{error => motivo_o_id_invalido}, Req}
  end.

texto(Bin) when is_binary(Bin) -> Bin;
texto(Term) -> iolist_to_binary(io_lib:format("~tp", [Term])).
