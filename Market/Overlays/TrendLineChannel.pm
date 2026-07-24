package Market::Overlays::TrendLineChannel;

# =============================================================================
# Market::Overlays::TrendLineChannel
#
# Capa visual del canal de tendencia manual (Market::Indicators::TrendLineChannel).
# NO calcula nada: solo lee get_channel()/get_pending() y dibuja.
#
# Dibuja:
#   - Linea media          : punteada
#   - Banda superior/inferior : solidas
#   - Relleno semitransparente entre bandas
#   - Handles (circulos) en A, B y el centro del canal, para permitir el
#     arrastre desde ChartEngine (que hace su propio hit-test por
#     proximidad usando get_handle_positions()).
#   - Preview de construccion (stage 1: linea A->cursor; stage 2: bandas
#     A->cursor con el ancho tentativo) usando la posicion de mouse que
#     ChartEngine ya expone.
#
# Contrato Overlay (OverlayManager): tag() + render($canvas, $scale).
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_trendchan';

use constant {
    C_LINE     => '#ff9800',   # bordes del canal - naranja
    C_MID      => '#ffc477',   # linea central - naranja tenue
    C_FILL     => '#ff9800',
    FILL_OP    => 0.14,
    LINE_WIDTH => 2,
    HANDLE_R   => 5,
    C_HANDLE       => '#ffffff',
    C_HANDLE_EDGE  => '#ff9800',
    C_HANDLE_CTR   => '#ff9800',
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source => $args{source},   # Market::Indicators::TrendLineChannel
        show   => $args{show} // 1,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

# -----------------------------------------------------------------------------
# set_cursor: ChartEngine llama esto en cada <Motion> mientras se construye
# el canal (stage 1/2), para que el preview siga al mouse.
# -----------------------------------------------------------------------------
sub set_cursor {
    my ( $self, $idx, $price ) = @_;
    $self->{_cursor_idx}   = $idx;
    $self->{_cursor_price} = $price;
}

sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    return unless $self->{show};

    my $src = $self->{source};
    return unless $src;

    my $ch = $src->can('get_channel') ? $src->get_channel : undef;
    if ($ch) {
        $self->_draw_channel( $canvas, $scale, $ch );
        $self->_draw_handles( $canvas, $scale, $ch );
    }

    if ( $src->can('get_pending') ) {
        my $pending = $src->get_pending;
        $self->_draw_pending( $canvas, $scale, $pending ) if $pending;
    }
}

# -----------------------------------------------------------------------------
# _draw_channel: dibuja el canal confirmado, ACOTADO al segmento [A, B]
# (igual criterio que RegressionChannel: no se proyecta mas alla de los
# dos puntos que el usuario coloco).
# -----------------------------------------------------------------------------
sub _draw_channel {
    my ( $self, $canvas, $scale, $ch ) = @_;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    my $from_idx = $ch->{ax} < $ch->{bx} ? $ch->{ax} : $ch->{bx};
    my $to_idx   = $ch->{ax} < $ch->{bx} ? $ch->{bx} : $ch->{ax};
    return if $to_idx < $off || $from_idx > $off + $vb;

    my $clip_from = $from_idx < $off       ? $off       : $from_idx;
    my $clip_to   = $to_idx   > $off + $vb ? $off + $vb : $to_idx;
    return if $clip_to <= $clip_from;

    my $x1 = $scale->index_to_center_x($clip_from);
    my $x2 = $scale->index_to_center_x($clip_to);

    my $mid_y1 = $scale->value_to_y_raw( $ch->{slope} * $clip_from + $ch->{intercept} );
    my $mid_y2 = $scale->value_to_y_raw( $ch->{slope} * $clip_to   + $ch->{intercept} );
    my $up_y1  = $scale->value_to_y_raw( $ch->{slope} * $clip_from + $ch->{intercept} + $ch->{upper_off} );
    my $up_y2  = $scale->value_to_y_raw( $ch->{slope} * $clip_to   + $ch->{intercept} + $ch->{upper_off} );
    my $low_y1 = $scale->value_to_y_raw( $ch->{slope} * $clip_from + $ch->{intercept} + $ch->{lower_off} );
    my $low_y2 = $scale->value_to_y_raw( $ch->{slope} * $clip_to   + $ch->{intercept} + $ch->{lower_off} );

    my $fill = _mix( C_FILL, FILL_OP );
    $canvas->createPolygon(
        $x1, $up_y1, $x2, $up_y2, $x2, $low_y2, $x1, $low_y1,
        -fill => $fill, -outline => '', -tags => [TAG] );

    $canvas->createLine( $x1, $up_y1,  $x2, $up_y2,
        -fill => C_LINE, -width => LINE_WIDTH, -tags => [TAG] );
    $canvas->createLine( $x1, $low_y1, $x2, $low_y2,
        -fill => C_LINE, -width => LINE_WIDTH, -tags => [TAG] );
    $canvas->createLine( $x1, $mid_y1, $x2, $mid_y2,
        -fill => C_MID, -width => 1, -dash => [ 4, 3 ], -tags => [TAG] );
}

