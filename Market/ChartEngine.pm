package Market::ChartEngine;
use strict;
use warnings;

use lib '.';

use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;

# ─── Constructor ──────────────────────────────────────────────────────────────
# Input (args con nombre):
#   market_data  => objeto Market::MarketData
#   indicators   => objeto Market::IndicatorManager
#   canvas_price => Tk::Canvas del panel de precios
#   canvas_atr   => Tk::Canvas del panel ATR
#   canvas_w     => ancho de los canvas en píxeles
#   canvas_price_h => alto del canvas de precios
#   canvas_atr_h   => alto del canvas ATR
#   tf_buttons   => hashref de widgets Tk para botones de timeframe (opcional)
sub new {
    my ($class, %args) = @_;

    my $self = {
        # Referencias externas
        market_data  => $args{market_data},
        indicators   => $args{indicators},
        canvas_price => $args{canvas_price},
        canvas_atr   => $args{canvas_atr},

        # Dimensiones
        canvas_w       => $args{canvas_w}       // 800,
        canvas_price_h => $args{canvas_price_h} // 400,
        canvas_atr_h   => $args{canvas_atr_h}   // 120,
        margin_right   => 70,
        margin_bottom  => 20,

        # Estado de la vista
        visible_bars  => $args{visible_bars} // 100,
        offset        => 0,      # índice de la primera vela visible
        y_min_manual  => undef,  # undef = zoom automático
        y_max_manual  => undef,
        y_drag_start  => undef,  # para drag vertical

        # Estado del render
        _render_pending => 0,

        # Paneles (se instancian en _init_panels)
        price_panel => undef,
        atr_panel   => undef,
        scale_price => undef,
        scale_atr   => undef,

        # Widgets opcionales
        tf_buttons => $args{tf_buttons} // {},
    };

    bless $self, $class;
    $self->_init_panels();
    $self->bind_events();
    $self->reset_view();
    return $self;
}

# ─── _init_panels ─────────────────────────────────────────────────────────────
# Instancia los paneles y sus escalas iniciales.
# Output: ninguno
sub _init_panels {
    my ($self) = @_;

    # Escala compartida horizontalmente (offset y visible_bars comunes)
    $self->{scale_price} = Market::Panels::Scales->new(
        canvas_width  => $self->{canvas_w},
        canvas_height => $self->{canvas_price_h},
        margin_right  => $self->{margin_right},
        margin_bottom => $self->{margin_bottom},
        visible_bars  => $self->{visible_bars},
        offset        => $self->{offset},
        y_min         => 0,
        y_max         => 1,
    );

    $self->{scale_atr} = Market::Panels::Scales->new(
        canvas_width  => $self->{canvas_w},
        canvas_height => $self->{canvas_atr_h},
        margin_right  => $self->{margin_right},
        margin_bottom => $self->{margin_bottom},
        visible_bars  => $self->{visible_bars},
        offset        => $self->{offset},
        y_min         => 0,
        y_max         => 1,
    );

    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas      => $self->{canvas_price},
        scale       => $self->{scale_price},
        market_data => $self->{market_data},
        indicators  => $self->{indicators},
    );

    $self->{atr_panel} = Market::Panels::ATRPanel->new(
        canvas => $self->{canvas_atr},
        scale  => $self->{scale_atr},
    );
}

# ─── compute_window ───────────────────────────────────────────────────────────
# Calcula qué porción de datos es visible según offset y visible_bars.
# Ajusta offset si está fuera de rango.
# Output: ($start, $end) índices del slice visible
sub compute_window {
    my ($self) = @_;
    my $size = $self->{market_data}->size();
    return (0, 0) if $size == 0;

    my $end   = $size - 1;
    my $start = $end - $self->{visible_bars} + 1;
    $start    = 0 if $start < 0;

    # Aplicar offset de scroll (negativo = ir al pasado)
    $start += $self->{offset};
    $end   += $self->{offset};

    # Clamp: no salir del rango de datos
    if ($end >= $size) {
        $end   = $size - 1;
        $start = $end - $self->{visible_bars} + 1;
        $start = 0 if $start < 0;
    }
    if ($start < 0) {
        $start = 0;
        $end   = $start + $self->{visible_bars} - 1;
        $end   = $size - 1 if $end >= $size;
    }

    return ($start, $end);
}

