# Entrega — Banco de sangre (#44)

**Proyecto:** simulación educativa, no sistema clínico. **Repositorio:** [Apu3114/erlang-proyectos — proyecto 44](https://github.com/Apu3114/erlang-proyectos/tree/main/proyectos/44-banco-de-sangre). **Demo:** http://54.227.229.168/ (solo disponible si el laboratorio AWS Academy está encendido; la IP puede cambiar). El sitio usa HTTP, no tiene autenticación y solo admite datos ficticios. **Video Loom:** pendiente de grabación y enlace por el autor; no se presenta como entregado.

## Manual de uso para el cliente

**Propósito.** Consultar el inventario simulado, seguir cada unidad de un donante a un lote y a un receptor, reservar/despachar unidades y observar alertas y fallas. Público previsto: estudiante/evaluador; **no** hospitales ni pacientes.

**Acceso rápido sin instalar:** en un navegador moderno, abre `http://54.227.229.168/` mientras AWS Academy esté activo. Se redirige a `/app/`. La esquina superior muestra el logo y «Sistema en línea» cuando las API responden. Si el laboratorio cambia de IP, usa la nueva IP pública. No introduzcas datos reales: cualquier visitante puede leer y modificar esta demo sin autenticación.

**Instalación reproducible en VM Ubuntu con Erlang/OTP y rebar3:** clona el repositorio, entra en `proyectos/44-banco-de-sangre`, ejecuta `rebar3 compile`, `rebar3 eunit` y `rebar3 as prod release`. Para servirlo públicamente, configura nginx, systemd y las reglas de acceso siguiendo [deploy/aws/README.md](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/deploy/aws/README.md). En esta VM se activó OTP 26.2.5 mediante `. /home/ubuntu/otp/26.2.5/activate`; en otra VM usa la ruta de tu instalación. Cowboy escucha en `127.0.0.1:8080`, nginx publica HTTP/80; abre el puerto 80 y restringe SSH. Un clon limpio no incluye la bitácora: inicia vacío. Para cargar 300 unidades **solo en una VM vacía** usa la instrucción `p44_simulador:cargar(p44_simulador:generar(42))` documentada en deploy/aws/README.md. Nunca ejecutes `reiniciar/0` con datos que desees conservar.

**Uso paso a paso:**

1. **Inventario:** revisa tarjetas de disponibilidad y próximos vencimientos. Para reservar, elige tipo del receptor, componente, solicitante **ficticio** y duración; pulsa «Reservar». El sistema busca primero tipo exacto, luego compatible y elige la unidad que antes vence (FEFO).
2. **Procesos:** busca el ID de la unidad reservada. Puedes despachar (introduce receptor ficticio), liberar antes de que expire o retirar si corresponde. «Historial» abre los eventos de esa unidad. Ejemplo seguro de consulta: busca la unidad `1` y abre su historial **sin pulsar acciones**. Las acciones de estado son reales sobre la simulación pública.
3. **Lotes:** abre un lote para ver componente, refrigerador, unidades y caducidad. Desactiva «Solo lotes con unidades disponibles» para ver también los vacíos. «Crear un lote» pide nombre y componente; tras crearlo selecciona un donante registrado y «Añadir unidad». Se impide duplicar al mismo donante y componente en ese lote. «Simular falla» es **irreversible** en esa demo: úsalo solo en un entorno de pruebas.
4. **Donantes:** busca por alias/ID, filtra por tipo y revisa sus unidades. Los donantes originales no registraron edad/peso: se muestra «No registrado». «Registrar donante ficticio» pide alias y tipo; edad/peso simulados son opcionales, no una certificación de aptitud. «Retiro por prueba positiva tardía» bloquea nuevas unidades y reporta las ya entregadas; acción irreversible sobre la demo.
5. **Bitácora:** consulta los últimos 100 eventos o filtra por ID. El tablero se actualiza automáticamente cada 15 segundos; las alertas se reciben por SSE. Para ver datos actualizados manualmente, recarga la página.

**Ejemplo de recorrido sin alterar datos:** Inventario → observar existencias → Donantes → buscar ID y abrir su ficha → Lotes → inspeccionar unidades → Procesos → consultar unidad e historial → Bitácora. Para probar altas/reservas/fallas, utiliza una copia de desarrollo con datos ficticios, no la demo compartida.

**Problemas frecuentes:**

| Síntoma | Comprobación y solución |
|---|---|
| La web no abre | Enciende el laboratorio AWS Academy, confirma IP pública y regla HTTP/80; comprueba `sudo systemctl is-active nginx p44-banco-de-sangre` en la VM. |
| Aparece «Sin conexión» | Consulta `/metrics` y `/api/unidades`; comprueba servicio OTP, nginx y sus logs. Si solo fallan altas, revisa que el backend y la web estén actualizados juntos. |
| Arranca sin inventario | Un clon nuevo no contiene DETS. Carga la simulación una vez en un nodo vacío, nunca sobre la demo con datos. |
| El lote recién creado no aparece | Desactiva el filtro «Solo lotes con unidades disponibles»; el lote empieza vacío. |
| No puedo añadir una unidad | Comprueba que el refrigerador opera, que el donante existe y no está bloqueado y que no hay otra unidad suya del mismo componente en ese lote. |
| La reserva falla | Puede faltar tipo compatible o la unidad pudo caducar; revisa existencias y alertas. |
| No aparece edad o peso | Esos campos no existían para los donantes originales. No son datos inventados ni una avería. |

**Capturas/evidencias:** las tres capturas de Stitch se enlazan abajo; captura también la interfaz real en Inventario, Lotes, Donantes y Bitácora desde el navegador al grabar Loom. No incluyas credenciales ni nombres reales.

## Solución y diseño OTP

- Cada unidad es un proceso `p44_unidad` (`gen_statem`): disponible, reservada, asignada, caducada, retirada o comprometida. Verifica la caducidad al reservar y al despachar; por eso ni un índice desactualizado puede asignar una unidad vencida o duplicarla.
- `p44_banco_de_sangre_sup` usa `rest_for_one`: `pg` → bitácora → supervisores dinámicos de unidades y refrigeradores → repoblador → inventario → catálogo → alertas. Si falla una unidad, su supervisor la reinicia con su historial; si falla un supervisor dinámico, el repoblador recrea sus hijos. La bitácora ETS + DETS permite recuperar el estado incluso tras reiniciar la VM.
- `p44_inventario` mantiene el índice FEFO; prioriza tipo exacto y luego compatibles, conservando O negativo cuando sea posible. La unidad tiene la última palabra. `p44_refrigerador` compromete un lote en caso de falla; `p44_donantes` retira unidades por resultado positivo tardío e informa las ya despachadas para seguimiento.
- `p44_catalogo` serializa altas de donantes ficticios, lotes vacíos y unidades; el registro persiste en DETS. Donantes históricos muestran ID, tipo y unidades inferidas, no edad o peso inventados. Donantes retirados quedan bloqueados para nuevas unidades.

## Simulación y casos difíciles

Semilla 42: **300 unidades, 8 tipos sanguíneos, 3 componentes**. En la corrida reproducible descrita en el [README](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/README.md#resultados-de-la-simulaci%C3%B3n): el accidente pide 20 O− y se surten 20 exactas; el pico de 50 reservas A+ se resuelve con 40 exactas y 10 A−; 20 reservas no usadas vencen y vuelven al inventario; el donante positivo se retira y el refrigerador fallado compromete su lote. Resultado de esa **corrida de referencia**, no del tablero en vivo: 207 disponibles, 50 asignadas, 1 retirada, 42 comprometidas. `p44_simulador:invariantes/0` valida los historiales; la expiración se comprueba también en cada operación.

## Caos: expectativa y resultado de la corrida de referencia

| Proceso terminado | Esperado | Observado |
|---|---|---|
| Unidad con reserva viva | Recuperar reserva | Reinició con la misma reserva |
| Refrigerador fallado | Mantener lote inutilizable | Reinició fallado; sus 54 unidades permanecieron inutilizables |
| Alertas | Re-notificar niveles críticos | Reinició y re-notificó 9 niveles en la nueva corrida (8 en la corrida anterior) |
| Inventario bajo carga | Reconstruir índice | Coincidió con las unidades disponibles |
| Supervisor de unidades | Recuperar las 300 | Las 300 volvieron con estados idénticos |
| Bitácora | Recargar desde DETS | Recuperó 300 unidades y el historial |

**Nueva ejecución aislada (10 de noviembre de 2026, VM AWS, sin tocar producción):** `rebar3 compile` y `rebar3 eunit` → **76 pruebas, 0 fallos**; `p44_simulador:correr()` → 207 disponibles, 50 asignadas, 1 retirada, 42 comprometidas, `invariantes=ok`; `p44_caos:correr()` → **6/6 experimentos con `ok=true`**, 29 solicitudes surtidas durante la carga, 0 interrumpidas observadas, `invariantes=ok`; la bitácora recuperó 300 unidades antes/después del reinicio. Cada ejecución usó su propio archivo DETS en una copia separada del proyecto. La prueba bajo carga no demuestra cómo responderían solicitudes justo en el instante de caída del inventario. El archivo DETS continúa siendo un punto único de falla; hay que respaldarlo. En producción se verificó que las **300 unidades y 3 refrigeradores fallados** persistían tras reiniciar, sin borrar la simulación.

## Supuestos y cifras verificadas

- Plantilla inventada: 180 unidades de rojos, 90 de plasma, 30 de plaquetas; umbral crítico propio: 5 por tipo/componente. Emergencia sin tipificar representada como solicitud O−; no existe cola de prioridad.
- Vida útil modelada: rojos 42 días, plaquetas 7 días, plasma 365 días. La [NOM-253-SSA1-2012](https://www.dof.gob.mx/nota_detalle.php?codigo=5275587&fecha=26/10/2012) condiciona estos plazos a preparación y temperatura: el plasma puede durar hasta 36 meses a ≤ −25 °C o 3 meses entre −18 °C y −25 °C. Se mantuvo un año por el enunciado; no se modela temperatura.
- Compatibilidad simplificada en plasma y plaquetas (ABO invertido, Rh ignorado); no sustituye reglas clínicas reales. Un refrigerador por lote, sin simular agitación o temperatura.
- La norma establece intervalos mínimos entre donaciones (p. ej. 8 semanas entre dos donaciones de sangre total) y criterios de aptitud. El sistema **no verifica** intervalos, pruebas infecciosas previas ni aptitud; los campos de edad/peso simulados no certifican elegibilidad. La distribución de tipos «más comunes en México» no se verificó con datos epidemiológicos y no se afirma como hecho.

## Compilación, pruebas y evidencias

En `proyectos/44-banco-de-sangre/` con Erlang/OTP y rebar3:

```bash
rebar3 compile
rebar3 eunit
```

**Última ejecución verificada en la VM:** 76 pruebas EUnit, 0 fallos; compilación y release completados. La prueba de simulación y caos está documentada en el README. No ejecutes `p44_simulador:reiniciar/0` en la demo: **elimina su bitácora**.

**Capturas de Stitch:** [dashboard](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/design/dashboard/screen.png), [detalle de unidad](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/design/detalle_unidad/screen.png) y [bitácora](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/design/bitacora/screen.png). Estas son maquetas, no capturas de datos reales. **Captura de la app funcional:** pendiente de adjuntar por el autor durante la grabación/entrega; la aplicación funcional es `design/app/`.

**Guion del video:** [docs/GUION_LOOM.md](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/docs/GUION_LOOM.md). El video debe grabarse y enlazarse por el autor. El enunciado disponible (`problema/readme.md`) no especifica Loom ni Gist; si hay rúbrica adicional, comprobarla antes de entregar.