# -----------------------------------------------------------------------------
# _draw_handles: circulos en A, B y el centro (punto medio entre A y B,
# sobre la linea media) para que el usuario los arrastre.
# -----------------------------------------------------------------------------
sub _draw_handles {
    my ( $self, $canvas, $scale, $ch ) = @_;

    my ( $ax_x, $ay_y ) = ( $scale->index_to_center_x( $ch->{ax} ), $scale->value_to_y_raw( $ch->{ay} ) );
    my ( $bx_x, $by_y ) = ( $scale->index_to_center_x( $ch->{bx} ), $scale->value_to_y_raw( $ch->{by} ) );

    my $cidx   = ( $ch->{ax} + $ch->{bx} ) / 2;
    my $cprice = $ch->{slope} * $cidx + $ch->{intercept};
    my ( $cx_x, $cy_y ) = ( $scale->index_to_center_x($cidx), $scale->value_to_y_raw($cprice) );

    $self->_draw_handle( $canvas, $ax_x, $ay_y );
    $self->_draw_handle( $canvas, $bx_x, $by_y );
    $self->_draw_handle( $canvas, $cx_x, $cy_y, 1 );   # centro: relleno solido
}

sub _draw_handle {
    my ( $self, $canvas, $x, $y, $is_center ) = @_;
    my $r = HANDLE_R;
    $canvas->createOval(
        $x - $r, $y - $r, $x + $r, $y + $r,
        -fill    => $is_center ? C_HANDLE_CTR : C_HANDLE,
        -outline => C_HANDLE_EDGE,
        -width   => 2,
        -tags    => [TAG],
    );
}