# ─── round ────────────────────────────────────────────────────────────────────
sub round {
    my ($self, $value, $dec) = @_;
    $dec //= 2;
    return sprintf("%.${dec}f", $value) + 0;
}

# ─── request_render ───────────────────────────────────────────────────────────
# Solicita un render diferido usando after(0).
# Evita renderizados redundantes si se disparan múltiples eventos seguidos.
# Output: ninguno
sub request_render {
    my ($self) = @_;
    return if $self->{_render_pending};
    $self->{_render_pending} = 1;
    $self->{canvas_price}->after(0, sub {
        $self->{_render_pending} = 0;
        $self->render();
    });
}

# ─── render ───────────────────────────────────────────────────────────────────
# Loop principal de render. Coordina todos los paneles.
# Output: ninguno
sub render {
    my ($self) = @_;
    my $size = $self->{market_data}->size();
    return if $size == 0;

    # 1. Calcular ventana visible
    my ($start, $end) = $self->compute_window();

    # 2. Obtener slices de datos
    my $price_data = $self->{market_data}->get_slice($start, $end);
    my $atr_values = $self->{indicators}->slice_array('ATR', $start, $end);

    # 3. Actualizar escala horizontal (compartida)
    $self->{scale_price}{visible_bars} = $self->{visible_bars};
    $self->{scale_price}{offset}       = $start;
    $self->{scale_atr}{visible_bars}   = $self->{visible_bars};
    $self->{scale_atr}{offset}         = $start;

    # 4. Calcular rango Y del panel de precios
    my ($y_min, $y_max);
    if (defined $self->{y_min_manual} && defined $self->{y_max_manual}) {
        # Zoom vertical manual activo
        $y_min = $self->{y_min_manual};
        $y_max = $self->{y_max_manual};
    } else {
        # Zoom vertical automático
        ($y_min, $y_max) = $self->{price_panel}->get_y_range($price_data);
    }
    $self->{scale_price}{y_min} = $y_min;
    $self->{scale_price}{y_max} = $y_max;

    # 5. Calcular rango Y del panel ATR (siempre automático)
    my ($atr_min, $atr_max) = $self->{atr_panel}->get_y_range($atr_values);
    $self->{scale_atr}{y_min} = $atr_min;
    $self->{scale_atr}{y_max} = $atr_max;

    # 6. Renderizar paneles
    $self->{price_panel}->render(
        $self->{canvas_price},
        $price_data,
        $self->{scale_price},
    );

    $self->{atr_panel}->render(
        $self->{canvas_atr},
        $atr_values,
        $self->{scale_atr},
    );

    # 7. Dibujar eje de tiempo (solo en panel de precios)
    my $timestamps = $self->compute_intraday_labels();
    $self->{price_panel}->draw_time_axis($self->{canvas_price}, $timestamps);
}

# ─── _bind_all_canvas ─────────────────────────────────────────────────────────
# Asocia un mismo callback a múltiples canvas.
# Input:  $event    => string evento Tk (ej: '<Motion>')
#         $callback => subrutina
# Output: ninguno
sub _bind_all_canvas {
    my ($self, $event, $callback) = @_;
    $self->{canvas_price}->bind($event, $callback);
    $self->{canvas_atr}->bind($event, $callback);
}

