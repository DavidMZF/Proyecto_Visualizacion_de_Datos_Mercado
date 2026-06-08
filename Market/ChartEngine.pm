package Market::ChartEngine;
use strict;
use warnings;
use Tk qw(Ev);

use lib '.';

use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;

sub new {
    my ( $class, %args ) = @_;

    my $self = {
        market_data  => $args{market_data},
        indicators   => $args{indicators},
        canvas_price => $args{canvas_price},
        canvas_atr   => $args{canvas_atr},

        canvas_w       => $args{canvas_w}       // 800,
        canvas_price_h => $args{canvas_price_h} // 400,
        canvas_atr_h   => $args{canvas_atr_h}   // 120,
        margin_right   => $args{margin_right}   // 70,
        margin_bottom  => 20,

        visible_bars => $args{visible_bars} // 100,

        # offset: barras ocultas desde el borde derecho.
        #  0  = última vela de los datos visible en el borde derecho.
        # >0  = scroll hacia atrás (más historia a la derecha).
        # <0  = espacio vacío a la derecha (permitido para Ctrl+zoom).
        offset => 0,

        view_mode    => 'auto',
        y_min_manual => undef,
        y_max_manual => undef,
        y_drag_start => undef,

        _cursor_idx       => undef,
        _cursor_idx_float => undef,
        _cursor_x         => undef,
        _cursor_y         => undef,
        _cursor_source    => undef,
        _cursor_snap_x    => undef,

        _render_pending => 0,

        price_panel => undef,
        atr_panel   => undef,
        scale_price => undef,
        scale_atr   => undef,

        tf_buttons => $args{tf_buttons} // {},
    };

    bless $self, $class;
    $self->_init_panels();
    $self->CanvasBind_events();
    $self->reset_view();
    return $self;
}

