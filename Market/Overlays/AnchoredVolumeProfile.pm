package Market::Overlays::AnchoredVolumeProfile;

# =============================================================================
# Market::Overlays::AnchoredVolumeProfile
#
# Dibuja el histograma horizontal (docked al lienzo en blanco a la derecha
# de la ultima vela conocida, igual zona que dejo libre el fix de Replay).
# Cada bin es una barra apilada compra(cyan)/venta(rosa); el bin POC se
# resalta con contorno propio + linea de precio punteada que cruza todo el
# ancho del histograma (con etiqueta de precio), igual criterio visual que
# ya usa el proyecto para lineas POC (Overlays::ZigZagVolumeProfile2).
#
# NO calcula nada: lee get_profile()/get_anchor_index() de
# Indicators::AnchoredVolumeProfile.
# =============================================================================

use strict;
use warnings;

use constant TAG        => 'overlay_avp';
use constant TAG_LABELS => 'overlay_avp_labels';

use constant {
    C_BUY       => '#26a69a',   # volumen comprador (velas alcistas)
    C_SELL      => '#ef5350',   # volumen vendedor (velas bajistas)
    C_POC       => '#ffd700',   # linea/():contorno del bin de mayor volumen
    C_ANCHOR    => '#4f8cff',   # marca vertical del punto de ancla
    MAX_WIDTH_FRACTION => 0.45,  # tope del histograma: fraccion del ancho del plot
    MIN_BAR_H          => 2,     # alto minimo dibujable de una barra (px)
};

sub tag         { return TAG; }
sub tag_labels  { return TAG_LABELS; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source => $args{source},
        show   => $args{show} // 1,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    $canvas->delete(TAG_LABELS);
    return unless $self->{show};

    my $src = $self->{source} or return;
    my $profile = $src->get_profile or return;
    my $bins = $profile->{bins};
    return unless $bins && @$bins;

    my $anchor_idx = $profile->{anchor_index};
    my $last_idx   = $src->processed_last;

    # Baseline: borde derecho de la ultima vela conocida (arranque del
    # "lienzo en blanco" -- misma zona que deja libre el fix de Replay).
    my $baseline_x = $scale->index_to_center_x($last_idx);
    my $plot_w     = $scale->_plot_w;

    # Si la ultima vela conocida quedo fuera de pantalla (usuario scrolleo
    # lejos en el historico), el docking a la derecha no tiene sentido visual.
    return if $baseline_x < 0 || $baseline_x > $plot_w;

    my $max_bar_w = ( $plot_w - $baseline_x );
    my $cap       = $plot_w * MAX_WIDTH_FRACTION;
    $max_bar_w = $cap if $max_bar_w > $cap;
    return if $max_bar_w <= 1;

    my $max_total = $profile->{max_total} || 1;

    # --- Marca vertical del ancla (si esta en pantalla) ---
    if ( defined $anchor_idx ) {
        my $ax = $scale->index_to_center_x($anchor_idx);
        if ( $ax >= 0 && $ax <= $plot_w ) {
            $canvas->createLine(
                $ax, $scale->_plot_y_top, $ax, $scale->_plot_y_bottom,
                -fill => C_ANCHOR, -width => 1, -dash => [ 3, 3 ],
                -tags => [TAG],
            );
            $canvas->createText(
                $ax + 4, $scale->_plot_y_top + 10,
                -text => 'AVP', -anchor => 'w', -fill => C_ANCHOR,
                -font => 'TkDefaultFont 7 bold', -tags => [ TAG, TAG_LABELS ],
            );
        }
    }

    # --- Barras por bin ---
    for my $b (@$bins) {
        next unless $scale->value_in_range( $b->{price_lo} )
                 || $scale->value_in_range( $b->{price_hi} )
                 || ( $b->{price_lo} < $scale->{min_val}
                   && $b->{price_hi} > $scale->{max_val} );

        my $y1 = $scale->value_to_y( $b->{price_hi} );
        my $y2 = $scale->value_to_y( $b->{price_lo} );
        ( $y1, $y2 ) = ( $y2, $y1 ) if $y1 > $y2;
        next if ( $y2 - $y1 ) < MIN_BAR_H;

        my $bar_len  = ( $b->{total} / $max_total ) * $max_bar_w;
        next if $bar_len <= 0;

        my $buy_len  = $b->{total} > 0 ? ( $b->{buy} / $b->{total} ) * $bar_len : 0;
        my $sell_len = $bar_len - $buy_len;

        my $x1 = $baseline_x;
        my $x2 = $x1 + $buy_len;
        my $x3 = $x2 + $sell_len;

        $canvas->createRectangle( $x1, $y1, $x2, $y2,
            -fill => C_BUY, -outline => C_BUY, -width => 0, -tags => [TAG] )
            if $buy_len > 0;
        $canvas->createRectangle( $x2, $y1, $x3, $y2,
            -fill => C_SELL, -outline => C_SELL, -width => 0, -tags => [TAG] )
            if $sell_len > 0;

        if ( $b->{is_poc} ) {
            $canvas->createRectangle( $x1, $y1, $x3, $y2,
                -fill => '', -outline => C_POC, -width => 2, -tags => [TAG] );
        }
    }

    # --- Linea + etiqueta del POC (cruza todo el ancho del histograma) ---
    my ($poc) = grep { $_->{is_poc} } @$bins;
    if ($poc) {
        my $py = $scale->value_to_y( ( $poc->{price_lo} + $poc->{price_hi} ) / 2 );
        $canvas->createLine(
            $baseline_x, $py, $baseline_x + $max_bar_w, $py,
            -fill => C_POC, -width => 1, -dash => [ 4, 2 ], -tags => [TAG],
        );
        my $mid_price = ( $poc->{price_lo} + $poc->{price_hi} ) / 2;
        $canvas->createText(
            $baseline_x + $max_bar_w + 4, $py,
            -text   => sprintf( '%.2f', $mid_price ),
            -anchor => 'w', -fill => C_POC,
            -font   => 'TkDefaultFont 8 bold', -tags => [ TAG, TAG_LABELS ],
        );
    }
}

1;