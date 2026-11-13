# Tiny Tycoon Inmobiliario: estudio de viabilidad

> Informe de viabilidad anterior al diseño, copiado tal cual. Donde no coincida con `docs/DESIGN.md` (por ejemplo, el almacén de datos propio), manda `DESIGN.md`. Los ficheros que cita están en `docs/prototype/`.

*Juego idle de inversión inmobiliaria sobre el mundo real, en una ventanita de 600x600 en la esquina del escritorio, como Tiny Battlegrounds.*

## 1. Veredicto

**Sí es viable.** El prototipo genera en un segundo las parcelas de 16 manzanas del Eixample y un dibujo isométrico en pixel art hecho solo con matemáticas.

Lo difícil no es dibujar. Lo difícil es esto:

1. **Google Maps no se puede usar.** Sus condiciones prohíben sacar la forma de los edificios y guardarla. Hay que usar **OpenStreetMap** (gratis y legal, con atribución).
2. **Los datos reales son desiguales.** Hay ciudades con edificios sin alturas o con calles curvas, así que el juego tiene que inventar con buen criterio lo que falte.
3. **Para venderlo en Steam hace falta un pequeño almacén de datos propio.** El servidor público de OpenStreetMap no aguanta miles de jugadores. La solución es barata, pero hay que montarla.

## 2. De dónde sacar el mapa

| Fuente | ¿Juego comercial? | Coste | ¿Guardar en disco? | Nota |
|---|---|---|---|---|
| Google Maps | **No.** Sus condiciones (§3.2.3) prohíben extraer contenido, guardarlo en caché, crear datos a partir de sus mapas y mezclarlo con otros mapas | De pago | No | Descartado |
| **OpenStreetMap** | **Sí** (licencia ODbL) | Gratis | Sí | Calles, edificios, plantas, usos del suelo, parques, metro... |
| Overpass API (pedir trocitos de OSM) | Sí | Gratis | Sí | Bien para desarrollar y para una beta; **no para el juego publicado** |
| Extractos de OSM (Geofabrik) | Sí | Gratis | Sí | Para "precocinar" ciudades y subirlas a un almacén propio |
| Overture Maps | Sí (ODbL) | Gratis | Sí | A veces trae alturas que OSM no tiene; para procesar por lotes |
| Mapbox | Muy limitado | De pago | Con límites | No encaja |
| Catastro de España (INSPIRE) | Reutilización abierta citando la fuente (falta leer la licencia antes de lanzar) | Gratis | Sí | **Parcelas reales**, plantas, uso, año y nº de viviendas. Solo España (sin País Vasco ni Navarra) |

**Qué implica la licencia de OSM en Steam:**
- Hay que poner "© OpenStreetMap contributors" visible en el juego, en los créditos y en la página de Steam.
- El código y las imágenes del juego siguen siendo tuyos y cerrados.
- Las ciudades precocinadas que distribuyas deben publicarse también con licencia ODbL (por ejemplo, en GitHub). Es fácil de cumplir.

**Recomendación:** OpenStreetMap en dos fases:
1. **Prototipo y beta:** el juego consulta Overpass una vez por zona y la guarda para siempre.
2. **Lanzamiento:** una herramienta propia precocina ciudades desde los extractos y las deja en un almacenamiento barato (por ejemplo, Cloudflare R2, que no cobra por descargas).

El Catastro sirve como capa extra para España ("este edificio tiene 24 pisos que alquilar").

## 3. Cómo funcionaría (de mapa a pixel art)

1. **Pedir la zona:** unos 500 x 500 m con calles, edificios, parques y usos del suelo.
2. **Pasar a metros y enderezar:** se gira el barrio para que las calles queden alineadas con la cuadrícula isométrica (el Eixample sale girado unos 45°).
3. **Calles:** cada calle recibe su anchura, aceras, pasos de cebra y árboles.
4. **Parcelas:** cada edificio mapeado es una parcela. Si una manzana está vacía, se trocea con matemáticas en parcelas de 300 a 750 m². En España, el Catastro da directamente las parcelas reales.
5. **Alturas:** se usan las plantas reales. Si faltan, se inventa un valor creíble con una fórmula fija, que da siempre el mismo resultado.
6. **Rejilla de juego:** casillas de 4 x 4 m para hacer clic y para la lógica.
7. **Dibujo:** se levanta cada edificio, se sombrean las paredes, se añaden ventanas, azoteas y árboles, y se amplía x2 sin suavizar para que el píxel quede nítido.
8. **Guardar:** todo va a un fichero por zona (`block_saved.json`) junto con tu progreso. Nunca se regenera.

