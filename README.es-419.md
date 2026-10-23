[English](README.md) · **Español (Latinoamérica)**

# 📚 BiblioJules

Un catálogo amigable y modular para tu **biblioteca personal**. Escanea libros
con un lector de códigos de barras USB (o escribe un ISBN a mano), deja que
busque los metadatos en línea y lleva el control de dónde está cada libro,
quién lo tomó prestado y qué todavía quieres comprar.

Construido con **FastAPI + SQLAlchemy + Jinja2 + HTMX + Alpine.js + Tailwind
CSS**. SQLite por defecto, pero la capa de base de datos está totalmente
abstraída, así que cambiar a **PostgreSQL o MariaDB** más adelante es un cambio
de una sola línea.

Alójala una vez y accede desde donde quieras: hay una **app web**, una **app de
escritorio** nativa (Qt/PySide6) y una **app de Android** nativa (Flutter); las
tres usan el mismo catálogo protegido con cuentas. El teléfono también puede
guardar una biblioteca propia y funcionar **sin ningún servidor**.

### Capturas de pantalla

Capturas de pantalla de la app Android (todas tomadas en un teléfono; se muestran reducidas aquí):

<img src="docs/screenshots/dashboard.jpeg" width="240" alt="Dashboard"> <img src="docs/screenshots/catalog.jpeg" width="240" alt="Catálogo"> <img src="docs/screenshots/discover.jpeg" width="240" alt="Descubrir">
<img src="docs/screenshots/add_book.jpeg" width="240" alt="Agregar libro"> <img src="docs/screenshots/book_details.jpeg" width="240" alt="Detalles del libro"> <img src="docs/screenshots/settings.jpeg" width="240" alt="Configuración">
<img src="docs/screenshots/locations.jpeg" width="240" alt="Ubicaciones"> <img src="docs/screenshots/lend.jpeg" width="240" alt="Préstamo">

- **Dashboard** — conteos de libros, autores y editoriales, y desglose por estado
- **Catálogo** — lista de libros con portada, etiquetas de estado y ubicaciones
- **Descubrir** — buscar catálogos en línea (Open Library, Google Books) por ISBN o título
- **Agregar libro** — escanea un código ISBN o escríbelo; los metadatos se rellenan automáticamente
- **Detalles del libro** — página completa con acciones de edición y préstamo
- **Ubicaciones** — jerárquicas: salas → estanterías → repisas → cajas
- **Préstamo** — prestar y devolver libros
- **Configuración** — idioma, tema, URL del servidor

---

## Funciones