# -----------------------------------------------------------------------------
# _draw_pending: preview durante la construccion (stage 1 o 2). Necesita la
# posicion actual del mouse en coordenadas de datos (idx, price), que se
# pasa via $pending->{cursor_idx}/{cursor_price} si ChartEngine los añade;
# si no vienen, no se dibuja preview (solo el punto A ya fijado).
# -----------------------------------------------------------------------------
sub _draw_pending {
    my ( $self, $canvas, $scale, $pending ) = @_;

    my ( $ax_x, $ay_y ) = ( $scale->index_to_center_x( $pending->{ax} ), $scale->value_to_y_raw( $pending->{ay} ) );
    $self->_draw_handle( $canvas, $ax_x, $ay_y );

    my $cidx   = $self->{_cursor_idx};
    my $cprice = $self->{_cursor_price};
    return unless defined $cidx && defined $cprice;

    if ( $pending->{stage} == 1 ) {
        # Preview de la linea media: A -> cursor.
        my ( $cx, $cy ) = ( $scale->index_to_center_x($cidx), $scale->value_to_y_raw($cprice) );
        $canvas->createLine( $ax_x, $ay_y, $cx, $cy,
            -fill => C_LINE, -width => LINE_WIDTH, -dash => [ 5, 3 ], -tags => [TAG] );
        $self->_draw_handle( $canvas, $cx, $cy );
        return;
    }

    if ( $pending->{stage} == 2 ) {
        # Preview del ancho: bandas tentativas A->B con desviacion segun cursor.
        my ( $bx_x, $by_y ) = ( $scale->index_to_center_x( $pending->{bx} ), $scale->value_to_y_raw( $pending->{by} ) );
        $self->_draw_handle( $canvas, $bx_x, $by_y );

        my $dx = $pending->{bx} - $pending->{ax};
        my ( $slope, $intercept );
        if ( $dx == 0 ) { ( $slope, $intercept ) = ( 0, $pending->{ay} ); }
        else {
            $slope     = ( $pending->{by} - $pending->{ay} ) / $dx;
            $intercept = $pending->{ay} - $slope * $pending->{ax};
        }

        my $mid_at_cursor = $slope * $cidx + $intercept;
        my $deviation     = abs( $cprice - $mid_at_cursor );
        $deviation = 0.0001 if $deviation <= 0;

        my $from_idx = $pending->{ax} < $pending->{bx} ? $pending->{ax} : $pending->{bx};
        my $to_idx   = $pending->{ax} < $pending->{bx} ? $pending->{bx} : $pending->{ax};
        my $off = $scale->{offset};
        my $vb  = $scale->{visible_bars};
        my $clip_from = $from_idx < $off       ? $off       : $from_idx;
        my $clip_to   = $to_idx   > $off + $vb ? $off + $vb : $to_idx;
        return if $clip_to <= $clip_from;
        my $x1 = $scale->index_to_center_x($clip_from);
        my $x2 = $scale->index_to_center_x($clip_to);

        my $mid_y1 = $scale->value_to_y_raw( $slope * $clip_from + $intercept );
        my $mid_y2 = $scale->value_to_y_raw( $slope * $clip_to   + $intercept );
        my $up_y1  = $scale->value_to_y_raw( $slope * $clip_from + $intercept + $deviation );
        my $up_y2  = $scale->value_to_y_raw( $slope * $clip_to   + $intercept + $deviation );
        my $low_y1 = $scale->value_to_y_raw( $slope * $clip_from + $intercept - $deviation );
        my $low_y2 = $scale->value_to_y_raw( $slope * $clip_to   + $intercept - $deviation );

        $canvas->createLine( $x1, $mid_y1, $x2, $mid_y2,
            -fill => C_MID, -width => 1, -dash => [ 4, 3 ], -tags => [TAG] );
        $canvas->createLine( $x1, $up_y1, $x2, $up_y2,
            -fill => C_LINE, -width => LINE_WIDTH, -dash => [ 5, 3 ], -tags => [TAG] );
        $canvas->createLine( $x1, $low_y1, $x2, $low_y2,
            -fill => C_LINE, -width => LINE_WIDTH, -dash => [ 5, 3 ], -tags => [TAG] );
    }
}

# -----------------------------------------------------------------------------
# get_handle_positions: expone en PIXELES las posiciones actuales de los 3
# handles (A, B, centro) para que ChartEngine haga hit-test de proximidad
# al iniciar un drag. Devuelve undef si no hay canal confirmado.
# Formato: { a => [x,y], b => [x,y], center => [x,y] }
# -----------------------------------------------------------------------------
sub get_handle_positions {
    my ( $self, $scale ) = @_;
    my $src = $self->{source};
    return undef unless $src;
    my $ch = $src->can('get_channel') ? $src->get_channel : undef;
    return undef unless $ch;

    my $cidx   = ( $ch->{ax} + $ch->{bx} ) / 2;
    my $cprice = $ch->{slope} * $cidx + $ch->{intercept};

    return {
        a      => [ $scale->index_to_center_x( $ch->{ax} ), $scale->value_to_y_raw( $ch->{ay} ) ],
        b      => [ $scale->index_to_center_x( $ch->{bx} ), $scale->value_to_y_raw( $ch->{by} ) ],
        center => [ $scale->index_to_center_x($cidx),        $scale->value_to_y_raw($cprice) ],
    };
}

# -----------------------------------------------------------------------------
# _mix: mezcla un color hex con el fondo, simulando opacidad en Tk Canvas.
# -----------------------------------------------------------------------------
sub _mix {
    my ( $hex, $op ) = @_;
    $op = 0 if $op < 0;
    $op = 1 if $op > 1;
    my ( $r, $g, $b ) = ( hex( substr( $hex, 1, 2 ) ),
                          hex( substr( $hex, 3, 2 ) ),
                          hex( substr( $hex, 5, 2 ) ) );
    my $f = 1 - $op;
    my ( $br, $bg, $bb ) = ( 214, 219, 230 );   # fondo claro de referencia
    $r = int( $r + ( $br - $r ) * $f );
    $g = int( $g + ( $bg - $g ) * $f );
    $b = int( $b + ( $bb - $b ) * $f );
    return sprintf( '#%02x%02x%02x', $r, $g, $b );
}

1;