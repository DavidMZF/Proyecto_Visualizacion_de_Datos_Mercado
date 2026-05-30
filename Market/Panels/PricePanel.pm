package Market::Panels::PricePanel;
use strict;
use warnings;

# ─── Constructor ──────────────────────────────────────────────────────────────
# Input (args con nombre):
#   canvas        => widget Tk::Canvas del panel de precios
#   scale         => objeto Market::Panels::Scales
#   market_data   => objeto Market::MarketData
#   indicators    => objeto Market::IndicatorManager
# Colores por defecto estilo TradingView oscuro
sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas      => $args{canvas},
        scale       => $args{scale},
        market_data => $args{market_data},
        indicators  => $args{indicators},

        # Colores
        color_bull      => $args{color_bull}      // '#26a69a',  # vela alcista (verde)
        color_bear      => $args{color_bear}      // '#ef5350',  # vela bajista (rojo)
        color_wick      => $args{color_wick}      // '#888888',  # mechas
        color_crosshair => $args{color_crosshair} // '#ffffff',  # crosshair
        color_price_tag => $args{color_price_tag} // '#131722',  # fondo etiqueta precio

        # Objetos del crosshair (IDs de canvas Tk)
        _ch_hline => undef,   # línea horizontal
        _ch_vline => undef,   # línea vertical
        _ch_label => undef,   # etiqueta de precio en eje Y
        _ch_box   => undef,   # fondo de la etiqueta
    };
    bless $self, $class;
    $self->_init_crosshair_objects();
    return $self;
}

# ─── _init_crosshair_objects ──────────────────────────────────────────────────
# Crea los elementos gráficos del crosshair en el canvas (ocultos inicialmente).
# Se crean una vez y se mueven/actualizan en draw_crosshair para eficiencia O(1).
# Output: ninguno
sub _init_crosshair_objects {
    my ($self) = @_;
    my $c = $self->{canvas};

    $self->{_ch_hline} = $c->createLine(
        0, 0, 0, 0,
        -fill  => $self->{color_crosshair},
        -dash  => [4, 4],
        -width => 1,
        -state => 'hidden',
        -tags  => ['crosshair'],
    );

    $self->{_ch_vline} = $c->createLine(
        0, 0, 0, 0,
        -fill  => $self->{color_crosshair},
        -dash  => [4, 4],
        -width => 1,
        -state => 'hidden',
        -tags  => ['crosshair'],
    );

    # Fondo de la etiqueta de precio (rectángulo)
    $self->{_ch_box} = $c->createRectangle(
        0, 0, 0, 0,
        -fill    => $self->{color_crosshair},
        -outline => $self->{color_crosshair},
        -state   => 'hidden',
        -tags    => ['crosshair'],
    );

    # Texto del precio bajo el cursor
    $self->{_ch_label} = $c->createText(
        0, 0,
        -text   => '',
        -fill   => $self->{color_price_tag},
        -font   => ['monospace', 8, 'bold'],
        -anchor => 'w',
        -state  => 'hidden',
        -tags   => ['crosshair'],
    );
}

# ─── round ────────────────────────────────────────────────────────────────────
# Redondeo auxiliar a N decimales.
# Input:  $value, $decimals (default 2)
# Output: float redondeado
sub round {
    my ($self, $value, $decimals) = @_;
    $decimals //= 2;
    return sprintf("%.${decimals}f", $value) + 0;
}

# ─── get_y_range ──────────────────────────────────────────────────────────────
# Calcula el rango de precios (min, max) de las velas visibles.
# Agrega un padding del 5% arriba y abajo para que las velas no toquen los bordes.
# Input:  $data => arrayref de velas (slice visible)
# Output: ($y_min, $y_max) o (0, 1) si no hay datos
sub get_y_range {
    my ($self, $data) = @_;
    return (0, 1) unless @$data;

    my $min =  9**9**9;
    my $max = -9**9**9;

    for my $candle (@$data) {
        $min = $candle->{low}  if $candle->{low}  < $min;
        $max = $candle->{high} if $candle->{high} > $max;
    }

    # Padding del 5% del rango para respiración visual
    my $padding = ($max - $min) * 0.05;
    $padding    = 0.001 if $padding == 0;   # evitar rango cero

    return ($min - $padding, $max + $padding);
}