# ─── bind_events ──────────────────────────────────────────────────────────────
# Registra todos los eventos de mouse y teclado.
# Output: ninguno
sub bind_events {
    my ($self) = @_;

    # Scroll horizontal (arrastre con botón izquierdo)
    my $drag_start_x = undef;
    my $drag_start_offset = undef;

    $self->_bind_all_canvas('<ButtonPress-1>', sub {
        my ($canvas, $event) = @_;
        $drag_start_x      = $event->x;
        $drag_start_offset = $self->{offset};
    });

    $self->_bind_all_canvas('<B1-Motion>', sub {
        my ($canvas, $event) = @_;
        return unless defined $drag_start_x;
        my $scale   = $self->{scale_price};
        my $bar_w   = $scale->_bar_width();
        my $delta_x = $event->x - $drag_start_x;
        my $delta_bars = int($delta_x / $bar_w);
        $self->{offset} = $drag_start_offset - $delta_bars;
        $self->request_render();
    });

    $self->_bind_all_canvas('<ButtonRelease-1>', sub {
        $drag_start_x = undef;
    });

    # Zoom horizontal con rueda del mouse
    $self->_bind_all_canvas('<MouseWheel>', sub {
        my ($canvas, $event) = @_;
        my $delta = $event->Delta > 0 ? -1 : 1;
        $self->_horizontal_zoom($delta);
    });

    # Linux: botones 4 y 5 para la rueda
    $self->_bind_all_canvas('<Button-4>', sub { $self->_horizontal_zoom(-1); });
    $self->_bind_all_canvas('<Button-5>', sub { $self->_horizontal_zoom(1);  });

    # Zoom vertical en barra de precios (botón derecho + arrastre)
    $self->{canvas_price}->bind('<ButtonPress-3>', sub {
        my ($canvas, $event) = @_;
        $self->{y_drag_start} = $event->y;
    });

    $self->{canvas_price}->bind('<B3-Motion>', sub {
        my ($canvas, $event) = @_;
        $self->_vertical_drag($event->y - $self->{y_drag_start});
        $self->{y_drag_start} = $event->y;
    });

    # Doble click derecho: reset zoom vertical a automático
    $self->{canvas_price}->bind('<Double-ButtonPress-3>', sub {
        $self->{y_min_manual} = undef;
        $self->{y_max_manual} = undef;
        $self->request_render();
    });

    # Movimiento del mouse: crosshair
    $self->_bind_all_canvas('<Motion>', sub {
        my ($canvas, $event) = @_;
        $self->_on_mouse_move($event);
    });

    # Teclas de timeframe
    $self->{canvas_price}->bind('<Key-1>', sub { $self->set_timeframe('1');  });
    $self->{canvas_price}->bind('<Key-5>', sub { $self->set_timeframe('5');  });
    $self->{canvas_price}->bind('<Key-6>', sub { $self->set_timeframe('15'); });

    # Tecla R: reset vista
    $self->{canvas_price}->bind('<r>', sub { $self->reset_view(); });

    $self->{canvas_price}->focus();
}

# ─── _horizontal_zoom ─────────────────────────────────────────────────────────
# Controla el zoom horizontal (cantidad de velas visibles).
# Input:  $delta => 1 (zoom out, más velas) o -1 (zoom in, menos velas)
# Output: ninguno
sub _horizontal_zoom {
    my ($self, $delta) = @_;
    my $factor       = $delta > 0 ? 1.15 : 0.87;
    my $new_bars     = int($self->{visible_bars} * $factor);
    my $size         = $self->{market_data}->size();

    # Límites: mínimo 10 velas, máximo el total de datos
    $new_bars = 10     if $new_bars < 10;
    $new_bars = $size  if $new_bars > $size && $size > 0;

    $self->{visible_bars} = $new_bars;
    $self->request_render();
}

# ─── _vertical_drag ───────────────────────────────────────────────────────────
# Controla el desplazamiento vertical manual arrastrando la barra de precios.
# Activa el modo de zoom manual si estaba en automático.
# Input:  $dy => delta en píxeles (positivo = arrastrar hacia abajo)
# Output: ninguno
sub _vertical_drag {
    my ($self, $dy) = @_;
    my $scale = $self->{scale_price};

    # Si estaba en automático, inicializar con el rango actual
    unless (defined $self->{y_min_manual}) {
        $self->{y_min_manual} = $scale->{y_min};
        $self->{y_max_manual} = $scale->{y_max};
    }

    # Convertir delta de píxeles a delta de precio
    my $range       = $self->{y_max_manual} - $self->{y_min_manual};
    my $price_delta = ($dy / $scale->_plot_height()) * $range;

    $self->{y_min_manual} += $price_delta;
    $self->{y_max_manual} += $price_delta;
    $self->request_render();
}

