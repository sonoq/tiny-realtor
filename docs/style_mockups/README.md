# Mockups de estilo

Cuatro propuestas de estilo visual para Tiny Realtor, generadas con Python (Pillow) a partir de la
manzana de ejemplo (`data/sample_block.json`). Cada carpeta tiene la vista del juego a 600x600
(`city_600.png`), los seis niveles de edificio (`tiers.png`), un primer plano (`closeup_2x.png`) y
el script que las genera.

| Carpeta | Estilo |
|---|---|
| `a_battlegrounds/` | Hermano de Tiny Battlegrounds: pizarra oscura, paneles con remaches, cian y oro; fuera del radio la ciudad queda gris, como miniaturas sin pintar |
| `b_cozy/` | Diorama acogedor: maqueta flotante pastel, terracota, tarde mediterránea, mucha vida en la calle |
| `c_neon/` | Ciudad nocturna de neón: miles de ventanas encendidas, lo tuyo brilla en dorado, oficina magenta |
| `d_tabletop/` | Juego de mesa de juguete: contornos gruesos, colores planos, lo tuyo en rojo con peana y bandera |

Son maquetas, no el juego: algunas parcelas de la muestra se cambiaron para componer la imagen.
`.gdignore` evita que Godot importe esta carpeta.
