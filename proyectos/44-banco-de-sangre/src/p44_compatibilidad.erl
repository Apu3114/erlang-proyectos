%% Reglas puras de compatibilidad (sin procesos): quién puede donarle a quién.
%% Tipos: o_neg, o_pos, a_neg, a_pos, b_neg, b_pos, ab_neg, ab_pos.
-module(p44_compatibilidad).

-export([tipos/0, componentes/0, compatible/3, donantes_en_orden/2]).

tipos() -> [o_neg, o_pos, a_neg, a_pos, b_neg, b_pos, ab_neg, ab_pos].
componentes() -> [globulos_rojos, plaquetas, plasma].

info(o_neg) -> {o, neg};
info(o_pos) -> {o, pos};
info(a_neg) -> {a, neg};
info(a_pos) -> {a, pos};
info(b_neg) -> {b, neg};
info(b_pos) -> {b, pos};
info(ab_neg) -> {ab, neg};
info(ab_pos) -> {ab, pos}.

%% Glóbulos rojos: ABO y Rh. El donante no debe llevar antígenos que el receptor no tenga.
compatible(globulos_rojos, Donante, Receptor) ->
  {AD, RD} = info(Donante),
  {AR, RR} = info(Receptor),
  abo_ok(AD, AR) andalso rh_ok(RD, RR);
%% Plasma (y, por simplificación, plaquetas): el ABO funciona al revés, porque lo que
%% importa son los anticuerpos del donante; el Rh se ignora. SUPUESTO a verificar.
compatible(Componente, Donante, Receptor)
  when Componente =:= plasma; Componente =:= plaquetas ->
  {AD, _} = info(Donante),
  {AR, _} = info(Receptor),
  abo_ok(AR, AD).

abo_ok(o, _) -> true;
abo_ok(X, X) -> true;
abo_ok(a, ab) -> true;
abo_ok(b, ab) -> true;
abo_ok(_, _) -> false.

rh_ok(neg, _) -> true;
rh_ok(pos, pos) -> true;
rh_ok(pos, neg) -> false.

%% Orden de preferencia para surtir a un receptor: primero su tipo exacto; después los
%% compatibles, empezando por los MENOS versátiles, para no gastar la sangre "universal"
%% (O negativo en glóbulos rojos) mientras haya otra opción.
donantes_en_orden(Componente, Receptor) ->
  Otros = [D || D <- tipos(), D =/= Receptor, compatible(Componente, D, Receptor)],
  Ordenados = lists:sort([{versatilidad(Componente, D), D} || D <- Otros]),
  [Receptor | [D || {_, D} <- Ordenados]].

%% A cuántos tipos de receptor puede servir este donante.
versatilidad(Componente, Donante) ->
  length([R || R <- tipos(), compatible(Componente, Donante, R)]).
