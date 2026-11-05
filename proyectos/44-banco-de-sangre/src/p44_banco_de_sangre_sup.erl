-module(p44_banco_de_sangre_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% rest_for_one: el orden de arranque importa. La bitácora va primero porque las
%% unidades la necesitan para recuperarse; si ella cae, se reinicia todo lo que
%% viene después. Los hijos del dominio (inventario, refrigeradores, alertas, http)
%% se agregan debajo, en este mismo orden de dependencia.
init([]) ->
  Children = [
    #{id => p44_bitacora,
      start => {p44_bitacora, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type => worker},
    #{id => p44_unidades_sup,
      start => {p44_unidades_sup, start_link, []},
      restart => permanent,
      shutdown => infinity,
      type => supervisor},
    #{id => p44_banco_de_sangre_server,
      start => {p44_banco_de_sangre_server, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type => worker}
  ],
  {ok, {#{strategy => rest_for_one, intensity => 10, period => 60}, Children}}.
