# Proyecto: Visualización de Datos de Mercado (Perl + Tk)

Este repositorio implementa un **visor de mercado tipo TradingView** (tema oscuro) que:

- Carga velas **OHLCV** desde un CSV (1 minuto).
- Construye temporalidades agregadas **5m** y **15m**.
- Calcula el indicador **ATR (Average True Range)**.
- Renderiza un gráfico interactivo con **velas** (panel superior) y **ATR** (panel inferior).

El punto de entrada principal es `market.pl`.

---

## Estructura del repo

- `market.pl`: entrypoint (carga CSV → calcula indicadores → abre GUI Tk).
- `data/2026_03.csv`: dataset de ejemplo.
- `Market/MarketData.pm`: almacenamiento de velas y construcción de temporalidades.
- `Market/IndicatorManager.pm`: registro/actualización/reset de indicadores.
- `Market/Indicators/ATR.pm`: cálculo incremental del ATR.
- `Market/ChartEngine.pm`: motor de render + interacción (zoom/scroll/crosshair/timeframe).
- `Market/Panels/PricePanel.pm`: render de velas + escala Y + último precio + crosshair.
- `Market/Panels/ATRPanel.pm`: render línea ATR + escala Y + último valor + crosshair.
- `Market/Panels/Scales.pm`: conversiones índice↔x y valor↔y y dibujo de escalas.

---

## Formato del CSV

Se espera un CSV con encabezado y columnas:

```csv
time,open,high,low,close,Volume
2026-04-01T00:00:00-05:00,24013.75,24013.75,24007.5,24009.25,67
...
```

- `time` debe estar en formato ISO-8601 con zona horaria (se parsea con `Time::Moment`).
- `open/high/low/close` deben ser numéricos.

El archivo por defecto está configurado en `market.pl` con la variable `$CSV_FILE`.

---

## Cómo funciona (pipeline)

1. **Carga CSV** (`market.pl`):
   - Parsea `time` → epoch.
   - Inserta velas 1m en `Market::MarketData`.
2. **Construcción de temporalidades** (`Market::MarketData`):
   - Agrega velas de 1m en bloques de 5 y 15.
3. **Indicadores** (`Market::IndicatorManager` + `Market::Indicators::ATR`):
   - ATR usa True Range y suavizado de Wilder.
   - Se recalcula incrementalmente (solo velas nuevas).
4. **Render + interacción** (`Market::ChartEngine` + Panels):
   - Calcula una ventana visible `[start..end]`.
   - Renderiza velas y ATR solo para esa ventana.

---

## Requisitos

- Perl 5
- Módulos Perl:
  - `Tk` (GUI)
  - `Time::Moment` (parseo de timestamps)

### En Windows

En PowerShell, si `perl` no está disponible, hay dos caminos:

- **Usar WSL (recomendado)**: ejecutar con `wsl perl ...`.
- **Instalar Perl nativo** (p.ej. Strawberry Perl) y luego instalar módulos `Tk` y `Time::Moment`.

### En WSL (Ubuntu/Debian)

Instalación típica:

```bash
sudo apt update
sudo apt install -y perl perl-tk libtime-moment-perl
```

> Nota GUI: Para ver la ventana Tk desde WSL necesitas soporte gráfico (por ejemplo **WSLg** en Windows 11) o un **X Server** en Windows.

---

## Ejecutar

Desde la raíz del repo:

- GUI (entrypoint original):

```bash
perl market.pl
```

- Alternativa (wrapper):

```bash
perl Tareas/main.pl
```

Si estás usando WSL:

```bash
wsl perl market.pl
# o
wsl perl Tareas/main.pl
```

---

## Controles (UI)

- **Rueda del mouse**: zoom horizontal (más/menos velas visibles).
- **Drag izquierdo**: scroll horizontal (hacia pasado/futuro).
- **Drag derecho (panel precio)**: pan vertical (rango Y manual).
- **Ctrl + rueda** (panel precio): zoom vertical.
- **Doble click derecho**: volver a autoscale.
- **Teclas**:
  - `1` → 1m
  - `5` → 5m
  - `6` → 15m
  - `r` → reset de vista

---

## Cambiar de archivo CSV

Edita en `market.pl`:

- `$CSV_FILE` para apuntar a otro CSV.




