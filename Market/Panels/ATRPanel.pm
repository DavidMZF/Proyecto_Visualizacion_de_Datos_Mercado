package Market::Panels::ATRPanel;
use strict;
use warnings;

# ─── Constructor ──────────────────────────────────────────────────────────────
# Input (args con nombre):
#   canvas      => widget Tk::Canvas del panel ATR
#   scale       => objeto Market::Panels::Scales (compartido horizontalmente
#                  con PricePanel, pero con y_min/y_max propios del ATR)
#   color_line  => color de la línea ATR (default azul TradingView)
#   color_cross => color del crosshair
sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas      => $args{canvas},
        scale       => $args{scale},

        # Colores
        color_line  => $args{color_line}  // '#2962ff',   # azul TradingView
        color_cross => $args{color_cross} // '#ffffff',
        color_label => $args{color_label} // '#131722',

        # Objetos crosshair (creados una vez, movidos en O(1))
        _ch_hline => undef,
        _ch_vline => undef,
        _ch_box   => undef,
        _ch_label => undef,
    };
    bless $self, $class;
    $self->_init_crosshair();
    return $self;
}

# ─── _init_crosshair ──────────────────────────────────────────────────────────
# Crea los objetos gráficos del crosshair en el canvas ATR (ocultos al inicio).
# Misma estrategia O(1) que PricePanel.
# Output: ninguno
sub _init_crosshair {
    my ($self) = @_;
    my $c = $self->{canvas};

    $self->{_ch_hline} = $c->createLine(
        0, 0, 0, 0,
        -fill  => $self->{color_cross},
        -dash  => [4, 4],
        -width => 1,
        -state => 'hidden',
        -tags  => ['crosshair'],
    );

    $self->{_ch_vline} = $c->createLine(
        0, 0, 0, 0,
        -fill  => $self->{color_cross},
        -dash  => [4, 4],
        -width => 1,
        -state => 'hidden',
        -tags  => ['crosshair'],
    );

    $self->{_ch_box} = $c->createRectangle(
        0, 0, 0, 0,
        -fill    => $self->{color_cross},
        -outline => $self->{color_cross},
        -state   => 'hidden',
        -tags    => ['crosshair'],
    );

    $self->{_ch_label} = $c->createText(
        0, 0,
        -text   => '',
        -fill   => $self->{color_label},
        -font   => ['monospace', 8, 'bold'],
        -anchor => 'w',
        -state  => 'hidden',
        -tags   => ['crosshair'],
    );
}

# ─── get_y_range ──────────────────────────────────────────────────────────────
# Calcula el rango vertical (min, max) de los valores ATR visibles.
# Ignora undefs (velas sin ATR calculado aún).
# Input:  $values => arrayref de floats o undef
# Output: ($y_min, $y_max)
sub get_y_range {
    my ($self, $values) = @_;

    my @valid = grep { defined $_ } @$values;
    return (0, 1) unless @valid;

    my $min =  9**9**9;
    my $max = -9**9**9;
    for my $v (@valid) {
        $min = $v if $v < $min;
        $max = $v if $v > $max;
    }

    # Padding del 10% para que la línea no toque los bordes del panel
    my $padding = ($max - $min) * 0.10;
    $padding    = 0.0001 if $padding == 0;

    return ($min - $padding, $max + $padding);
}