**¿Dentro de Godot?** Sí: Godot puede descargar datos, leer JSON y hacer la geometría necesaria. Para empezar, todo dentro de Godot; para el lanzamiento, los pasos 1 a 6 pasan a una herramienta de precocinado.

**Medidas del prototipo:** 4 x 4 manzanas (~530 x 530 m), 298 parcelas, fichero guardado de 122 KB, 0,4 s para preparar y 1 s para dibujar (en Python). En la ventana de 600x600 cabe una manzana y media de cerca. El rendimiento no es un problema.

## 4. Ideas de diseño

- **Bucle básico:** cada finca da alquiler por minuto, también con el juego cerrado (con tope). Con lo ganado compras la finca de al lado o subes de nivel.
- **Niveles:** Solar → Casa → Urbanización (une 2-4 parcelas vecinas) → Bloque de pisos → Torre → Rascacielos. El tamaño real de la parcela limita lo que puedes construir.
- **Normativa:** la altura real del barrio fija el máximo permitido; superarlo exige comprar una **recalificación** cara.
- **Valor del barrio con datos reales:** parques, metro, colegios y tiendas cerca suben el alquiler; mar o monumentos dan extra.
- **Tipos de edificio:** viviendas = ingreso estable; locales = más dinero pero pueden quedar vacíos; hotel = depende de la temporada.
- **Esquinas y manzanas completas:** los chaflanes pagan más. Comprar una manzana entera convierte el patio en jardín o piscina y multiplica todo.
- **Eventos de un clic:** inquilino moroso, inspección, reforma urgente, oferta de compra. Más adelante, un "administrador de fincas" los automatiza.
- **Expansión real:** manzanas vecinas → barrio → otras ciudades que elige el jugador ("tengo medio Eixample y estoy entrando en mi barrio").
- **Prestigio:** "sales a bolsa", ganas multiplicadores permanentes y empiezas en otra ciudad.
- **Ambiente:** día y noche con ventanas que se encienden, y paleta de colores según el país.
- **Se puede inventar sin problema:** interiores, inquilinos, precios, alturas que falten y fachadas. Solo conviene que sean reales las calles y las parcelas.

## 5. Riesgos y primer paso

**Riesgos:**
- Calidad desigual de los datos fuera de Europa y Japón.
- Geometría desordenada en cascos antiguos, edificios gigantes y patios.
- Licencias: Google no; OSM sí, con atribución; el Catastro, revisarlo antes.
- No conviene depender del servidor público en Steam.
- Se ve pequeño en 600x600: hacen falta zoom y desplazamiento.
- Edificios famosos: mostrarlos sin logotipos ni marcas.
- Ambición: empezar por un barrio, no por el mundo entero.

**Primer hito (1-2 fines de semana):**
1. Proyecto Godot con la misma ventana sin bordes de 600x600.
2. Una sola zona fija cargada desde un fichero guardado.
3. Dibujo isométrico con polígonos.
4. Clic en una finca → comprar → genera alquiler → subir de nivel → guardar partida.
5. Las descargas reales quedan para el hito 2, y el almacén propio para el hito 3.

## 6. Nota sobre el prototipo

La red de la sesión en la nube bloqueaba OpenStreetMap y el Catastro. Por eso los datos son **una muestra hecha a mano** con el mismo formato que devuelve Overpass. Imita la cuadrícula real del Eixample (manzanas de 113 m con chaflanes, calles de 20 m, giro de 45°), pero los edificios concretos son inventados.

Consulta real para usar con conexión normal (enviar a `https://overpass-api.de/api/interpreter`):

```
[out:json][timeout:50];
( way["building"](41.3895,2.1600,41.3935,2.1660);
  way["highway"](41.3895,2.1600,41.3935,2.1660);
  way["landuse"](41.3895,2.1600,41.3935,2.1660);
  way["leisure"](41.3895,2.1600,41.3935,2.1660); );
out body geom;
```

Ficheros: `iso_overview.png`, `iso_window_600.png`, `plots_map.png`, `data/block_saved.json` y los scripts de `tools/`.
