-module(p44_compatibilidad_tests).
-include_lib("eunit/include/eunit.hrl").

rojos_o_neg_dona_a_todos_test() ->
  [?assert(p44_compatibilidad:compatible(globulos_rojos, o_neg, R))
   || R <- p44_compatibilidad:tipos()].

rojos_ab_pos_recibe_de_todos_test() ->
  [?assert(p44_compatibilidad:compatible(globulos_rojos, D, ab_pos))
   || D <- p44_compatibilidad:tipos()].

rojos_rh_positivo_no_dona_a_negativo_test() ->
  ?assertNot(p44_compatibilidad:compatible(globulos_rojos, a_pos, a_neg)),
  ?assertNot(p44_compatibilidad:compatible(globulos_rojos, a_pos, o_pos)),
  ?assert(p44_compatibilidad:compatible(globulos_rojos, a_neg, a_pos)).

plasma_funciona_al_reves_test() ->
  %% El plasma AB lo recibe cualquiera; el plasma O solo lo reciben receptores O.
  [?assert(p44_compatibilidad:compatible(plasma, ab_pos, R)) || R <- p44_compatibilidad:tipos()],
  ?assert(p44_compatibilidad:compatible(plasma, o_neg, o_pos)),
  ?assertNot(p44_compatibilidad:compatible(plasma, o_neg, a_pos)).

orden_primero_el_exacto_test() ->
  [?assertEqual(R, hd(p44_compatibilidad:donantes_en_orden(globulos_rojos, R)))
   || R <- p44_compatibilidad:tipos()].

orden_guarda_o_negativo_para_el_final_test() ->
  Orden = p44_compatibilidad:donantes_en_orden(globulos_rojos, ab_pos),
  ?assertEqual(ab_pos, hd(Orden)),
  ?assertEqual(o_neg, lists:last(Orden)),
  ?assertEqual(8, length(Orden)).

orden_sin_duplicados_test() ->
  Orden = p44_compatibilidad:donantes_en_orden(globulos_rojos, a_pos),
  ?assertEqual(length(Orden), length(lists:usort(Orden))).
