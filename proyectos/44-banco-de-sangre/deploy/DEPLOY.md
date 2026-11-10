# Desplegar el release (relx + systemd)

Esto empaqueta la aplicación como un **release autocontenido** (incluye el
runtime de Erlang, no necesitas `rebar3` ni Erlang instalado aparte para
correrlo) y lo deja arrancando solo, como un servicio del sistema.

No se probó el build completo en el entorno donde se escribió esto (sin acceso
a `rebar3`/hex.pm). Lo de abajo son los pasos estándar de un release con relx;
verifícalo aquí, en tu VM o en la Raspberry Pi, y avisa si algo no coincide.

## 1. Construir el release

Desde `proyectos/44-banco-de-sangre/`:

```bash
rebar3 as prod release
```

Si todo sale bien, el release queda en
`_build/prod/rel/p44_banco_de_sangre/`. Pruébalo ahí mismo antes de mover nada:

```bash
_build/prod/rel/p44_banco_de_sangre/bin/p44_banco_de_sangre console
```

Debe arrancar igual que `rebar3 shell`, con el mismo prompt de Erlang. Sal con
`q().` Si en vez de eso ves errores de "app not found" para cowboy, cowlib o
ranch, revisa que `rebar.lock` siga listando esas tres dependencias (ver
`rebar.config`, que ya las declara explícitas en el release).

## 2. Copiar el release a su lugar final

El `.service` en este mismo directorio asume `/opt/p44_banco_de_sangre`.
Ajusta la ruta en ambos lados si usas otra.

```bash
sudo mkdir -p /opt/p44_banco_de_sangre
sudo cp -r _build/prod/rel/p44_banco_de_sangre/* /opt/p44_banco_de_sangre/
sudo chown -R pi:pi /opt/p44_banco_de_sangre
```

## 3. Instalar el servicio

```bash
sudo cp deploy/p44_banco_de_sangre.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now p44_banco_de_sangre
```

## 4. Verificar

```bash
sudo systemctl status p44_banco_de_sangre
journalctl -u p44_banco_de_sangre -f
curl http://localhost:8080/api/inventario
```

Para entrar a una consola del nodo que ya está corriendo (sin reiniciarlo):

```bash
sudo /opt/p44_banco_de_sangre/bin/p44_banco_de_sangre remote_console
```

## Notas y supuestos de este paso

- El puerto HTTP (`8080`, en `config/sys.config`) no es privilegiado, así que
  el servicio corre como el usuario `pi`, no como `root`. Más seguro y más
  simple.
- El cookie de distribución Erlang en `config/vm.args` es uno generado una
  sola vez para este proyecto y vive en el repo. Sirve para `remote_console`
  local; si este nodo alguna vez se conecta a otros por la red, hay que
  generar uno propio y no commitearlo.
- Cada actualización del código requiere repetir desde el paso 1 (`rebar3 as
  prod release`) y volver a copiar los archivos; relx no trae "hot code
  reload" configurado aquí, aunque la plataforma (OTP) sí lo soporta si se
  quiere ir más allá del alcance de este proyecto.