# ─── _vertical_zoom ───────────────────────────────────────────────────────────
# Controla el zoom vertical escalando el rango de precios.
# Input:  $factor => >1 expande el rango, <1 lo comprime
# Output: ninguno
sub _vertical_zoom {
    my ($self, $factor) = @_;
    my $scale = $self->{scale_price};

    unless (defined $self->{y_min_manual}) {
        $self->{y_min_manual} = $scale->{y_min};
        $self->{y_max_manual} = $scale->{y_max};
    }

    my $mid   = ($self->{y_min_manual} + $self->{y_max_manual}) / 2;
    my $range = ($self->{y_max_manual} - $self->{y_min_manual}) * $factor / 2;

    $self->{y_min_manual} = $mid - $range;
    $self->{y_max_manual} = $mid + $range;
    $self->request_render();
}

# ─── _on_mouse_move ───────────────────────────────────────────────────────────
# Maneja el movimiento del mouse: actualiza el crosshair en todos los paneles.
# Input:  $event => evento Tk con x, y
# Output: ninguno
sub _on_mouse_move {
    my ($self, $event) = @_;
    my $x = $event->x;
    my $y = $event->y;
    $self->_draw_crosshair_all($x, $y);
}

# ─── _draw_crosshair_all ──────────────────────────────────────────────────────
# Dibuja el crosshair sincronizado en todos los paneles.
# X es común (misma vela), Y es local a cada panel.
# Input:  $x => píxel X (sincronizado)
#         $y => píxel Y del panel que recibió el evento
# Output: ninguno
sub _draw_crosshair_all {
    my ($self, $x, $y) = @_;

    # PricePanel recibe X e Y real del mouse
    $self->{price_panel}->draw_crosshair($x, $y);

    # ATRPanel recibe la misma X pero Y centrado en su panel
    my $atr_h  = $self->{canvas_atr_h} / 2;
    $self->{atr_panel}->draw_crosshair($x, $atr_h);
}

# ─── set_timeframe ────────────────────────────────────────────────────────────
# Cambia la temporalidad activa y reconstruye todo.
# Input:  $tf => '1', '5' o '15'
# Output: ninguno
sub set_timeframe {
    my ($self, $tf) = @_;

    $self->{market_data}->set_timeframe($tf);
    $self->{indicators}->reset_all();
    $self->{indicators}->update_last($self->{market_data});

    # Reset de vista al cambiar timeframe
    $self->reset_view();
}

# ─── reset_view ───────────────────────────────────────────────────────────────
# Resetea zoom y desplazamiento al estado inicial (última vela visible).
# Output: ninguno
sub reset_view {
    my ($self) = @_;
    $self->{offset}       = 0;
    $self->{y_min_manual} = undef;
    $self->{y_max_manual} = undef;
    $self->{visible_bars} = 100;
    $self->request_render();
}

# ─── compute_intraday_labels ──────────────────────────────────────────────────
# Calcula etiquetas de tiempo para el eje X espaciadas uniformemente.
# Output: arrayref de [ $index, $label_string ]
sub compute_intraday_labels {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my $visible       = $end - $start + 1;
    my $n_labels      = 6;
    my $step          = int($visible / $n_labels) || 1;
    my @labels;

    for (my $i = $start; $i <= $end; $i += $step) {
        my $ts = $self->{market_data}->get_timestamp($i);
        next unless defined $ts;

        # Formatear timestamp a HH:MM
        # Asume que $ts es epoch Unix
        my @t   = localtime($ts);
        my $label = sprintf("%02d:%02d", $t[2], $t[1]);
        push @labels, [$i, $label];
    }

    return \@labels;
}

# ─── get_all_timestamps ───────────────────────────────────────────────────────
# Devuelve todos los timestamps del slice visible.
# Output: arrayref de [ $index, $timestamp ]
sub get_all_timestamps {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my @result;

    for my $i ($start .. $end) {
        my $ts = $self->{market_data}->get_timestamp($i);
        push @result, [$i, $ts] if defined $ts;
    }

    return \@result;
}

1;