sub _init_panels {
    my ($self) = @_;

    $self->{scale_price} = Market::Panels::Scales->new(
        canvas_width  => $self->{canvas_w},
        canvas_height => $self->{canvas_price_h},
        margin_right  => $self->{margin_right},
        margin_bottom => $self->{margin_bottom},
        visible_bars  => $self->{visible_bars},
        offset        => 0,
        y_min         => 0,
        y_max         => 1,
    );

    $self->{scale_atr} = Market::Panels::Scales->new(
        canvas_width  => $self->{canvas_w},
        canvas_height => $self->{canvas_atr_h},
        margin_right  => $self->{margin_right},
        margin_bottom => $self->{margin_bottom},
        visible_bars  => $self->{visible_bars},
        offset        => 0,
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

# ─── compute_window ──────────────────────────────────────────────────────────
# Devuelve (start, end): índices de la ventana visible.
# start puede ser < 0 y end puede ser >= size: ambos casos representan
# espacio vacío en los bordes, manejado correctamente por render().
# Solo se aplica un límite hard para evitar scroll completamente fuera.
sub compute_window {
    my ($self) = @_;

    my $size = $self->{market_data}->size();
    return ( 0, 0 ) if $size == 0;

    my $end   = ( $size - 1 ) - $self->{offset};
    my $start = $end - $self->{visible_bars} + 1;

    # Límite hard: al menos 1 vela real debe ser visible.
    # start > size-1 → todo el viewport está a la derecha de los datos.
    if ( $start > $size - 2 ) {
        $start          = $size - 2;
        $end            = $start + $self->{visible_bars} - 1;
        $self->{offset} = ( $size - 1 ) - $end;
    }
    # end < 0 → todo el viewport está a la izquierda de los datos.
    if ( $end < 1 ) {
        $end            = 1;
        $start          = $end - $self->{visible_bars} + 1;
        $self->{offset} = ( $size - 1 ) - $end;
    }

    return ( $start, $end );
}

sub request_render {
    my ($self) = @_;
    return if $self->{_render_pending};
    $self->{_render_pending} = 1;
    $self->{canvas_price}->after(
        0,
        sub {
            $self->{_render_pending} = 0;
            $self->render();
        }
    );
}

sub render {
    my ($self) = @_;

    my $size = $self->{market_data}->size();
    return if $size == 0;

    # ── Actualizar dimensiones de canvas desde el widget real ────────────────
    my $cw_price = $self->{canvas_price}->width;
    my $ch_price = $self->{canvas_price}->height;
    my $cw_atr   = $self->{canvas_atr}->width;
    my $ch_atr   = $self->{canvas_atr}->height;

    if ( $cw_price > 10 && $ch_price > 10 ) {
        $self->{scale_price}{canvas_width}  = $cw_price;
        $self->{scale_price}{canvas_height} = $ch_price;
    }
    if ( $cw_atr > 10 && $ch_atr > 10 ) {
        $self->{scale_atr}{canvas_width}  = $cw_atr;
        $self->{scale_atr}{canvas_height} = $ch_atr;
    }

    $self->{canvas_price}->configure(
        -scrollregion => [ 0, 0, $cw_price, $ch_price ] );
    $self->{canvas_atr}->configure(
        -scrollregion => [ 0, 0, $cw_atr, $ch_atr ] );

    $self->{canvas_price}->xviewMoveto(0);
    $self->{canvas_price}->yviewMoveto(0);
    $self->{canvas_atr}->xviewMoveto(0);
    $self->{canvas_atr}->yviewMoveto(0);

    $self->{scale_price}{visible_bars} = $self->{visible_bars};
    $self->{scale_atr}{visible_bars}   = $self->{visible_bars};

    my ( $start, $end ) = $self->compute_window();

    # scale.offset = start del viewport (puede ser negativo).
    # Los métodos index_to_x / index_to_center_x lo usan para posicionar.
    $self->{scale_price}{offset} = $start;
    $self->{scale_atr}{offset}   = $start;

    # data_start/data_end: rango real de datos (siempre dentro de [0, size-1]).
    my $data_start = $start < 0      ? 0         : $start;
    my $data_end   = $end   >= $size ? $size - 1 : $end;

    my $price_data = $self->{market_data}->get_slice( $data_start, $data_end );
    my $atr_values = $self->{indicators}->slice_array( 'ATR', $data_start, $data_end );

    # ── Rango Y ──────────────────────────────────────────────────────────────
    my ( $y_min, $y_max );
    if ( $self->{view_mode} eq 'manual' ) {
        unless ( defined $self->{y_min_manual} && defined $self->{y_max_manual} ) {
            ( $self->{y_min_manual}, $self->{y_max_manual} ) =
                $self->{price_panel}->get_y_range($price_data);
        }
        $y_min = $self->{y_min_manual};
        $y_max = $self->{y_max_manual};
    }
    else {
        ( $y_min, $y_max ) = $self->{price_panel}->get_y_range($price_data);
        $self->{y_min_manual} = undef;
        $self->{y_max_manual} = undef;
    }

    $self->{scale_price}{y_min} = $y_min;
    $self->{scale_price}{y_max} = $y_max;

    my ( $atr_min, $atr_max ) = $self->{atr_panel}->get_y_range($atr_values);
    $self->{scale_atr}{y_min} = $atr_min;
    $self->{scale_atr}{y_max} = $atr_max;

    # ── Dibujar paneles ───────────────────────────────────────────────────────
    # data_start se pasa explícitamente porque scale.offset puede ser negativo
    # pero el índice real del primer elemento del slice siempre es >= 0.
    $self->{price_panel}->render(
        $self->{canvas_price}, $price_data, $self->{scale_price}, $data_start );
    $self->{atr_panel}->render(
        $self->{canvas_atr}, $atr_values, $self->{scale_atr}, $data_start );

    my $timestamps = $self->compute_intraday_labels();
    $self->{price_panel}->draw_time_axis( $self->{canvas_price}, $timestamps );

    # ── Indicador de modo ─────────────────────────────────────────────────────
    $self->{canvas_price}->delete('mode_status_indicator');
    my $text_to_show =
        $self->{view_mode} eq 'auto'
        ? "ESC: ESCALA AUTOMÁTICA"
        : "ESC: ESCALA MANUAL (Arrastre 2D habilitado)";
    my $text_color = $self->{view_mode} eq 'auto' ? '#00ff00' : '#ffa500';
    $self->{canvas_price}->createText(
        15, 15,
        -text   => $text_to_show,
        -fill   => $text_color,
        -anchor => 'nw',
        -font   => 'Helvetica 10 bold',
        -tags   => 'mode_status_indicator'
    );

    # ── Redibujar crosshair si el cursor estaba en pantalla ──────────────────
    if ( defined $self->{_cursor_x} ) {
        $self->_draw_crosshair_all(
            $self->{_cursor_x},
            $self->{_cursor_y}      // -1,
            $self->{_cursor_source} // 'price'
        );
    }
}

# ─── CanvasBind_events ─────────────────────────────────────────────────────────────
# NOTA SOBRE CanvasCanvasBind vs CanvasBind en Fedora/perl-Tk:
#
# CanvasCanvasBind registra el evento sobre el canvas en el nivel de item de canvas
# (útil para eventos en items individuales). Para eventos de ratón globales
# sobre el widget, la diferencia práctica con CanvasBind es mínima en versiones
# modernas, PERO hay un problema conocido en perl-Tk <= 804.033 en sistemas
# con Tk 8.5 (que es lo que trae Fedora 35 del repo):
#
#   CanvasCanvasBind con arrayref [sub{...}, Ev('x')] no propaga Ev() correctamente
#   en todos los casos cuando el evento tiene modificadores (Control, Shift).
#   El callback recibe el canvas como primer argumento pero Ev() puede devolver
#   undef para coordenadas si el evento fue sintetizado por Tk al combinar
#   con un modificador de teclado.
#
# Solución: usar SIEMPRE ->CanvasBind() para eventos de ratón sobre el canvas widget,
# y capturar coordenadas con $widget->XEvent->x / ->y dentro del callback.
# Esto funciona correctamente en todas las versiones de perl-Tk desde 800.x.
#
# CanvasCanvasBind SÍ es correcto para: eventos en items del canvas (tags), p.ej.
# $canvas->CanvasCanvasBind('<ButtonPress-1>', sub { ... }) vinculado a un tag.
# Para el widget en su conjunto, usar CanvasBind().
sub CanvasBind_events {
    my ($self) = @_;

    my $cp = $self->{canvas_price};
    my $ca = $self->{canvas_atr};

    my $drag_start_x      = undef;
    my $drag_start_y      = undef;
    my $drag_start_offset = undef;
    my $drag_base_y_min   = undef;
    my $drag_base_y_max   = undef;
    my $drag_on_yscale    = 0;

    my $main_window = $cp->toplevel;

    # ── Focus al entrar ───────────────────────────────────────────────────────
    for my $c ( $cp, $ca ) {
        $c->CanvasBind( '<Enter>', sub { $c->focusForce(); } );
    }

    # ── Resize ────────────────────────────────────────────────────────────────
    $cp->CanvasBind( '<Configure>', sub { $self->request_render(); } );
    $ca->CanvasBind( '<Configure>', sub { $self->request_render(); } );

    # ── Botón 1: inicio de drag ───────────────────────────────────────────────
    for my $c ( $cp, $ca ) {
        $c->CanvasBind(
            '<ButtonPress-1>',
            sub {
                my $ev = $c->XEvent;
                my ( $x, $y ) = ( $ev->x, $ev->y );
                $c->focusForce();
                $drag_start_x      = $x;
                $drag_start_y      = $y;
                $drag_start_offset = $self->{offset};
                $drag_base_y_min   = $self->{scale_price}{y_min};
                $drag_base_y_max   = $self->{scale_price}{y_max};

                my $plot_w = $self->{scale_price}->plot_width();
                $drag_on_yscale = ( $x > $plot_w ) ? 1 : 0;

                if ($drag_on_yscale) {
                    $self->{view_mode} = 'manual';
                    unless ( defined $self->{y_min_manual} ) {
                        $self->{y_min_manual} = $self->{scale_price}{y_min};
                        $self->{y_max_manual} = $self->{scale_price}{y_max};
                    }
                    $drag_base_y_min = $self->{y_min_manual};
                    $drag_base_y_max = $self->{y_max_manual};
                }
            }
        );
    }

    # ── Botón 1: drag ────────────────────────────────────────────────────────
    for my $c ( $cp, $ca ) {
        $c->CanvasBind(
            '<B1-Motion>',
            sub {
                return unless defined $drag_start_x;
                my $ev = $c->XEvent;
                my ( $x, $y ) = ( $ev->x, $ev->y );

                if ($drag_on_yscale) {
                    my $dy     = $y - $drag_start_y;
                    my $range  = $drag_base_y_max - $drag_base_y_min;
                    my $mid    = ( $drag_base_y_max + $drag_base_y_min ) / 2;
                    my $ph     = $self->{scale_price}->plot_height();
                    return if $ph == 0;
                    my $factor = 1.0 + ( $dy / $ph );
                    $factor    = 0.1  if $factor < 0.1;
                    $factor    = 10.0 if $factor > 10.0;
                    my $new_half          = ( $range / 2 ) * $factor;
                    $self->{y_min_manual} = $mid - $new_half;
                    $self->{y_max_manual} = $mid + $new_half;
                    $self->request_render();
                    return;
                }

                my $bar_w = $self->{scale_price}->bar_width();
                if ( $bar_w > 0 ) {
                    # Drag derecha → x aumenta → delta_bars > 0 → offset aumenta
                    # → end retrocede → se ve historia más antigua. Correcto.
                    my $delta_bars  = int( ( $x - $drag_start_x ) / $bar_w + 0.5 );
                    $self->{offset} = $drag_start_offset + $delta_bars;
                    my $size        = $self->{market_data}->size();
                    # Límites: permitir hasta (visible_bars - 2) de espacio vacío
                    # en cada extremo, de modo que siempre queden al menos 2 velas
                    # reales visibles aunque el usuario arrastre más allá del borde.
                    my $slack   = $self->{visible_bars} - 2;
                    my $min_off = -$slack;           # borde izquierdo (futuro)
                    my $max_off = $size - 1 + $slack; # borde derecho (pasado)
                    $self->{offset} = $min_off if $self->{offset} < $min_off;
                    $self->{offset} = $max_off if $self->{offset} > $max_off;
                }
 
                if ( $self->{view_mode} eq 'manual' && defined $drag_base_y_min ) {
                    my $dy          = $y - $drag_start_y;
                    my $range       = $drag_base_y_max - $drag_base_y_min;
                    my $ph          = $self->{scale_price}->plot_height();
                    if ( $ph > 0 ) {
                        my $shift             = ( $dy / $ph ) * $range;
                        $self->{y_min_manual} = $drag_base_y_min - $shift;
                        $self->{y_max_manual} = $drag_base_y_max - $shift;
                    }
                }

                $self->request_render();
            }
        );
    }

    # ── Botón 1: release ──────────────────────────────────────────────────────
    for my $c ( $cp, $ca ) {
        $c->CanvasBind(
            '<ButtonRelease-1>',
            sub {
                $drag_start_x = undef;
                $drag_start_y = undef;
            }
        );
    }

    # ── Scroll normal (sin modificador): ancla al borde derecho ───────────────
    # Fedora 35 con X11: la rueda llega como Button-4 / Button-5.
    # En algunos entornos (Wayland/XWayland) también puede llegar MouseWheel.
    # Registramos ambos para máxima compatibilidad.
    for my $c ( $cp, $ca ) {
        $c->CanvasBind(
            '<Button-4>',
            sub {
                my $x = $c->XEvent->x;
                $self->{_cursor_x} = $x;
                $self->_update_cursor_from_x($x);
                $self->_zoom_right_edge(-1);    # zoom in
            }
        );
        $c->CanvasBind(
            '<Button-5>',
            sub {
                my $x = $c->XEvent->x;
                $self->{_cursor_x} = $x;
                $self->_update_cursor_from_x($x);
                $self->_zoom_right_edge(1);     # zoom out
            }
        );
        # MouseWheel para entornos que lo envíen (Wayland, Windows-like)
        $c->CanvasBind(
            '<MouseWheel>',
            sub {
                my $ev    = $c->XEvent;
                my $x     = $ev->x;
                my $delta = $ev->D // 0;
                $self->{_cursor_x} = $x;
                $self->_update_cursor_from_x($x);
                $self->_zoom_right_edge( $delta > 0 ? -1 : 1 );
            }
        );
    }

    # ── Ctrl+Scroll: ancla al cursor ─────────────────────────────────────────
    # Control+Button-4/5 en X11.
    # IMPORTANTE: en Fedora 35, el WM puede capturar Ctrl+scroll para cambiar
    # espacios de trabajo (GNOME lo hace con Ctrl+Alt+scroll, no Ctrl solo,
    # así que no hay conflicto). Si el usuario tiene otro atajo, puede cambiarse
    # aquí a otro modificador sin tocar la lógica.
    for my $c ( $cp, $ca ) {
        $c->CanvasBind(
            '<Control-Button-4>',
            sub {
                my $x = $c->XEvent->x;
                $self->{_cursor_x} = $x;
                $self->_update_cursor_from_x($x);
                $self->_zoom_cursor(-1);        # zoom in anclado al cursor
            }
        );
        $c->CanvasBind(
            '<Control-Button-5>',
            sub {
                my $x = $c->XEvent->x;
                $self->{_cursor_x} = $x;
                $self->_update_cursor_from_x($x);
                $self->_zoom_cursor(1);         # zoom out anclado al cursor
            }
        );
    }

    # ── Botón 3 en price: drag vertical de precio ────────────────────────────
    $cp->CanvasBind(
        '<ButtonPress-3>',
        sub {
            my $ev = $cp->XEvent;
            $cp->focusForce();
            $self->{view_mode}    = 'manual';
            $self->{y_drag_start} = $ev->y;
            $self->request_render();
        }
    );

    $cp->CanvasBind(
        '<B3-Motion>',
        sub {
            return unless defined $self->{y_drag_start};
            my $y  = $cp->XEvent->y;
            my $dy = $y - $self->{y_drag_start};
            $self->_vertical_drag($dy);
            $self->{y_drag_start} = $y;
        }
    );

    $cp->CanvasBind(
        '<Double-ButtonPress-3>',
        sub { $self->set_view_mode('auto'); }
    );

    # ── Motion: actualizar crosshair ─────────────────────────────────────────
    $cp->CanvasBind(
        '<Motion>',
        sub {
            my $ev = $cp->XEvent;
            my ( $x, $y ) = ( $ev->x, $ev->y );
            $self->{_cursor_x} = $x;
            $self->_draw_crosshair_all( $x, $y, 'price' );
        }
    );

    $ca->CanvasBind(
        '<Motion>',
        sub {
            my $ev = $ca->XEvent;
            my ( $x, $y ) = ( $ev->x, $ev->y );
            $self->{_cursor_x} = $x;
            $self->_draw_crosshair_all( $x, $y, 'atr' );
        }
    );

    # ── Atajos de teclado ─────────────────────────────────────────────────────
    $main_window->bind( '<Key-1>', sub { $self->set_timeframe('1'); } );
    $main_window->bind( '<Key-5>', sub { $self->set_timeframe('5'); } );
    $main_window->bind( '<Key-6>', sub { $self->set_timeframe('15'); } );
    $main_window->bind( '<Key-a>', sub { $self->set_view_mode('auto'); } );
    $main_window->bind( '<Key-A>', sub { $self->set_view_mode('auto'); } );
    $main_window->bind( '<Key-m>', sub { $self->set_view_mode('manual'); } );
    $main_window->bind( '<Key-M>', sub { $self->set_view_mode('manual'); } );
    $main_window->bind( '<Key-r>', sub { $self->reset_view(); } );
    $main_window->bind( '<Key-R>', sub { $self->reset_view(); } );

    $cp->focusForce();
}

sub set_view_mode {
    my ( $self, $mode ) = @_;
    $self->{view_mode} = $mode;
    if ( $mode eq 'auto' ) {
        $self->{y_min_manual} = undef;
        $self->{y_max_manual} = undef;
    }
    $self->request_render();
}

# ─── _update_cursor_from_x ───────────────────────────────────────────────────
# Actualiza _cursor_idx_float desde una coordenada X de píxel sin redibujar
# el crosshair completo. Necesario en los handlers de scroll/zoom para tener
# el anchor correcto antes de llamar a _zoom_cursor.
sub _update_cursor_from_x {
    my ( $self, $x ) = @_;
    $self->{_cursor_idx_float} = $self->{scale_price}->x_to_index_float($x);
    $self->{_cursor_idx}       = $self->{scale_price}->x_to_index($x);
}

# ─── _zoom_right_edge ────────────────────────────────────────────────────────
# Zoom anclado al borde derecho visible.
#
# Invariante: end = (size-1) - offset.
# Cambiar visible_bars sin tocar offset mantiene end constante → el borde
# derecho del viewport no se mueve.
#
# delta < 0 → zoom in  (menos barras visibles)
# delta > 0 → zoom out (más barras visibles)
sub _zoom_right_edge {
    my ( $self, $delta ) = @_;

    my $factor   = $delta < 0 ? 0.90 : 1.10;
    my $old_bars = $self->{visible_bars};
    my $new_bars = $delta < 0 ? int( $old_bars * $factor )
                          : int( $old_bars * $factor + 0.9999 );
    my $size     = $self->{market_data}->size();

    $new_bars = 2    if $new_bars < 2;
    $new_bars = $size if $new_bars > $size;
    $new_bars = 1     if $new_bars < 1;
    return if $new_bars == $old_bars;

    $self->{visible_bars} = $new_bars;
    # offset sin tocar → end fijo → borde derecho anclado.
    $self->request_render();
}

# ─── _zoom_cursor ────────────────────────────────────────────────────────────
# Zoom anclado a la vela bajo el cursor (_cursor_idx_float).
#
# La vela bajo el cursor mantiene su posición X en píxeles antes y después
# del zoom. Se permite espacio vacío (offset negativo o start fuera de rango).
#
# Derivación matemática:
#   Sea A = anchor_idx (índice flotante de la vela bajo el cursor).
#   Sea S = scale.offset (= start del viewport, puede ser negativo).
#   La posición X del anchor en el viewport es:
#       snap_x = (A - S) * bw + bw/2
#   Queremos que tras el zoom, con new_bw, el anchor siga en snap_x:
#       snap_x = (A - S') * new_bw + new_bw/2
#   Despejando S' (nuevo start):
#       S' = A - (snap_x - new_bw/2) / new_bw
#   El nuevo end:
#       end' = S' + visible_bars - 1
#   El nuevo offset:
#       new_offset = (size-1) - end'
#   No se clampea new_offset a [0, size-1] para permitir espacio vacío.
#   Solo se aplica un límite para evitar que todas las velas queden fuera.
sub _zoom_cursor {
    my ( $self, $delta ) = @_;

    my $factor   = $delta < 0 ? 0.90 : 1.10;
    my $old_bars = $self->{visible_bars};
    my $new_bars = $delta < 0 ? int( $old_bars * $factor )
                          : int( $old_bars * $factor + 0.9999 );
    my $size     = $self->{market_data}->size();

    $new_bars = 2    if $new_bars < 2;
    $new_bars = $size if $new_bars > $size;
    $new_bars = 1     if $new_bars < 1;
    return if $new_bars == $old_bars;

    my $anchor_idx = $self->{_cursor_idx_float};

    # Sin cursor conocido: degradar a zoom por borde derecho.
    unless ( defined $anchor_idx ) {
        $self->{visible_bars} = $new_bars;
        $self->request_render();
        return;
    }

    # S = scale.offset actual (= start del viewport tras el último render).
    # Usamos scale_price->{offset} directamente, no compute_window(), para
    # evitar desincronización si hay un render pendiente.
    my $scale = $self->{scale_price};
    my $S     = $scale->{offset};

    my $old_bw = $scale->bar_width();    # bar_width con visible_bars actuales
    return if $old_bw <= 0;

    # Posición X del anchor en el viewport (píxeles) antes del zoom.
    my $snap_x = ( $anchor_idx - $S ) * $old_bw + $old_bw / 2.0;

    # Bar width que habrá con new_bars (usando bar_width_for de Scales para
    # no duplicar la fórmula y garantizar consistencia).
    my $new_bw = $scale->bar_width_for($new_bars);
    return if $new_bw <= 0;

    # Nuevo start (flotante) que mantiene anchor_idx en snap_x.
    my $new_S     = $anchor_idx - ( $snap_x - $new_bw / 2.0 ) / $new_bw;
    my $new_end_f = $new_S + $new_bars - 1;

    # Offset derivado (puede ser negativo → espacio vacío a la derecha).
    my $new_offset = ( $size - 1 ) - $new_end_f;

    # Límite blando: no más de visible_bars/2 de espacio vacío en cada extremo.
    my $max_offset = $size - 1 + int( $new_bars / 2 );
    my $min_offset = -int( $new_bars / 2 );
    $new_offset = $max_offset if $new_offset > $max_offset;
    $new_offset = $min_offset if $new_offset < $min_offset;

    $self->{visible_bars} = $new_bars;
    $self->{offset}       = int( $new_offset + 0.5 );

    $self->request_render();
}

sub _vertical_drag {
    my ( $self, $dy ) = @_;
    my $scale = $self->{scale_price};

    unless ( defined $self->{y_min_manual} ) {
        $self->{y_min_manual} = $scale->{y_min};
        $self->{y_max_manual} = $scale->{y_max};
    }

    my $range = $self->{y_max_manual} - $self->{y_min_manual};
    my $ph    = $scale->plot_height();
    return if $ph == 0;

    my $price_shift        = ( $dy / $ph ) * $range;
    $self->{y_min_manual} -= $price_shift;
    $self->{y_max_manual} -= $price_shift;
    $self->request_render();
}

sub _vertical_zoom {
    my ( $self, $factor ) = @_;
    my $scale = $self->{scale_price};

    unless ( defined $self->{y_min_manual} ) {
        $self->{y_min_manual} = $scale->{y_min};
        $self->{y_max_manual} = $scale->{y_max};
    }

    my $mid  = ( $self->{y_min_manual} + $self->{y_max_manual} ) / 2;
    my $half = ( $self->{y_max_manual} - $self->{y_min_manual} ) / 2;
    $half *= $factor;
    $self->{y_min_manual} = $mid - $half;
    $self->{y_max_manual} = $mid + $half;
    $self->request_render();
}

# ─── _draw_crosshair_all ─────────────────────────────────────────────────────
# Actualiza _cursor_idx_float (anchor para zoom) y dibuja el crosshair.
sub _draw_crosshair_all {
    my ( $self, $x, $y, $source ) = @_;

    $self->{_cursor_x}         = $x;
    $self->{_cursor_idx}       = $self->{scale_price}->x_to_index($x);
    $self->{_cursor_idx_float} = $self->{scale_price}->x_to_index_float($x);
    $self->{_cursor_snap_x}    = $self->{scale_price}->index_to_center_x( $self->{_cursor_idx} );
    $self->{_cursor_y}         = $y;
    $self->{_cursor_source}    = $source;

    my $snap_x = $self->{_cursor_snap_x};

    my $ts       = $self->{market_data}->get_timestamp( $self->{_cursor_idx} );
    my $time_str = '';
    if ( defined $ts ) {
        my @t = localtime($ts);
        $time_str = sprintf( "%02d/%02d %02d:%02d", $t[3], $t[4] + 1, $t[2], $t[1] );
    }

    my $price_y = $source eq 'price' ? $y : -1;
    my $atr_y   = $source eq 'atr'   ? $y : -1;

    $self->{price_panel}->draw_crosshair( $snap_x, $price_y,
        $source eq 'price' ? $time_str : '' );
    $self->{atr_panel}->draw_crosshair( $snap_x, $atr_y,
        $source eq 'atr' ? $time_str : '' );
}

sub set_timeframe {
    my ( $self, $tf ) = @_;
    $self->{market_data}->set_timeframe($tf);
    $self->{indicators}->reset_all();
    $self->{indicators}->update_last( $self->{market_data} );
    $self->reset_view();
}

sub reset_view {
    my ($self) = @_;
    $self->{offset}            = 0;
    $self->{view_mode}         = 'auto';
    $self->{y_min_manual}      = undef;
    $self->{y_max_manual}      = undef;
    $self->{visible_bars}      = 100;
    $self->{_cursor_x}         = undef;
    $self->{_cursor_idx_float} = undef;
    $self->request_render();
}

sub compute_intraday_labels {
    my ($self) = @_;
    my ( $start, $end ) = $self->compute_window();
    my $size = $self->{market_data}->size();

    my $i_start = $start < 0      ? 0         : $start;
    my $i_end   = $end   >= $size ? $size - 1 : $end;

    my $visible  = $i_end - $i_start + 1;
    my $n_labels = 6;
    my $step     = int( $visible / $n_labels ) || 1;

    my @labels;
    my %is_day_pivot;
    my $last_day = undef;

    for my $i ( $i_start .. $i_end ) {
        my $ts = $self->{market_data}->get_timestamp($i);
        next unless defined $ts;
        my @t   = localtime($ts);
        my $day = $t[3];
        if ( !defined $last_day || $day != $last_day ) {
            $is_day_pivot{$i} = sprintf( "%02d/%02d", $t[3], $t[4] + 1 );
            $last_day = $day;
        }
    }

    my %used_idx;
    for ( my $i = $i_start; $i <= $i_end; $i += $step ) {
        my $ts = $self->{market_data}->get_timestamp($i);
        next unless defined $ts;
        if ( exists $is_day_pivot{$i} ) {
            push @labels, [ $i, $is_day_pivot{$i} ];
        }
        else {
            my @t = localtime($ts);
            push @labels, [ $i, sprintf( "%02d:%02d", $t[2], $t[1] ) ];
        }
        $used_idx{$i} = 1;
    }

    for my $i ( sort { $a <=> $b } keys %is_day_pivot ) {
        next if $used_idx{$i};
        my $too_close = 0;
        for my $used ( keys %used_idx ) {
            if ( abs( $used - $i ) < int( $step / 2 ) ) {
                $too_close = 1;
                last;
            }
        }
        if ($too_close) {
            @labels = grep { abs( $_->[0] - $i ) >= int( $step / 2 ) } @labels;
        }
        push @labels, [ $i, $is_day_pivot{$i} ];
        $used_idx{$i} = 1;
    }

    my $last_idx = $self->{market_data}->last_index();
    if ( $last_idx >= $i_start && $last_idx <= $i_end ) {
        my $ts = $self->{market_data}->get_timestamp($last_idx);
        if ( defined $ts ) {
            my @t     = localtime($ts);
            my $label = sprintf( "%02d/%02d", $t[3], $t[4] + 1 );
            @labels = grep { $_->[0] != $last_idx } @labels;
            push @labels, [ $last_idx, $label ];
        }
    }

    @labels = sort { $a->[0] <=> $b->[0] } @labels;
    return \@labels;
}

sub get_all_timestamps {
    my ($self) = @_;
    my ( $start, $end ) = $self->compute_window();
    my $size = $self->{market_data}->size();
    my @result;
    for my $i ( $start .. $end ) {
        next if $i < 0 || $i >= $size;
        my $ts = $self->{market_data}->get_timestamp($i);
        push @result, [ $i, $ts ] if defined $ts;
    }
    return \@result;
}

1;