- **Escanea para agregar.** Un lector de códigos de barras USB simplemente
  escribe el ISBN y presiona Enter. La app lo busca en servicios gratuitos en
  línea ([Open Library](https://openlibrary.org/developers/api) y
  [Google Books](https://developers.google.com/books)) y completa título,
  autores, editorial, año, cantidad de páginas, descripción e imagen de portada.
  Escribe el ISBN a mano y funciona exactamente igual.
- **Agrega a mano.** Cualquier libro sin ISBN (o desconocido en línea) se puede
  cargar manualmente con el mismo formulario.
- **Carga por lotes.** Marca *Mantener este formulario abierto* y el formulario
  de alta sigue abierto después de cada guardado: los datos del ISBN se limpian,
  mientras que la ubicación, el estado y las notas se conservan, así puedes
  escanear un estante entero de una sola vez. La app de escritorio tiene la
  misma opción en su diálogo de alta.
- **Ubicaciones jerárquicas.** Modela tu casa como quieras: habitaciones →
  bibliotecas → estantes → cajas. Elige una ubicación de una lista con sangría
  al agregar un libro, en lugar de escribirla.
- **Estados.** Estados integrados (En la biblioteca, Leyendo, Prestado, Lista de
  deseos, Perdido, Donado) que puedes renombrar, recolorear, reordenar y
  ampliar con los tuyos.
- **Metadatos de lectura.** Registra el tipo de tapa de cada libro (tapa dura,
  tapa blanda, ebook…), el estado de lectura (sin leer, por leer, leyendo ahora,
  leído, abandonado), una puntuación de 1 a 5 estrellas (en pasos de media
  estrella) y su lugar en una saga (por ejemplo, *Caliban's War* es el n.º 2 de
  *The Expanse*). El catálogo puede filtrar por saga; la tabla de escritorio
  también muestra saga, estado de lectura y puntuación como columnas
  ordenables, y las tarjetas web muestran la saga y la puntuación.
- **Control de préstamos.** Registra quién tomó prestado un libro, cuándo y
  cuándo esperas que lo devuelva. Los préstamos vencidos se resaltan.
- **Lista de deseos.** El estado *Lista de deseos* (`wishlist`) funciona también
  como lista de compras. La página **Descubrir** te permite buscar en los
  catálogos en línea por título/autor para agregar a la lista de deseos libros
  que todavía no tienes.
- **Estadísticas y metas de lectura.** Controla tus estadísticas de lectura
  personales y las metas anuales (objetivo de libros/páginas) desde el Panel y una
  página dedicada de Lectura. El progreso se muestra con barras de progreso; las
  estadísticas incluyen libros/páginas leídos, calificación media, leyendo ahora,
  DNF, perdidos y donados.
- **Lista de deseos por leer.** Lista dedicada de libros que planeas leer. Los
  libros pueden añadirse desde la página de detalles del libro o desde la página
  Descubrir. Las filas de las importaciones CSV sin un ISBN se enrutan automáticamente
  aquí.
- **Importación CSV.** Importa en lote un archivo de Goodreads o StoryGraph. La
  página de importación muestra una vista previa con Enriquecimiento de metadatos,
  detección de duplicados y selección de filas. Las filas sin ISBN se añaden
  automáticamente a la lista de deseos por leer.
- **Subidas de portada.** Sube portadas desde la página de detalles del libro. Las
  imágenes se validan por bytes mágicos, hasta 10 MB. Las portadas subidas se
  almacenan localmente bajo `/covers/` y están asociadas al registro del libro.
- **Filtra y busca.** Filtra por estado, ubicación (incluyendo todo lo que está
  anidado debajo), autor, editorial, estado de lectura y estado de préstamo;
  busca por título, autor, editorial e ISBN.
- **Listas ordenables.** Haz clic en el encabezado de una columna —en la grilla
  del catálogo web o en las tablas Catálogo, Descubrir y Estados de la app de
  escritorio— para ordenar por esa columna, y haz clic de nuevo para alternar
  entre ascendente y descendente.
- **Mira un libro de cerca.** Haz clic en la tarjeta de un libro (o doble clic
  en una fila de la app de escritorio) para abrir una ventana con todos sus
  detalles —incluida la portada— y un acceso directo para editarlos.
- **Interfaz moderna y responsiva** con modo oscuro y ocho temas de color que
  repintan tanto los acentos como las superficies; funciona en teléfono, tablet
  y computadora.
- **Sin conexión en el teléfono.** La app de Android puede guardar todo el
  catálogo en un archivo del dispositivo —sin cuenta, sin servidor y sin red— y
  igual te da el panel, la búsqueda, los filtros, los estantes, los estados y los
  préstamos. Solo las búsquedas en línea necesitan conexión. Consulta
  [*App de Android*](#app-de-android-opcional) más abajo.
- **Interfaz multilingüe.** El inglés es el idioma predeterminado; incluye una
  traducción al español latinoamericano (`es-419`). Cambia el idioma desde la
  barra lateral (web), el selector de idioma (escritorio) o Configuración
  (Android): la elección se recuerda. Agregar otro idioma solo requiere colocar
  un archivo `app/locales/<code>.json` (ver más abajo).
- **API JSON** (`/api/...`) y documentación interactiva en `/docs`. La app de
  escritorio (modo remoto) y la app de Android están construidas sobre ella.
- **Cuentas y catálogo compartido.** Inicio de sesión con usuario y contraseña, y
  un panel de administración para agregar o quitar personas. Todos comparten los
  mismos estantes, así que la app puede alojarse y usarse desde la web, el
  escritorio y el teléfono.
- **Tres interfaces, una biblioteca.** El navegador, una ventana nativa de
  escritorio con modos de base de datos local y remota, y una app nativa de
  Android que puede guardar su propia biblioteca en el teléfono (totalmente sin
  conexión) o comunicarse con una alojada.
- **Comparte esa biblioteca entre dispositivos, sin servidor.** Apunta la página
  de administración web, la app de escritorio y la app de Android a la misma
  carpeta —Google Drive, Dropbox, Syncthing, un pendrive— y todas intercambian
  instantáneas de la biblioteca: gana la edición más reciente de cada fila, las
  eliminaciones también viajan, y en la carpeta nunca aterriza nada que no sean
  archivos completos. Ver [*La misma biblioteca en todos los
  dispositivos*](#la-misma-biblioteca-en-todos-los-dispositivos-opcional-sin-servidor).

---

## Inicio rápido

```bash
# 1. Crea un entorno virtual e instala las dependencias
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 2. (opcional) copia la configuración de ejemplo
cp .env.example .env

# 3. Ejecútala
python run.py
# o, con recarga automática mientras desarrollas:
uvicorn app.main:app --reload
```

Abre <http://127.0.0.1:8000>. La base de datos SQLite y su carpeta se crean
automáticamente en la primera ejecución, en `data/library.db`.

> **Nota:** la interfaz carga Tailwind/HTMX/Alpine desde un CDN y obtiene los
> datos de los libros desde internet, así que la máquina donde se ejecuta
> necesita acceso a la red. Para una instalación totalmente sin conexión,
> incluye esos recursos localmente (ver *Personalización*).

---

## Cuentas e inicio de sesión

BiblioJules es una biblioteca **compartida**: todas las cuentas ven y editan el
mismo catálogo. Las cuentas son control de acceso, no estantes privados.

La primera cuenta de administrador debe crearse desde una terminal (todavía no
hay nadie que pueda iniciar sesión); después, todo el resto se agrega desde la
interfaz web:

```bash
python -m app.cli create-admin          # pide una contraseña
python -m app.cli create-user ana       # una cuenta normal
python -m app.cli list-users
python -m app.cli set-password ana
python -m app.cli delete-user ana
```

Luego inicia sesión en <http://127.0.0.1:8000/login>. Las cuentas
**administradoras** tienen una página extra, *Usuarios*, para agregar cuentas,
cambiar roles, restablecer contraseñas o deshabilitar a alguien. Las cuentas
normales tienen acceso completo al catálogo —solo la gestión de usuarios está
restringida.

Las sesiones duran 30 días (ver `SESSION_TTL_DAYS`) y viven en el servidor, así
que cerrar sesión, cambiar una contraseña o deshabilitar una cuenta surte efecto
de inmediato.

### Alojarla de forma segura

Si expones la app más allá de tu red doméstica:

- Sírvela por **HTTPS** (detrás de un proxy inverso) y define
  `COOKIE_SECURE=true`, para que la cookie de sesión solo se envíe cifrada.
- Considera `ENABLE_DOCS=false` para ocultar `/docs` y el esquema OpenAPI.
- `/api/*` solo acepta tokens Bearer: inicia sesión con `POST /api/auth/login`
  para obtener uno. La app de escritorio (modo remoto) y la app de Android usan
  la misma ruta.

---

## Desplegar con Docker

El repositorio incluye un `Dockerfile` y un `docker-compose.yml`, así que una
instancia alojada —la app web *y* la API JSON que usan las apps de escritorio y
de Android— se levanta con:

```bash
docker compose up -d --build
docker compose run --rm web python -m app.cli create-admin alice
```

Luego abre <http://localhost:8000> e inicia sesión. Tu biblioteca vive en el
volumen `bibliojules-data`, así que reconstruir, reemplazar o actualizar el
contenedor nunca la toca. La imagen se ejecuta con un usuario sin privilegios e
incluye un `HEALTHCHECK` que consulta `/health`, el cual responde `503` cuando la
base de datos es inalcanzable.

Conviene decidir esto antes de exponerla (defínelo en `docker-compose.yml` o en
un archivo `.env` junto a él —compose lee `${VAR}` desde allí):

| Ajuste | Por qué |
| --- | --- |
| `APP_CONTACT` | Open Library pide que los clientes se identifiquen |
| `COOKIE_SECURE=true` | enviar la cookie de sesión solo por HTTPS |
| `ENABLE_DOCS=false` | ocultar `/docs` en una instancia pública |
| `SESSION_TTL_DAYS` | cuánto dura una sesión (30 por defecto) |
| `SYNC_FILE` | la carpeta compartida por la que esta instancia intercambia instantáneas (ver [*La misma biblioteca en todos los dispositivos*](#la-misma-biblioteca-en-todos-los-dispositivos-opcional-sin-servidor)) |
| `SYNC_ON_START=true` | sincronizar una vez al iniciar la aplicación |

**HTTPS.** Termina el TLS delante de la app. El archivo de compose trae un
servicio **Caddy** listo para descomentar, que obtiene el certificado por ti:

```bash
# 1. apunta library.example.com a esta máquina
# 2. descomenta el servicio `caddy` en docker-compose.yml
COOKIE_SECURE=true docker compose --profile tls up -d
```

Cuando eso funcione, deja de publicar el puerto `8000` hacia afuera: Caddy llega
a la app por la red de compose. Cualquier otro proxy inverso (nginx, Traefik, uno
que ya uses) es la misma idea: redirige a `web:8000` y define
`COOKIE_SECURE=true`.

**Copias de seguridad.** Todo está en un solo volumen, y SQLite tiene una llamada
de respaldo en caliente, así que no hace falta detener nada:

```bash
docker compose exec web python -c "import sqlite3; sqlite3.connect('/app/data/library.db').backup(sqlite3.connect('/app/data/backup.db'))"
docker compose cp web:/app/data/backup.db ./library-backup.db
```

**PostgreSQL o MariaDB en lugar de SQLite.** Define `DATABASE_URL` (por ejemplo
`postgresql+psycopg://user:password@db:5432/bibliojules`), agrega el controlador
correspondiente a `requirements.txt` (`psycopg[binary]` o `pymysql`) y añade el
servicio de base de datos al archivo de compose. Nada más cambia en el código.

**Administrar la instancia.** La imagen incluye la misma CLI de administración,
así que las cuentas se manejan dentro del contenedor — `docker compose exec web
python -m app.cli list-users`, `set-password alice`, `create-user bob` — y
Alembic está disponible para cambios de esquema (mira *Evolucionar el esquema
con Alembic* para el `alembic stamp head` que necesita una biblioteca existente).

---

## App de escritorio (opcional, sin navegador)

También hay una interfaz nativa de escritorio en **Qt (PySide6)** para cuando
prefieras no usar un navegador. Tiene dos modos, que se eligen desde
**Archivo → Configuración…**:

- **Base de datos local** (el predeterminado): abre la **misma base de datos
  SQLite** y reutiliza la misma capa de servicios que la app web, así que puedes
  alternar entre las dos libremente —sin necesidad de importar/exportar— (solo no
  ejecutes ambas contra la misma base de datos al mismo tiempo).
- **Servidor remoto**: inicia sesión en una instancia alojada a través de la API
  JSON y **no guarda ninguna base de datos local**, así que un portátil puede usar
  la biblioteca desde donde sea. Escribe la URL del servidor (por ejemplo,
  `https://biblioteca.ejemplo.com`), inicia sesión una vez y el token queda
  recordado.

```bash
# Instala la dependencia extra (Qt + el resto)
pip install -r requirements.txt -r requirements-desktop.txt

# Iníciala
python desktop.py
```

PySide6 incluye wheels precompiladas para **Windows, macOS y Linux** y trae el
runtime de Qt correspondiente, así que no hay que instalar Qt en el sistema. La
app de escritorio necesita el mismo Python que la app web (instalado en el mismo
entorno virtual).

La ventana tiene una barra lateral que refleja las páginas web —**Panel,
Catálogo, Ubicaciones, Estados, Descubrir**— con las mismas capacidades:

- explorar, buscar y filtrar el catálogo; agregar/editar/eliminar libros;
- ordenar cualquier lista haciendo clic en los encabezados de sus columnas;
- escanear y buscar un ISBN (o buscar en línea y agregar a la lista de deseos);
- prestar y devolver libros, con historial de préstamos;
- gestionar el árbol de ubicaciones anidadas y los estados personalizables.

El botón al pie de la barra lateral siempre muestra de dónde vienen los datos (la
base de datos local, o la cuenta con la que iniciaste sesión) y vuelve a abrir el
diálogo de configuración al hacerle clic.

En **modo local** ese diálogo también tiene un grupo *Biblioteca compartida*:
apúntalo a una carpeta que se sincronice sola (Google Drive, Syncthing, un
pendrive) y mantendrá el escritorio, el navegador y tu teléfono en la misma
biblioteca — ver [*La misma biblioteca en todos los
dispositivos*](#la-misma-biblioteca-en-todos-los-dispositivos-opcional-sin-servidor).
**Archivo → Sincronizar la biblioteca ahora…** (`Ctrl+Shift+S`) sincroniza a
pedido, y *Sincronizar al iniciar la aplicación* lo hace al abrirla.

En **modo local**, como abre el archivo de base de datos directamente,
`DATABASE_URL` debe apuntar al mismo archivo para ambas interfaces. El valor
predeterminado (`data/library.db`, ruta absoluta) lo hace; si sobrescribes
`DATABASE_URL` en `.env` con una ruta *relativa*, se resolverá contra el
directorio de trabajo desde el que la inicies, así que es preferible usar una
ruta absoluta.

En cualquier caso, la elección se guarda en `data/preferences.json`. En modo
remoto ese archivo también contiene el token de sesión, por lo que se crea con
permisos `0600`: mantenlo fuera del control de versiones (`data/` ya lo está).

---

## App de Android (opcional)

También hay una app **nativa de Android** (Flutter) para el teléfono. Funciona
en dos modos, se elige en la pantalla de inicio de sesión y se cambia cuando
quieras en **Configuración**:

- **Una biblioteca en este teléfono** — el modo *sin conexión*. Toda la colección
  vive en un único archivo SQLite en el almacenamiento propio de la app: sin
  cuenta, sin servidor y sin red, así que el panel, la búsqueda, los filtros, los
  estantes, los estados y los préstamos funcionan en un avión. Solo **Descubrir**
  y las búsquedas por ISBN necesitan conexión, y le preguntan directamente a Open
  Library y a Google Books.
- **Un servidor** — un cliente liviano para una biblioteca *alojada*: no guarda
  base de datos propia, cada pantalla lee y escribe por la API JSON, y un
  préstamo que registres aquí aparece enseguida en el navegador.

Cambiar de modo conserva los dos: el archivo queda en el teléfono y el token
queda en el *keystore*, así que ir y volver no exige iniciar sesión otra vez.

```bash
cd mobile
flutter pub get
flutter run --release      # o bien: flutter build apk --split-per-abi
```

Los dos modos tienen las mismas funciones que las versiones web y de escritorio
—panel, catálogo con búsqueda y filtros, escaneo de ISBN, ubicaciones, estados,
préstamos, historial de préstamos y búsqueda en línea—, todo menos la gestión de
usuarios, que sigue siendo exclusiva del administrador en la web.

### Mover una biblioteca entre el teléfono y un servidor

La sección local de **Configuración** puede **exportar** la biblioteca del
teléfono e **importar** otra. Las dos pasan por el selector de archivos de
Android, así que el destino puede ser Descargas, un pendrive o una carpeta de
**Google Drive**, sin configuración extra.

- **Exportar** escribe un único archivo `.sqlite` autocontenido. Déjalo en el
  directorio `data/` de una instancia alojada y el servidor ya tiene la
  colección.
- **Importar** toma un archivo —una exportación del teléfono, o el
  `data/library.db` de un servidor, con sus cuentas y todo— y lo convierte en la
  biblioteca de este teléfono. Nada se fusiona: la biblioteca actual se
  reemplaza.

Exportar e importar son un traslado de ida. Para mantener varios dispositivos en
sincronía —el teléfono, el navegador, la app de escritorio— apúntalos todos a una
misma carpeta compartida; consulta [*La misma biblioteca en todos los
dispositivos*](#la-misma-biblioteca-en-todos-los-dispositivos-opcional-sin-servidor).

- **Emulador:** usa `http://10.0.2.2:8000` como URL del servidor para llegar a un
  servidor que corre en la computadora anfitriona.
- **Teléfono:** usa la dirección en la red local de tu computadora
  (`http://192.168.1.20:8000`) o una instancia alojada con **HTTPS**.
- **Las compilaciones de publicación solo permiten HTTPS.** El HTTP sin cifrar
  está habilitado únicamente para las compilaciones de depuración, así puedes
  desarrollar contra un servidor local sin debilitar la app real.

Requiere el **SDK de Flutter 3.47+** y el SDK de Android; no necesita Python en
el teléfono. Consulta [`mobile/README.md`](mobile/README.md) para más detalles.

---

## La misma biblioteca en todos los dispositivos (opcional, sin servidor)

En una casa suele haber el navegador abierto en la notebook de la cocina, la app
de escritorio en la computadora del estudio y un teléfono en el bolsillo. Los tres
pueden trabajar sobre **una sola** biblioteca sin alojar nada: basta con dejar una
**instantánea** en una carpeta que ya se sincroniza sola —Google Drive, Dropbox,
Syncthing, un NAS, un pendrive; cualquier cosa que copie un archivo.

Cada dispositivo conserva su propia base de datos viva y nunca abre la
compartida en el lugar. Una sincronización, en ese orden:

1. lee la instantánea de la carpeta y la combina con la biblioteca local;
2. escribe una instantánea **nueva** de vuelta —pero solo cuando la biblioteca
   local tiene algo que la instantánea no tenía, así dos dispositivos inactivos
   no se rebotan archivos entre sí—;
3. guarda antes una copia de seguridad con fecha y hora de la biblioteca local
   (las últimas diez), para que una mala combinación nunca sea definitiva.

La instantánea es una base de datos BiblioJules normal, que puedes abrir a mano
con cualquier herramienta de SQLite. Se llama `bibliojules-library.sqlite`, no
lleva cuentas y trae un pequeño encabezado `sync_meta` (formato, generación,
identificador de la instantánea y el dispositivo que la escribió) para rechazar
un archivo copiado a medias en lugar de combinarlo.

### Quién gana cuando dos dispositivos no coinciden

| Situación | Resultado |
| --- | --- |
| La misma fila se editó en los dos | Gana la **edición más reciente**. Los empates de fecha los resuelve el identificador interno de la fila, así todos los dispositivos eligen al mismo ganador. |
| Una fila existe en los dos, pero se creó por separado | Se unifican en el primer contacto: los estados por slug, los autores y las editoriales por nombre, y los libros por ISBN. |
| Un libro se eliminó en uno y se editó en el otro | Gana el más reciente: una edición hecha *después* de la eliminación hace volver el libro. |
| Se eliminó un estante | Se va todo el subárbol; los libros de esos estantes simplemente quedan sin ubicación. |
| Los dos editaron la misma fila desde su última sincronización | Se conserva el ganador y el perdedor queda listado en el informe de sincronización, así nada desaparece en silencio. |

Los préstamos viajan con su libro, los estados nunca quedan huérfanos (los libros
vuelven a *In library*) y cada combinación termina con una verificación de
consistencia antes de confirmarse. Si algo sale mal, la combinación se revierte y
la biblioteca queda exactamente como estaba.

### Cómo configurarla

- **Web / servidor:** *Biblioteca compartida* en la barra lateral de
  administración (`/admin/sync`), o `python -m app.cli sync --file
  "/ruta/a/la/carpeta"`. Agrega `SYNC_ON_START=true` para sincronizar una vez al
  iniciar.
- **Escritorio:** *Configuración → Biblioteca compartida*, y luego **Archivo →
  Sincronizar la biblioteca ahora…** (`Ctrl+Shift+S`) cuando quieras. Marca
  *Sincronizar al iniciar la aplicación* para sincronizar al abrirla.
- **Android:** *Configuración → Biblioteca compartida → Elegir carpeta…*. La
  carpeta se elige con el selector propio de Android (Drive es uno de los lugares
  que ofrece) y el permiso se recuerda entre reinicios, así *Sincronizar al
  iniciar la aplicación* funciona sin intervención.

No hay nada que instalar del lado de la carpeta ni cuenta que crear: la carpeta
compartida es la única pieza móvil, y debe ser la **misma carpeta** para todos los
dispositivos. La sincronización necesita el motor SQLite (el predeterminado);
PostgreSQL y MariaDB no son compatibles.

La sincronización no es en tiempo real. Dos dispositivos coinciden cuando cada uno
haya sincronizado: al iniciar, o cuando pulses el botón.

---

## Cómo usarla

1. **Configura tus ubicaciones** (página `Ubicaciones`): agrega una habitación y
   luego anida una biblioteca y estantes debajo.
2. **Escanea un libro**: coloca el cursor en el cuadro de escaneo (queda
   enfocado por ti) y escanea. Revisa los detalles obtenidos, elige una
   ubicación y guarda.
3. **Presta un libro**: ábrelo y usa el panel *Préstamo* para registrar el
   prestatario y la fecha de devolución esperada.
4. **Arma una lista de deseos**: cambia el estado de un libro a *Lista de
   deseos*, o usa **Descubrir** para buscar en línea y agregar libros que
   quieras comprar.

---

## Estructura del proyecto

```
.
├── app/
│   ├── main.py            # Fábrica de la app FastAPI + arranque (crea tablas, siembra)
│   ├── config.py          # Configuración (DATABASE_URL, timeouts…) vía pydantic-settings
│   ├── dependencies.py    # Guardas de autenticación (sesión/Bearer) y CSRF
│   ├── cli.py             # CLI de administración (create-admin, create-user, …)
│   ├── database.py        # Motor, sesión, Base declarativa
│   ├── templating.py      # Entorno Jinja2 + filtros
│   ├── i18n.py            # Núcleo de traducción (estilo gettext) + middleware de idioma
│   ├── themes.json        # Los ocho temas: acentos + rampas de superficies (compartidos)
│   ├── themes.py          # Las carga: valores por defecto, validación, cookie
│   ├── preferences.py     # Pequeño almacén JSON (idioma, acento, origen de datos, token)
│   ├── locales/           # Catálogos de traducción, p. ej. es-419.json (el inglés es la fuente)
│   ├── schemas.py         # Modelos de request de Pydantic para la API JSON
│   ├── models/            # Modelos SQLAlchemy (un archivo por concepto)
│   │   ├── book.py  author.py  publisher.py
│   │   ├── location.py  status.py  loan.py
│   │   ├── user.py  token.py
│   │   └── associations.py
│   ├── services/          # Lógica de negocio (agnóstica del framework)
│   │   ├── library.py     #   CRUD, filtros, préstamos, ubicaciones, estados
│   │   ├── auth.py        #   Cuentas, hash de contraseñas, tokens
│   │   ├── isbn_lookup.py #   Búsquedas en línea de ISBN/metadatos
│   │   ├── serializers.py #   Modelo → dict para la API JSON
│   │   ├── sync.py        #   Instantáneas + la combinación entre dispositivos
│   │   ├── tombstones.py  #   Eliminaciones que tienen que viajar
│   │   └── seed.py        #   Estados predeterminados
│   ├── routers/           # Endpoints HTTP (delgados, llaman a los servicios)
│   │   ├── pages.py  books.py  locations.py  statuses.py
│   │   ├── auth.py        #   /login, /logout, /api/auth/...
│   │   ├── admin.py       #   /admin/users + /api/users
│   │   ├── lookup.py      #   Búsqueda y prellenado de Descubrir
│   │   └── api.py         #   API JSON /api/...
│   ├── templates/         # Plantillas Jinja2 (auth/, admin/, books/, ...)
│   ├── static/            # CSS y JS
│   └── desktop/           # Interfaz de escritorio Qt (PySide6)
│       ├── app.py         #   arranque: elige local o remoto y muestra la ventana
│       ├── repo.py        #   acceso a datos: LocalRepo (SQLite) / RemoteRepo (HTTP)
│       ├── main_window.py #   barra lateral + vistas apiladas
│       ├── settings_dialog.py  # dónde está la biblioteca + inicio de sesión
│       ├── dashboard.py  catalog.py  locations_view.py
│       ├── statuses_view.py  discover.py
│       ├── dialogs.py     #   diálogos de alta/edición de libro, préstamo, ubicación, estado
│       ├── db.py  workers.py  util.py
│       └── ...
├── mobile/                # App de Android con Flutter (biblioteca propia o servidor)
│   ├── lib/
│   │   ├── main.dart      #   abre la biblioteca + preferencias/catálogos y arranca
│   │   └── src/
│   │       ├── app.dart   #   router + guarda de inicio de sesión
│   │       ├── core/      #   cliente de API, providers, modelos, l10n
│   │       ├── widgets/   #   barra superior, tarjeta de libro, campos…
│   │       └── features/  #   un archivo por pantalla
│   ├── assets/locales/    #   copias de los catálogos del servidor
│   └── test/
├── Dockerfile             # Imagen del contenedor para la web + API JSON
├── docker-compose.yml     # Despliegue en un comando (la biblioteca vive en un volumen)
├── .dockerignore
├── migrations/            # Migraciones de Alembic (evolución del esquema)
├── run.py                 # Lanzador web
├── desktop.py             # Lanzador de escritorio
├── dump_schema.py         # Vuelca el esquema del servidor para la verificación de la app de Android
├── generate_theme_surfaces.py  # Recalcula la rampa de superficies de cada tema desde su acento
├── requirements.txt
├── requirements-desktop.txt
└── .env.example
```

**Idea de diseño:** los routers son delgados. Todas las reglas viven en
`app/services/`, y todo el acceso a la base de datos pasa por SQLAlchemy en
`app/models/`. Agregar una función normalmente implica un modelo (tal vez), una
función de servicio y una ruta; el código existente queda intacto. Eso es lo que
lo mantiene fácil de hacer crecer.

---

## Modelo de datos (a grandes rasgos)

- **Book** — ISBN, título/subtítulo, `publisher` (muchos a uno), `authors`
  (muchos a muchos), un único campo de fecha **Publicado** (el año se deriva de
  él para ordenar), descripción, páginas, idioma, URL de la portada, tipo de
  tapa, estado de lectura, una puntuación de 1 a 5 estrellas (pasos de media
  estrella), nombre + número de saga, `location`, `status`, notas, marcas de
  tiempo.
- **Location** — árbol autorreferencial (`parent_id`): habitaciones → estantes → …
- **Status** — nombre, color, emoji, orden de clasificación; `is_system` protege
  los integrados, `is_default` marca el estado que reciben los libros nuevos.
- **Loan** — un período durante el cual un libro estuvo afuera: prestatario,
  fechas de préstamo/vencimiento/devolución, notas. Un préstamo *activo* no
  tiene fecha de devolución.
- **Author/Publisher** — normalizados para poder filtrarlos y reutilizarlos. Las
  filas que ya no tienen ningún libro se eliminan automáticamente (al
  borrar/editar un libro y al iniciar), así los contadores del panel y las
  listas de filtros se mantienen exactos.

---

## Cambiar a PostgreSQL o MariaDB

Como todo pasa por SQLAlchemy, solo cambia la cadena de conexión.

```bash
# PostgreSQL
pip install "psycopg[binary]"
export DATABASE_URL="postgresql+psycopg://user:password@localhost:5432/bibliojules"

# MariaDB / MySQL
pip install pymysql
export DATABASE_URL="mysql+pymysql://user:password@localhost:3306/bibliojules"
```

Ponla en `.env` para hacerla permanente. La app crea las tablas al iniciar si no
existen, y agrega las columnas que se hayan introducido después de crear la base
de datos (un `ALTER TABLE ADD COLUMN` seguro e idempotente). Al mismo tiempo se
ejecutan algunas correcciones de datos pequeñas por única vez; por ejemplo,
fusionar un año de publicación heredado en el único campo **Publicado**.

### Evolucionar el esquema con Alembic

Alembic ya está configurado (y apunta al mismo `DATABASE_URL`). Se incluye una
migración inicial.

> Los cambios aditivos simples se aplican automáticamente al iniciar. Recurre a
> Alembic cuando el cambio sea más complejo (renombres, cambios de tipo,
> columnas eliminadas).

Una base de datos que creó la app tiene todas las tablas pero ninguna fila en
`alembic_version`, así que la primera ejecución de Alembic debe saber que el
esquema existente *ya es* la migración inicial. Hazlo una sola vez por cada
biblioteca existente:

```bash
alembic stamp head                                # una vez, sobre una base creada por la app
```

A partir de ahí (y en una base nueva, donde no hace falta el sello):

```bash
alembic upgrade head                              # aplica las migraciones
alembic revision --autogenerate -m "my change"    # después de editar los modelos
alembic upgrade head
```

Omitir el sello es lo que produce «table authors already exists» en una
biblioteca existente.

> La app de Android guarda su propia copia de este esquema
> (`mobile/lib/src/local/schema.dart`) para poder funcionar sin ningún servidor.
> Después de editar algo en `app/models/`, actualiza el archivo de referencia
> con el que se compara esa copia:
>
> ```bash
> python dump_schema.py
> ```
>
> Así, `mobile/test/schema_parity_test.dart` falla si la copia del teléfono se
> desvió: los dos esquemas deben seguir siendo intercambiables, porque un
> archivo exportado viaja entre ellos.

---

## API JSON

La interfaz HTML usa la misma capa de servicios, pero se expone una pequeña API
JSON para scripting y para los clientes de escritorio/móvil. Todo lo que está
bajo `/api/` requiere un **token Bearer**: obtén uno con `POST /api/auth/login` y
envíalo como `Authorization: Bearer <token>`.

| Método y ruta | Propósito |
| --- | --- |
| `POST /api/auth/login` | Canjear usuario/contraseña por un token |
| `GET /api/auth/me` · `POST /api/auth/logout` | Cuenta actual / revocar el token |
| `GET /api/books` | Lista/filtra libros (`search`, `status`, `location`, `author`, `publisher`, `loaned`, `saga`, `read_status`, `sort`, `dir`) |
| `GET /api/books/{id}` | Un libro |
| `GET /api/books/by-isbn/{isbn}` | Un libro por ISBN (para detectar duplicados) |
| `POST /api/books` · `PUT /api/books/{id}` · `DELETE /api/books/{id}` | Crear / actualizar / eliminar |
| `POST /api/books/{id}/lend` · `.../return` | Prestar o devolver |
| `GET /api/books/{id}/loans` | Historial completo de préstamos |
| `GET /api/locations` · `GET /api/locations/{id}` · `POST /api/locations` · `PUT` · `DELETE` | Ubicaciones |
| `GET /api/statuses` · `GET /api/statuses/{id}` · `POST /api/statuses` · `PUT` · `DELETE` | Estados |
| `GET /api/authors` · `GET /api/publishers` · `GET /api/sagas` | Datos de referencia para filtros |
| `GET /api/dashboard` · `GET /api/stats` | Agregado del panel / contadores |
| `GET /api/meta` | Tipos de tapa, estados de lectura, rango de puntaje, órdenes, roles, idiomas |
| `GET /api/i18n/{lang}` | Catálogo de cadenas de un idioma |
| `GET /api/lookup/isbn/{isbn}` | Búsqueda de metadatos en línea |
| `GET /api/search?q=` | Búsqueda en línea por título/autor |
| `GET /api/users` · `POST /api/users` · `PUT /api/users/{id}` · `DELETE /api/users/{id}` | Gestión de usuarios (**solo administradores**) |
| `GET /health` | Chequeo de disponibilidad — `200` cuando la base de datos responde, `503` en caso contrario (público) |

Documentación interactiva: <http://127.0.0.1:8000/docs>

Los endpoints `PUT` siguen la regla habitual: los campos que **omites** quedan
intactos y un campo que envías como `null` se **borra**; así un cliente con
formularios quita un libro de su estante sin sobrescribir el resto del registro.

---

## Personalización

- **Tema:** `app/themes.json` guarda ocho paletas (rojo, naranja, amarillo,
  verde, azul, violeta, rosa, gris), cada una con un acento de diez tonos *y* una
  rama de superficies de once pasos. La app web las convierte en la escala
  `brand` de Tailwind y en variables `--surface-*` al renderizar (ver
  `_palette.html`). Tailwind se carga desde su Play CDN con una pequeña
  configuración ahí (modo oscuro). Se puede colocar un Tailwind compilado/propio
  en `app/static/css/` y quitar el script del CDN.
- **Fuentes de ISBN:** los proveedores viven en `app/services/isbn_lookup.py`. El
  combinador ya completa campos faltantes desde una segunda fuente; agrega una
  tercera escribiendo una función asíncrona y añadiéndola a la lista de
  proveedores.
- **Estados como la lista de deseos** se conectan por *slug* (`wishlist`,
  `lent`, `available`…). Renombrarlos está bien; el slug se mantiene.

---

## Idiomas (i18n)

El inglés es el idioma de origen y el predeterminado. Las traducciones viven en
`app/locales/<code>.json` como simples mapas `{ "texto en inglés": "traducción" }`,
así que no hay que compilar nada:

```
app/locales/es-419.json   # Español (Latinoamérica)
```

- **Web:** el idioma se elige desde `?lang=`, la cookie `lang` o el encabezado
  `Accept-Language` del navegador (en ese orden). Usa el selector al final de la
  barra lateral (o en el encabezado móvil); la elección se guarda en una cookie.
- **Escritorio:** usa el selector al final de la barra lateral. La elección se
  guarda en `data/preferences.json` (junto con el modo local/remoto y, en modo
  remoto, el token de sesión) y se aplica en el próximo inicio.
- **Agregar un idioma:** copia `app/locales/es-419.json`, traduce los valores y
  añade el código + endónimo a `SUPPORTED_LANGUAGES` en `app/i18n.py`. Una clave
  faltante simplemente recurre al texto en inglés escrito en el código, así que
  un catálogo parcial está bien.
- Las formas plurales usan un valor de objeto: `"book": { "one": "libro", "other": "libros" }`.
- Los nombres de estado integrados (En la biblioteca, Leyendo, …) se traducen por
  *slug*; si renombras uno, se muestra tu nombre tal cual.

---

## Temas

Todos los clientes ofrecen los mismos ocho colores: rojo, naranja, amarillo,
verde, azul (el predeterminado), violeta, rosa y gris. Un tema es más que un
acento: las superficies también lo siguen, así que una biblioteca verde tiene
paneles verde muy oscuro en modo oscuro y una página apenas menta en modo claro,
mientras que una rosa es color vino o rosada.

Las paletas viven una sola vez en `app/themes.json`. Cada tema tiene:

- un **acento**, una escala `50`…`900` estilo Tailwind, más un `ink` para el
  texto dibujado *sobre* el acento (blanco en todos menos el amarillo, donde es
  oscuro para que se lea);
- una **rama de superficies**: los once pasos del gris pizarra de Tailwind con el
  matiz del acento. Cada paso conserva la *luminosidad* del pizarra, así que el
  texto normal, el atenuado y los bordes mantienen exactamente el contraste con
  el que se diseñaron: solo cambia el tono. La entrada `card` es el color del
  panel en modo claro (casi blanco, con un matiz).

La web convierte la rama en variables CSS (`bg-slate-900` pasa a ser un panel
con tema), la app de escritorio arma con ella su hoja de estilos y la paleta de
Qt, y Android pinta con ella el fondo, las tarjetas, los campos, los menús y los
bordes.

Las apps web y de escritorio leen ese archivo directamente. Android no puede leer
los archivos del servidor, así que guarda un espejo en
`mobile/lib/src/theme.dart`; `mobile/test/theme_sync_test.dart` falla si el
espejo y el JSON llegan a diferir.

La elección es por dispositivo, como el idioma:

- **Web:** la página Configuración (`/settings`) guarda el slug en una cookie
  `color_theme`.
- **Escritorio:** Archivo → Configuración → Apariencia lo guarda en
  `data/preferences.json` y recolorea la ventana apenas guardas.
- **Android:** Configuración → Tema lo guarda en las preferencias de la app.

Para agregar un color, añade el slug, la etiqueta, el `ink` y la escala de acento
a `app/themes.json`, ejecuta `python generate_theme_surfaces.py` para derivar su
rampa de superficies y luego refleja el tema en `theme.dart`. Los selectores, la
escala de Tailwind, las variables CSS y la hoja de estilos de escritorio lo toman
solos.

---

## Notas

- La app está pensada para ser compartida en un hogar. Ahora incluye cuentas, así
  que es segura para alojar —pero lee *Alojarla de forma segura* más arriba antes
  de exponerla a internet (HTTPS, `COOKIE_SECURE` y no dejes `/docs` abierto).
- Todo es local: tus datos viven únicamente en el archivo de tu base de datos (en
  el teléfono, en el archivo de biblioteca dentro del almacenamiento privado de
  la app). Las búsquedas en línea solo envían el ISBN que escaneas o las palabras
  que buscas.