# ─── set_scale ────────────────────────────────────────────────────────────────
# Asigna o reemplaza el objeto Scales del panel.
# Input:  $scale => objeto Market::Panels::Scales
# Output: ninguno
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# ─── render ───────────────────────────────────────────────────────────────────
# Dibuja la línea del ATR como serie de segmentos conectados.
# Salta undefs (no dibuja donde no hay ATR calculado).
# Input:  $canvas => Tk::Canvas
#         $values => arrayref de valores ATR visibles (slice)
#         $scale  => objeto Market::Panels::Scales
# Output: ninguno
sub render {
    my ($self, $canvas, $values, $scale) = @_;

    $canvas->delete('atr_line');
    $canvas->delete('scale_y');
    $canvas->delete('last_atr');

    my $start_index = $scale->{offset};
    my @points;     # acumula segmentos válidos

    for my $i (0 .. $#$values) {
        my $val = $values->[$i];

        # Saltar velas sin ATR calculado
        unless (defined $val) {
            # Si había puntos acumulados, dibujar el segmento y resetear
            if (@points >= 4) {
                $canvas->createLine(
                    @points,
                    -fill  => $self->{color_line},
                    -width => 1.5,
                    -tags  => ['atr_line'],
                );
            }
            @points = ();
            next;
        }

        my $abs_idx = $start_index + $i;
        my $x       = $scale->index_to_center_x($abs_idx);
        my $y       = $scale->value_to_y($val);

        push @points, $x, $y;
    }

    # Dibujar segmento final si quedaron puntos
    if (@points >= 4) {
        $canvas->createLine(
            @points,
            -fill  => $self->{color_line},
            -width => 1.5,
            -tags  => ['atr_line'],
        );
    }

    # Escala Y propia del panel ATR
    $scale->_draw_y_scale($canvas);

    # Último valor visible destacado
    $self->render_last_visible_value($canvas, $values, $scale);
}

# ─── render_last_visible_value ────────────────────────────────────────────────
# Muestra el último valor ATR válido en el eje Y del panel.
# Input:  $canvas, $values (slice), $scale
# Output: ninguno
sub render_last_visible_value {
    my ($self, $canvas, $values, $scale) = @_;

    # Buscar el último valor definido del slice
    my $last_val = undef;
    for my $v (reverse @$values) {
        if (defined $v) { $last_val = $v; last; }
    }
    return unless defined $last_val;

    my $y       = $scale->value_to_y($last_val);
    my $x_start = $scale->_plot_width();

    # Línea punteada horizontal hasta el eje Y
    $canvas->createLine(
        0, $y, $x_start, $y,
        -fill  => $self->{color_line},
        -dash  => [3, 3],
        -width => 1,
        -tags  => ['last_atr'],
    );

    # Fondo de la etiqueta
    $canvas->createRectangle(
        $x_start, $y - 9,
        $scale->{canvas_width}, $y + 9,
        -fill    => $self->{color_line},
        -outline => $self->{color_line},
        -tags    => ['last_atr'],
    );

    # Valor ATR en texto
    $canvas->createText(
        $x_start + 4, $y,
        -text   => sprintf("%.4f", $last_val),
        -fill   => $self->{color_label},
        -font   => ['monospace', 8, 'bold'],
        -anchor => 'w',
        -tags   => ['last_atr'],
    );
}

# ─── draw_crosshair ───────────────────────────────────────────────────────────
# Mueve el crosshair sincronizado con PricePanel.
# La coordenada X viene de ChartEngine (sincronizada entre paneles).
# La coordenada Y es local a este panel.
# Input:  $x => píxel X sincronizado con todos los paneles
#         $y => píxel Y local a este canvas
# Output: ninguno
sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};

    # Línea horizontal
    $c->coords($self->{_ch_hline}, 0, $y, $scale->plot_width(), $y);
    $c->itemconfigure($self->{_ch_hline}, -state => 'normal');

    # Línea vertical (misma X que PricePanel)
    $c->coords($self->{_ch_vline}, $x, 0, $x, $scale->plot_height());
    $c->itemconfigure($self->{_ch_vline}, -state => 'normal');

    # Etiqueta del valor ATR bajo el cursor
    my $atr_val  = $scale->y_to_value($y);
    my $x_start  = $scale->plot_width();

    $c->coords($self->{_ch_box},
        $x_start, $y - 9,
        $scale->{canvas_width}, $y + 9,
    );
    $c->itemconfigure($self->{_ch_box}, -state => 'normal');

    $c->coords($self->{_ch_label}, $x_start + 4, $y);
    $c->itemconfigure($self->{_ch_label},
        -text  => sprintf("%.4f", $atr_val),
        -state => 'normal',
    );

    $c->raise('crosshair');
}

1;
