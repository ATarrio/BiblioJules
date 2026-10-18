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
- **Interfaz moderna y responsiva** con modo oscuro; funciona en teléfono,
  tablet y computadora.
- **Interfaz multilingüe.** El inglés es el idioma predeterminado; incluye una
  traducción al español latinoamericano (`es-419`). Cambia el idioma desde la
  barra lateral (web) o el selector de idioma (escritorio): la elección se
  recuerda. Agregar otro idioma solo requiere colocar un archivo
  `app/locales/<code>.json` (ver más abajo).
- **API JSON** (`/api/...`) y documentación interactiva en `/docs`, para que una
  futura app móvil o SPA pueda reutilizar el mismo backend.

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

## App de escritorio (opcional, sin navegador)

También hay una interfaz nativa de escritorio en **Qt (PySide6)** para cuando
prefieras no usar un navegador. Se conecta a la **misma base de datos SQLite** y
reutiliza la misma capa de servicios que la app web, así que puedes alternar
entre las dos libremente —sin necesidad de importar/exportar— (solo no ejecutes
ambas contra la misma base de datos al mismo tiempo).

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

Como abre el archivo de base de datos directamente, `DATABASE_URL` debe apuntar
al mismo archivo para ambas interfaces. El valor predeterminado
(`data/library.db`, ruta absoluta) lo hace; si sobrescribes `DATABASE_URL` en
`.env` con una ruta *relativa*, se resolverá contra el directorio de trabajo
desde el que la inicies, así que es preferible usar una ruta absoluta.

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
│   ├── database.py        # Motor, sesión, Base declarativa
│   ├── templating.py      # Entorno Jinja2 + filtros
│   ├── i18n.py            # Núcleo de traducción (estilo gettext) + middleware de idioma
│   ├── preferences.py     # Pequeño almacén JSON de preferencias (idioma de escritorio, ...)
│   ├── locales/           # Catálogos de traducción, p. ej. es-419.json (el inglés es la fuente)
│   ├── schemas.py         # Modelos de request de Pydantic para la API JSON
│   ├── models/            # Modelos SQLAlchemy (un archivo por concepto)
│   │   ├── book.py  author.py  publisher.py
│   │   ├── location.py  status.py  loan.py
│   │   └── associations.py
│   ├── services/          # Lógica de negocio (agnóstica del framework)
│   │   ├── library.py     #   CRUD, filtros, préstamos, ubicaciones, estados
│   │   ├── isbn_lookup.py #   Búsquedas en línea de ISBN/metadatos
│   │   ├── serializers.py #   Modelo → dict para la API JSON
│   │   └── seed.py        #   Estados predeterminados
│   ├── routers/           # Endpoints HTTP (delgados, llaman a los servicios)
│   │   ├── pages.py  books.py  locations.py  statuses.py
│   │   ├── lookup.py      #   Búsqueda y prellenado de Descubrir
│   │   └── api.py         #   API JSON /api/...
│   ├── templates/         # Plantillas Jinja2 (+ macros reutilizables)
│   ├── static/            # CSS y JS
│   └── desktop/           # Interfaz de escritorio Qt (PySide6)
│       ├── app.py         #   arranque de la app (crea tablas + siembra, muestra la ventana)
│       ├── main_window.py #   barra lateral + vistas apiladas
│       ├── dashboard.py  catalog.py  locations_view.py
│       ├── statuses_view.py  discover.py
│       ├── dialogs.py     #   diálogos de alta/edición de libro, préstamo, ubicación, estado
│       ├── db.py  workers.py  util.py
│       └── ...
├── migrations/            # Migraciones de Alembic (evolución del esquema)
├── run.py                 # Lanzador web
├── desktop.py             # Lanzador de escritorio
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

```bash
alembic upgrade head                              # aplica las migraciones
alembic revision --autogenerate -m "my change"    # después de editar los modelos
alembic upgrade head
```

---

## API JSON

La interfaz HTML usa la misma capa de servicios, pero se expone una pequeña API
JSON para scripting o una futura interfaz:

| Método y ruta | Propósito |
| --- | --- |
| `GET /api/books` | Lista/filtra libros (`search`, `status`, `location`, `author`, `publisher`, `loaned`, `saga`, `read_status`, `sort`) |
| `GET /api/books/{id}` | Un libro |
| `POST /api/books` · `PUT /api/books/{id}` · `DELETE /api/books/{id}` | Crear / actualizar / eliminar |
| `POST /api/books/{id}/lend` · `.../return` | Prestar o devolver |
| `GET /api/locations` · `POST /api/locations` | Ubicaciones |
| `GET /api/statuses` · `POST /api/statuses` | Estados |
| `GET /api/lookup/isbn/{isbn}` | Búsqueda de metadatos en línea |
| `GET /api/search?q=` | Búsqueda en línea por título/autor |
| `GET /api/stats` | Contadores para el panel |
| `GET /health` | Chequeo de disponibilidad — `200` cuando la base de datos responde, `503` en caso contrario |

Documentación interactiva: <http://127.0.0.1:8000/docs>

---

## Personalización

- **Tema:** Tailwind se carga desde su Play CDN con una pequeña configuración en
  `app/templates/base.html` (color de marca, modo oscuro). Se puede colocar un
  Tailwind compilado/propio en `app/static/css/` y quitar el script del CDN.
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
  guarda en `data/preferences.json` y se aplica en el próximo inicio.
- **Agregar un idioma:** copia `app/locales/es-419.json`, traduce los valores y
  añade el código + endónimo a `SUPPORTED_LANGUAGES` en `app/i18n.py`. Una clave
  faltante simplemente recurre al texto en inglés escrito en el código, así que
  un catálogo parcial está bien.
- Las formas plurales usan un valor de objeto: `"book": { "one": "libro", "other": "libros" }`.
- Los nombres de estado integrados (En la biblioteca, Leyendo, …) se traducen por
  *slug*; si renombras uno, se muestra tu nombre tal cual.

---

## Notas

- La app está pensada para una red doméstica de confianza; **no tiene
  autenticación**. No la expongas directamente a internet sin agregar
  autenticación.
- Todo es local: tus datos viven únicamente en el archivo de tu base de datos (y
  las búsquedas en línea solo envían el ISBN que escaneas).
