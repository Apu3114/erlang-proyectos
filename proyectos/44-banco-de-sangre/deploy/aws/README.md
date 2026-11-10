# Demo pública en AWS Academy (EC2 Ubuntu)

En esta VM el repositorio vive en `/home/ubuntu/erlang-proyectos`. El release
ejecuta la API Cowboy **solo en 127.0.0.1:8080**; nginx expone en el puerto 80
la app adaptable a móvil y reenvía la API y SSE bajo el mismo origen.

```bash
cd /home/ubuntu/erlang-proyectos/proyectos/44-banco-de-sangre
. /home/ubuntu/otp/26.2.5/activate
rebar3 compile && rebar3 eunit && rebar3 as prod release
sudo apt-get update && sudo apt-get install -y nginx
sudo mkdir -p /var/www/p44-banco-de-sangre
sudo cp -r design/app /var/www/p44-banco-de-sangre/
sudo cp deploy/aws/p44-banco-de-sangre.service /etc/systemd/system/
sudo cp deploy/aws/p44-banco-de-sangre.nginx /etc/nginx/sites-available/p44-banco-de-sangre
sudo ln -s /etc/nginx/sites-available/p44-banco-de-sangre /etc/nginx/sites-enabled/p44-banco-de-sangre
sudo rm /etc/nginx/sites-enabled/default
sudo systemctl daemon-reload
sudo systemctl enable --now p44-banco-de-sangre
sudo nginx -t && sudo systemctl enable --now nginx
```

Si se modifica la app, volver a copiar `design/app/index.html` a
`/var/www/p44-banco-de-sangre/app/index.html`.

Si el banco arranca vacío, cargar las 300 unidades **una sola vez** (no usar
`reiniciar/0` en un servicio con datos persistidos):

```bash
ERL_RPC=relx_nodetool _build/prod/rel/p44_banco_de_sangre/bin/p44_banco_de_sangre eval 'p44_simulador:cargar(p44_simulador:generar(42)).'
```

En esta VM `erl_call` no logra contactar al nodo con nombre `@127.0.0.1`;
`ERL_RPC=relx_nodetool` fuerza el mecanismo alternativo de relx para `ping`,
`rpc` y `eval`.

Para permitir acceso desde Internet, en EC2 → Instancias → Grupo de seguridad
→ Reglas de entrada, añadir **HTTP TCP 80 desde 0.0.0.0/0** (y `::/0` si
se usa IPv6). SSH 22 debe permanecer restringido a la IP del administrador.
Visitar `http://IP_PUBLICA/`: abre la app responsive en `/app/` con pestañas
Inventario, Procesos y Bitácora. Las API están en `/api/...` y `/metrics`.

**Importante:** es una simulación educativa sin autenticación ni TLS. La API
las API de reservas, despacho, retiro y fallas quedan accesibles a cualquiera
con la URL y pueden alterar el inventario simulado. No usar datos médicos reales.
La IP pública de Academy
puede cambiar al reiniciar el laboratorio; el profesor podrá acceder solo
mientras la instancia y el laboratorio estén activos.
