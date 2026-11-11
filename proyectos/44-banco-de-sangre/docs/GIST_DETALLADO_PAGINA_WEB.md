# Banco de sangre #44 — Documentación detallada de la interfaz web

**Proyecto:** Simulación educativa de banco de sangre con Erlang/OTP  
**Repositorio:** https://github.com/Apu3114/erlang-proyectos/tree/main/proyectos/44-banco-de-sangre  
**Demo pública:** http://54.227.229.168/app/ (solo disponible si el laboratorio AWS Academy está encendido)  
**Estado:** HTTP sin autenticación · Datos ficticios · No es un sistema clínico  

**Video de demostración:** consulta el [apartado para el enlace de Loom](#video-de-demostración-en-loom).

---

## 1. Introducción

Esta aplicación web permite consultar y operar una simulación de banco de sangre donde **cada unidad es un proceso Erlang independiente** (`gen_statem`). El sistema controla inventario por tipo sanguíneo, componente, lote y caducidad; asigna respetando compatibilidad ABO/Rh y política FEFO (primero en vencer, primero en salir); reserva unidades para cirugías; alerta niveles críticos; retira unidades de donantes con prueba positiva tardía; y conserva trazabilidad completa donante → unidad → receptor.

La interfaz está en `design/app/index.html` y se sirve mediante nginx en la VM pública. El backend corre con Cowboy sobre Erlang/OTP y escucha en `127.0.0.1:8080`.

**Importante:** toda la información mostrada es ficticia. No usar datos reales ni pacientes reales.

---

## 2. Acceso y requisitos

### Desde el navegador (sin instalar nada)

1. Abrir un navegador moderno (Edge, Chrome, Firefox).
2. Ir a: `http://54.227.229.168/app/`
3. La página redirige/carga directamente en `/app/`.
4. Si el laboratorio AWS Academy está apagado o la IP cambió, la página no abrirá. Consultar la IP pública actual en la consola de AWS Academy.

### Desde la VM por SSH (para desarrollo o despliegue)

```powershell
# Desde PowerShell en Windows
ssh -i "C:\RUTA\DE\TU\CLAVE\aws_academy_p44" ubuntu@54.227.229.168
```

Una vez dentro:

```bash
cd /home/ubuntu/erlang-proyectos/proyectos/44-banco-de-sangre
sudo systemctl is-active p44-banco-de-sangre nginx
```

---

## 3. Vista general de la aplicación

La página usa un solo archivo HTML con CSS embebido y JavaScript vanilla. No depende de frameworks externos.

### Elementos globales

| Elemento | Descripción |
|----------|-------------|
| **Logo** | SVG original en la esquina superior izquierda. Gota de sangre con cruz médica blanca. También usado como favicon. |
| **Cabecera** | Fondo blanco con sombra sutil, contiene el logo, el nombre "Banco de sangre" y un indicador de estado en tiempo real. |
| **Estado del sistema** | Píldora en la cabecera: "● Sistema en línea" (verde) o "● Sin conexión" (gris/rojo). |
| **Navegación** | Barra de pestañas: Inventario, Lotes, Donantes, Procesos, Bitácora. Cambia de vista mediante `location.hash` sin recargar. |
| **Actualización automática** | Los datos se refrescan cada 15 segundos vía `fetch` a los endpoints de la API. |
| **Alertas en tiempo real** | Conexión SSE (`EventSource`) a `/api/alertas` que muestra avisos emergentes cuando hay niveles críticos. |
| **Pie de página** | Advertencia de uso académico y que el laboratorio AWS debe permanecer encendido. |

### Colores principales

- **Rojo sangre principal:** `#801b2d` (botones activos, encabezados, acentos).
- **Rojo oscuro:** `#681526` (hover de botones primarios).
- **Fondo general:** `#f5f6f8` (gris muy claro).
- **Paneles:** blanco con borde `#e5e9ee` y sombra suave.
- **Éxito/ disponible:** verdes suaves.
- **Peligro/crítico:** rojos suaves.

---

## 4. Detalle por sección

### 4.1 Inventario (`#inventario`)

Vista principal al cargar.

**Tarjetas de estado (estadísticas):**
- Disponibles
- Reservadas
- Despachadas
- Próximas a caducar (48 h)

**Formulario de reserva:**
- Tipo del receptor (8 tipos ABO/Rh)
- Componente (Glóbulos rojos, Plasma, Plaquetas)
- Solicitante (texto ficticio, máx. 100 caracteres)
- Reserva en minutos (TTL, 1–1440)

Al reservar, el sistema busca:
1. Tipo exacto disponible.
2. Si no hay, tipos compatibles ordenados por versatilidad (conserva O negativo cuando sea posible).
3. Dentro del tipo, aplica FEFO (la que prima vence primero).

**Existencias disponibles:**
Grid de tarjetas por combinación tipo + componente (ej. `O+ · Glóbulos rojos`). Si hay ≤ 5 unidades, se marca como crítica.

> Ejemplo de uso seguro: consultar existencias sin enviar el formulario, solo para observar.

---

### 4.2 Lotes (`#lotes`)

Permite ver, crear y gestionar lotes de sangre.

**Filtro:** "Solo lotes con unidades disponibles" (marcado por defecto). Al desactivarlo se ven también los lotes vacíos.

**Tarjetas de lote:** muestran nombre, número de lote, componente, estado del refrigerador, total de unidades y disponibles.

**Detalle del lote seleccionado:**
- Nombre y estado del refrigerador (`operando` / `fallado` / `desconocido`)
- Resumen de estados (cuántas disponibles, reservadas, asignadas, retiradas, comprometidas, caducadas)
- Existencias utilizables por tipo y componente
- Tabla de unidades del lote con botón "Ver proceso" para cada una

**Formulario "Crear un lote":**
- Nombre del lote (máx. 80 caracteres)
- Componente (rojos, plasma, plaquetas)
- Al crear, el lote empieza vacío. Luego se puede añadir una unidad de un donante registrado.

**Panel "Añadir una unidad al lote":**
- Solo se muestra si el lote seleccionado está `operando`.
- Desplegable de donantes registrados compatibles (excluye donantes bloqueados y duplicados de mismo donante/componente en ese lote).
- La caducidad se calcula automáticamente: rojos 42 días, plasma 365 días, plaquetas 7 días.

**Simular falla de refrigerador:**
- Desplegable de todos los lotes.
- Botón "Simular falla" (peligro). Acción **irreversible** en la demo pública. Compromete todas las unidades del lote seleccionado.
- Requiere confirmación explícita.

---

### 4.3 Donantes (`#donantes`)

Muestra las fichas de donantes y permite registrar nuevos (ficticios).

**Nota importante:** los donantes originales de la simulación no tenían edad ni peso registrados. La ficha muestra "No registrado" en esos campos. No se inventan datos personales.

**Filtros:**
- Buscar por ID o alias
- Filtrar por tipo sanguíneo (O−, O+, A−, A+, B−, B+, AB−, AB+)

**Lista de donantes:** tarjetas con ID, alias, tipo, total de unidades, disponibles y etiqueta "BLOQUEADO" si aplica.

**Ficha del donante seleccionado:**
- Alias, ID, tipo sanguíneo
- Edad simulada (o "No registrado")
- Peso simulado en kg (o "No registrado")
- Fecha de alta (o "No registrada")
- Total de unidades y disponibles
- Advertencia: "La edad y el peso de los donantes originales no se registraron. No se verifica aptitud médica ni el intervalo entre donaciones."
- Botón "Retirar unidades de este donante" (abre el panel de retiro)

**Formulario "Registrar donante ficticio":**
- Alias ficticio (máx. 80 caracteres, requerido)
- Tipo sanguíneo
- Edad simulada opcional (18–65)
- Peso simulado en kg opcional (50–250)
- Advertencia: no usar nombres, teléfonos ni datos médicos reales. No certifica aptitud para donar.

**Panel "Retiro por prueba positiva tardía":**
- ID del donante (requerido)
- Motivo (máx. 200 caracteres, requerido)
- Acción irreversible sobre la demo. Retira unidades disponibles del donante y reporta las ya despachadas con su receptor para seguimiento. El donante queda bloqueado para nuevas unidades.

---

### 4.4 Procesos (`#procesos`)

Lista de unidades con sus estados actuales.

**Filtros:**
- Buscar por ID de unidad o ID de donante
- Estado (todos, disponible, reservada, asignada, retirada, comprometida, caducada)
- Componente (todos, glóbulos rojos, plasma, plaquetas)

**Cada fila muestra:**
- Número de unidad, tipo y componente
- Donante, lote, fecha de caducidad
- Solicitante y receptor (si aplica)
- Badge con el estado actual
- Acciones según el estado:
  - Si está `reservada`: "Despachar" (pide receptor ficticio) y "Liberar"
  - Si está `disponible` o `reservada`: "Retirar" (pide motivo)
  - Siempre: "Historial" (abre la bitácora filtrada por esa unidad)

> Máximo 100 unidades mostradas por vista para rendimiento.

---

### 4.5 Bitácora (`#bitácora`)

Trazabilidad de eventos del sistema.

**Filtro opcional:** ID de unidad (para ver solo los eventos de una unidad específica).

**Cada evento muestra:**
- Fecha y hora (formato es-MX)
- Unidad afectada y evento/estado
- Descripción del evento

Últimos 100 eventos. Se actualiza automáticamente cada 15 segundos si se está en esta pestaña.

---

## 5. API HTTP y métricas

El backend Cowboy expone los siguientes endpoints (todos bajo `/api/` o `/metrics`):

| Ruta | Método | Qué hace |
|------|--------|----------|
| `/api/inventario` | GET | Existencias por tipo y componente |
| `/api/solicitudes` | POST | Reserva una unidad (cuerpo JSON con receptor, componente, solicitante, ttl_ms) |
| `/api/alertas` | GET | Stream SSE con alertas críticas |
| `/metrics` | GET | Unidades por estado, próximas a caducar en 48 h, histórico de asignadas |
| `/api/unidades` y `/api/unidades/:id` | GET | Listar unidades y detalle actual de una unidad |
| `/api/unidades/:id/acciones` | POST | Despachar, liberar o retirar una unidad |
| `/api/bitacora?unidad=ID` | GET | Últimos 100 eventos (opcionalmente filtrados por unidad) |
| `/api/refrigeradores/:id/falla` | POST | Simular falla de un lote/refrigerador |
| `/api/donantes` y `/api/donantes/:id` | GET | Fichas de donantes y unidades vinculadas |
| `/api/donantes` | POST | Registrar donante ficticio |
| `/api/donantes/:id/retirar` | POST | Retirar unidades por prueba positiva tardía |
| `/api/lotes` y `/api/lotes/:id` | GET | Lotes con estado y existencias (incluidos vacíos) |
| `/api/lotes` | POST | Crear lote vacío para un componente |
| `/api/lotes/:id/unidades` | POST | Añadir una unidad de donante existente al lote |

Todos los handlers validan entrada con lista blanca y responden JSON con códigos 200/201/400/404/405/409/503.

---

## 6. Sección de capturas (para la entrega)

El estudiante debe tomar capturas de pantalla desde su navegador y pegarlas aquí o en su entrega. Ejemplo de tabla para organizar:

| Pantalla | Qué mostrar | Archivo de captura |
|----------|-------------|--------------------|
| Cabecera + Logo | Logo en esquina, nombre, estado en línea | `captura-logo.png` |
| Inventario | Tarjetas de estado, existencias, formulario de reserva | `captura-inventario.png` |
| Lotes | Lista de lotes, detalle de uno, formulario crear lote | `captura-lotes.png` |
| Donantes | Lista de donantes, ficha de uno, formulario registrar | `captura-donantes.png` |
| Procesos | Lista de unidades, filtros, acciones | `captura-procesos.png` |
| Bitácora | Eventos recientes, filtro por unidad | `captura-bitacora.png` |
| Pruebas | Terminal con `rebar3 eunit` (76 pruebas, 0 fallos) | `captura-pruebas.png` |
| Simulación | Terminal con `p44_simulador:correr()` y resultados | `captura-simulacion.png` |
| Caos | Terminal con `p44_caos:correr()` y 6 experimentos ok | `captura-caos.png` |

> **Instrucción:** abre la app en `http://54.227.229.168/app/`, navega por cada pestaña y presiona `Pant Pant` o `Win + Shift + S` (Windows) para capturar. No incluyas credenciales, IPs privadas ni datos reales.

### Video de demostración en Loom

**Enlace del video:** **[PEGA AQUÍ TU ENLACE DE LOOM]**

El autor indicó que ya tiene el video. Antes de entregar, reemplaza el texto entre corchetes por la URL completa de Loom y comprueba en una ventana privada del navegador que el profesor pueda verlo. No incluyas claves ni datos personales en la grabación.

---

## 7. Prompts usados con OpenCode durante el desarrollo

A continuación se listan los principales prompts que el estudiante usó con el asistente OpenCode para construir y mejorar el proyecto. Sirven como registro de las decisiones tomadas.

### Prompt inicial del proyecto
> "Hacer más profesional la aplicación del banco de sangre, crear un logo para la esquina y preparar la documentación de entrega en Gist junto con un guion para Loom."

### Mejoras visuales y logo
> "mira si pues hacerla mucho mas profesional y realizar un logo para la pagina y que este en la esquina te lo agradeceria muhco"

Se creó `design/app/logo.svg` (gotas de sangre con cruz médica blanca, sin imágenes externas) y se reescribió el CSS de `design/app/index.html` para usar:
- Variables CSS (`:root`)
- Cabecera con logo y estado
- Tarjetas, paneles, botones y formularios con bordes redondeados y sombras
- Diseño responsivo con `@media` para móvil y escritorio

### Donantes y lotes
> "ose si pues hacerla mucho mas profesional... en el de lotes falta lo que es la crecion de ellos hazlo mas completo tu tambien agrega cosas"

Se añadieron:
- `src/p44_catalogo.erl` (altas serializadas de donantes, lotes y unidades)
- `src/p44_http_catalogo_donantes_handler.erl`
- `src/p44_http_lotes_handler.erl`
- `src/p44_http_lote_unidades_handler.erl`
- Sección Donantes en el HTML con búsqueda, filtros, registro ficticio y retiro
- Sección Lotes mejorada con crear lote vacío, añadir unidad y simular falla

### Corrección de persistencia DETS
> "al probar la persistencia descubrí un fallo previo importante..."

Se corrigieron `src/p44_bitacora.erl`, `src/p44_unidad.erl` y `src/p44_refrigerador.erl` para que:
- Cada registro DETS tenga clave única entre reinicios (nanosegundos + bytes aleatorios)
- El historial se ordene por fecha
- Las unidades y refrigeradores busquen explícitamente su evento de creación

### Simulación y caos
> "dame una guia de como inicarlo desde otra computadora y dame de que la manera de usar ssh desde otra computadoro"

Se ejecutaron y verificaron:
- `p44_simulador:correr()` → accidente O−, pico de cirugías A+, retiro por donante, falla de refrigerador
- `p44_caos:correr()` → 6 experimentos (unidad, refrigerador, alertas, inventario, supervisor, bitácora)
- `p44_simulador:invariantes()` → `ok`

### Documentación y entrega
> "mira ya comparti ese gist para la entrega de mi proyecto, ese no lo borres ni lo modifiques pero ahora ocupo que hagas otro que explique todo lo dela pagina a detalle..."

Se creó este documento y el Gist asociado.

---

## 8. Tecnologías y arquitectura

### Backend (Erlang/OTP)
- **Lenguaje:** Erlang/OTP 26.2.5 (compilado con kerl en la VM)
- **Build tool:** rebar3 3.28.0
- **Servidor HTTP:** Cowboy (sin dependencias externas de JSON; se usa `p44_json` propio)
- **Modelo de procesos:** Una unidad de sangre = un proceso `gen_statem`
- **Supervisión:** `p44_banco_de_sangre_sup` con estrategia `rest_for_one`
- **Persistencia:** ETS (rápido, en memoria) + DETS (disco, sobrevive a reinicios)
- **Supervisores dinámicos:** `p44_unidades_sup` y `p44_refrigeradores_sup` (estrategia `simple_one_for_one`)
- **Repoblador:** recrea unidades y refrigeradores desde DETS tras caídas
- **Grupos de procesos:** `pg` para localizar unidades por lote y donante sin recorrer las 300

### Frontend
- HTML5, CSS3, JavaScript vanilla (ES6+)
- Diseño responsivo (grid, flexbox, media queries)
- Fetch API para REST
- EventSource para SSE (alertas en tiempo real)
- SVG embebido para el logo

### Despliegue
- VM Ubuntu en AWS Academy
- systemd servicio `p44-banco-de-sangre`
- nginx proxy inverso HTTP/80
- IP pública puede cambiar al reiniciar el laboratorio

---

## 9. Advertencias y limitaciones

1. **Datos ficticios:** la web es pública y no tiene autenticación. No introducir nombres reales, teléfonos, datos médicos ni credenciales.
2. **Sin TLS:** la conexión es HTTP, no HTTPS.
3. **Demo pública compartida:** cualquier persona con la URL puede leer y modificar el inventario simulado. Para pruebas destructivas (fallas, retiros, reinicios), usar una copia aislada del proyecto.
4. **`p44_simulador:reiniciar/0` borra la bitácora:** nunca ejecutar en la VM pública.
5. **Punto único de falla:** el archivo DETS (`_build/prod/rel/p44_banco_de_sangre/priv/p44_bitacora.dets`) no está replicado. Respaldarlo antes de reconstruir el release.
6. **IP cambiante:** la IP de AWS Academy puede cambiar. Verificar antes de presentar.
7. **Compatibilidad simplificada:** plasma y plaquetas usan una regla simplificada (ABO invertido, Rh ignorado). No sustituye reglas clínicas reales.
8. **Intervalo entre donaciones:** no se modela en el código (aunque la NOM-253-SSA1-2012 lo establece). No se verifica aptitud médica.

---

## 10. Checklist de entrega

- [x] Video de Loom preparado (según indica el autor; enlace aún no añadido aquí)
- [ ] Enlace de Loom pegado en el apartado anterior y acceso verificado
- [ ] Capturas de la app real tomadas (inventario, lotes, donantes, procesos, bitácora)
- [ ] Capturas de pruebas (`rebar3 eunit`: 76 pruebas, 0 fallos)
- [ ] Capturas de simulación y caos (invariantes = ok)
- [ ] Gist publicado con este manual y enlaces
- [ ] Código subido a `https://github.com/Apu3114/erlang-proyectos` rama `main`
- [ ] App pública verificada en `http://54.227.229.168/app/`
- [ ] No se incluyeron claves privadas ni datos reales en ninguna entrega

---

*Documento generado como parte de la entrega del proyecto #44 Banco de sangre. Última actualización: 11 de noviembre de 2026.*
