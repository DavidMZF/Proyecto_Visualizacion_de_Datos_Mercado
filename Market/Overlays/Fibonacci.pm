package Market::Overlays::Fibonacci;

# =============================================================================
# Market::Overlays::Fibonacci
#
# Capa visual de Indicators::Fibonacci. Dibuja los niveles devueltos por
# get_fibo_levels() (mismo formato que ZigZagMTF2): linea horizontal desde
# from_index hasta la ultima vela conocida, extendida visualmente hasta el
# borde derecho de pantalla, con etiqueta ratio + precio.
#
# NO calcula nada: lee get_fibo_levels()/get_mode() de Indicators::Fibonacci.
#
# Modo manual: expone handle_click($index) para que market.pl la invoque
# cuando el usuario hace click sobre el chart estando en modo "manual"
# (boton "Fibonacci manual" activo). El overlay delega el guardado del
# ancla al indicador (set_manual_anchor) y se redibuja.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_fibonacci';

use constant {
    C_FIBO       => '#ffb300',   # ambar, distinto del fibo interno (lime) para diferenciarlos
    C_LABEL      => '#ffb300',
    C_ANCHOR     => '#ffffff',
    FIBO_LINE_WIDTH  => 1,
    ANCHOR_MARKER_R  => 4,
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source     => $args{source},        # Indicators::Fibonacci
        label_left => $args{label_left} // 0,   # por defecto a la derecha (extend.right)
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

# -----------------------------------------------------------------------------
# handle_click: traduce un click en pantalla (indice de vela ya resuelto por
# market.pl a partir del x del mouse) a un ancla manual. Solo tiene efecto
# si el indicador esta en modo 'manual'.
# -----------------------------------------------------------------------------
sub handle_click {
    my ( $self, $index ) = @_;
    my $src = $self->{source};
    return unless $src;
    return unless $src->can('get_mode') && $src->get_mode eq 'manual';
    $src->set_manual_anchor($index);
}

sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;
    return unless $src->can('get_mode');

    my $mode = $src->get_mode;
    return if $mode eq 'off';

    $self->_render_fibo( $canvas, $scale, $src );
    $self->_render_manual_anchor( $canvas, $scale, $src ) if $mode eq 'manual';
}

# -----------------------------------------------------------------------------
# Fibonacci: igual criterio de dibujo que el overlay interno (ZigZagMTF2):
# linea horizontal desde from_index, extendida hasta el borde derecho
# visible; label con ratio y precio.
# -----------------------------------------------------------------------------
sub _render_fibo {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_fibo_levels');
    my $levels = $src->get_fibo_levels;
    return unless $levels && @$levels;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};
    my $x_right_edge = $scale->index_to_center_x( $off + $vb );

    for my $lvl (@$levels) {
        next unless $scale->value_in_range( $lvl->{price} );

        my $x1 = $scale->index_to_center_x( $lvl->{from_index} );
        my $y  = $scale->value_to_y( $lvl->{price} );

        my $x2 = $x_right_edge > $x1 ? $x_right_edge : $x1;

        $canvas->createLine( $x1, $y, $x2-10, $y,
            -fill  => C_FIBO,
            -width => FIBO_LINE_WIDTH,
            -tags  => [TAG] );

        my $label = sprintf( "%.3f (%.2f)", $lvl->{ratio}, $lvl->{price} );
        my ( $lx, $anchor ) = $self->{label_left}
            ? ( $x1 - 4, 'e' )
            : ( $x2 - 155, 'w' );

        $canvas->createText( $lx, $y-7,
            -text   => $label,
            -fill   => C_LABEL,
            -anchor => $anchor,
            -font   => [ '', 8 ],
            -tags   => [TAG] );
    }
}

# -----------------------------------------------------------------------------
# Marcador visual de la vela ancla elegida por click, para que el usuario
# vea claramente sobre que vela quedo fijado el fibo manual.
# -----------------------------------------------------------------------------
sub _render_manual_anchor {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_manual_anchor');
    my $anchor = $src->get_manual_anchor;
    return unless defined $anchor;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};
    return if $anchor < $off || $anchor > $off + $vb;

    my $levels = $src->can('get_fibo_levels') ? $src->get_fibo_levels : undef;
    return unless $levels && @$levels;

    # El primer nivel (ratio 0) esta al precio del ancla (from_price).
    my $anchor_price = $levels->[0]{price};
    return unless $scale->value_in_range($anchor_price);

    my $x = $scale->index_to_center_x($anchor);
    my $y = $scale->value_to_y($anchor_price);

    $canvas->createOval(
        $x - ANCHOR_MARKER_R, $y - ANCHOR_MARKER_R,
        $x + ANCHOR_MARKER_R, $y + ANCHOR_MARKER_R,
        -outline => C_ANCHOR,
        -width   => 2,
        -tags    => [TAG],
    );
}

1;