# ─── set_scale ────────────────────────────────────────────────────────────────
# Asigna o reemplaza el objeto Scales de este panel.
# Input:  $scale => objeto Market::Panels::Scales
# Output: ninguno
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# ─── render ───────────────────────────────────────────────────────────────────
# Función principal: dibuja todas las velas visibles en el canvas.
# Borra el contenido previo (excepto crosshair) antes de redibujar.
# Input:  $canvas => Tk::Canvas
#         $data   => arrayref de velas visibles (slice)
#         $scale  => objeto Market::Panels::Scales
# Output: ninguno
sub render {
    my ($self, $canvas, $data, $scale) = @_;

    # Borrar velas anteriores (preservar crosshair)
    $canvas->delete('candle');
    $canvas->delete('scale_y');
    $canvas->delete('last_price');

    my $bar_w = $scale->bar_width();

    # Ancho del cuerpo: 80% del ancho de barra, mínimo 1px
    my $body_w = $bar_w * 0.8;
    $body_w    = 1 if $body_w < 1;

    my $start_index = $scale->{offset};

    for my $i (0 .. $#$data) {
        my $candle  = $data->[$i];
        my $abs_idx = $start_index + $i;

        # Coordenadas X
        my $cx     = $scale->index_to_center_x($abs_idx);
        my $left   = $cx - $body_w / 2;
        my $right  = $cx + $body_w / 2;

        # Coordenadas Y (precios → píxeles)
        my $y_open  = $scale->value_to_y($candle->{open});
        my $y_close = $scale->value_to_y($candle->{close});
        my $y_high  = $scale->value_to_y($candle->{high});
        my $y_low   = $scale->value_to_y($candle->{low});

        # Color según dirección
        my $is_bull = $candle->{close} >= $candle->{open};
        my $color   = $is_bull ? $self->{color_bull} : $self->{color_bear};

        # Cuerpo superior e inferior (open puede ser mayor o menor que close)
        my $body_top    = $is_bull ? $y_close : $y_open;
        my $body_bottom = $is_bull ? $y_open  : $y_close;

        # Dibujar mecha completa (high → low)
        $canvas->createLine(
            $cx, $y_high,
            $cx, $y_low,
            -fill  => $self->{color_wick},
            -width => 1,
            -tags  => ['candle'],
        );

        # Dibujar cuerpo de la vela
        # Vela doji (open == close): dibujar línea horizontal
        if (abs($body_bottom - $body_top) < 1) {
            $canvas->createLine(
                $left, $body_top,
                $right, $body_top,
                -fill  => $color,
                -width => 1,
                -tags  => ['candle'],
            );
        } else {
            $canvas->createRectangle(
                $left,  $body_top,
                $right, $body_bottom,
                -fill    => $color,
                -outline => $color,
                -tags    => ['candle'],
            );
        }
    }

    # Dibujar escala Y y último precio visible
    $scale->_draw_y_scale($canvas);
    $self->render_last_visible_price($canvas, $data, $scale);
}

# ─── render_last_visible_price ────────────────────────────────────────────────
# Dibuja una etiqueta destacada con el último precio visible en el eje Y.
# Input:  $canvas, $data (slice visible), $scale
# Output: ninguno
sub render_last_visible_price {
    my ($self, $canvas, $data, $scale) = @_;
    return unless @$data;

    my $last_close = $data->[-1]{close};
    my $y          = $scale->value_to_y($last_close);
    my $x_start    = $scale->plot_width();
    my $x_end      = $scale->{canvas_width};

    # Línea punteada horizontal hasta el eje Y
    $canvas->createLine(
        0, $y, $x_start, $y,
        -fill  => '#f0b90b',
        -dash  => [3, 3],
        -width => 1,
        -tags  => ['last_price'],
    );

    # Fondo de la etiqueta
    $canvas->createRectangle(
        $x_start, $y - 9,
        $x_end,   $y + 9,
        -fill    => '#f0b90b',
        -outline => '#f0b90b',
        -tags    => ['last_price'],
    );

    # Precio en texto
    $canvas->createText(
        $x_start + 4, $y,
        -text   => sprintf("%.2f", $last_close),
        -fill   => '#131722',
        -font   => ['monospace', 8, 'bold'],
        -anchor => 'w',
        -tags   => ['last_price'],
    );
}

# ─── draw_crosshair ───────────────────────────────────────────────────────────
# Mueve y hace visibles las líneas del crosshair en la posición del mouse.
# Operación O(1): mueve objetos existentes, no crea nuevos.
# Input:  $x, $y => coordenadas del mouse en el canvas
# Output: ninguno
sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    my $w     = $scale->{canvas_width};
    my $h     = $scale->{canvas_height};

    # Línea horizontal
    $c->coords($self->{_ch_hline}, 0, $y, $scale->plot_width(), $y);
    $c->itemconfigure($self->{_ch_hline}, -state => 'normal');

    # Línea vertical
    $c->coords($self->{_ch_vline}, $x, 0, $x, $scale->plot_height());
    $c->itemconfigure($self->{_ch_vline}, -state => 'normal');

    # Etiqueta de precio en el eje Y
    my $price    = $scale->y_to_value($y);
    my $x_start  = $scale->plot_width();

    $c->coords($self->{_ch_box},
        $x_start, $y - 9,
        $scale->{canvas_width}, $y + 9,
    );
    $c->itemconfigure($self->{_ch_box}, -state => 'normal');

    $c->coords($self->{_ch_label}, $x_start + 4, $y);
    $c->itemconfigure($self->{_ch_label},
        -text  => sprintf("%.2f", $price),
        -state => 'normal',
    );

    # Llevar crosshair al frente
    $c->raise('crosshair');
}

# ─── draw_time_axis ───────────────────────────────────────────────────────────
# Dibuja el eje temporal (eje X) con etiquetas de tiempo.
# Solo dibuja etiquetas para los índices provistos (calculados por ChartEngine).
# Input:  $canvas     => Tk::Canvas
#         $timestamps => arrayref de [ $index, $label_string ]
# Output: ninguno
sub draw_time_axis {
    my ($self, $canvas, $timestamps) = @_;
    my $scale = $self->{scale};
    my $y     = $scale->plot_height() + 2;

    $canvas->delete('time_axis');

    for my $entry (@$timestamps) {
        my ($index, $label) = @$entry;
        my $x = $scale->index_to_center_x($index);

        # Tick vertical
        $canvas->createLine(
            $x, $scale->plot_height(),
            $x, $scale->plot_height() + 4,
            -fill => '#555555',
            -tags => ['time_axis'],
        );

        # Etiqueta de tiempo
        $canvas->createText(
            $x, $y + 6,
            -text   => $label,
            -fill   => '#888888',
            -font   => ['monospace', 7],
            -anchor => 'n',
            -tags   => ['time_axis'],
        );
    }
}

1;