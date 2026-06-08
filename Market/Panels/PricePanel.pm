package Market::Panels::PricePanel;
use strict;
use warnings;

# ─── Constructor ──────────────────────────────────────────────────────────────
sub new {
    my ( $class, %args ) = @_;
    my $self = {
        canvas      => $args{canvas},
        scale       => $args{scale},
        market_data => $args{market_data},
        indicators  => $args{indicators},

        color_bull      => $args{color_bull}      // '#26a69a',
        color_bear      => $args{color_bear}      // '#ef5350',
        color_wick      => $args{color_wick}      // '#888888',
        color_crosshair => $args{color_crosshair} // '#ffffff',
        color_price_tag => $args{color_price_tag} // '#131722',

        _ch_hline      => undef,
        _ch_vline      => undef,
        _ch_label      => undef,
        _ch_box        => undef,
        _ch_time_box   => undef,
        _ch_time_label => undef,
    };
    bless $self, $class;
    $self->_init_crosshair_objects();
    return $self;
}

sub _init_crosshair_objects {
    my ($self) = @_;
    my $c = $self->{canvas};

    $self->{_ch_hline} = $c->createLine(
        0, 0, 0, 0,
        -fill  => $self->{color_crosshair},
        -dash  => [ 4, 4 ],
        -width => 1,
        -state => 'hidden',
        -tags  => ['crosshair'],
    );

    $self->{_ch_vline} = $c->createLine(
        0, 0, 0, 0,
        -fill  => $self->{color_crosshair},
        -dash  => [ 4, 4 ],
        -width => 1,
        -state => 'hidden',
        -tags  => ['crosshair'],
    );

    $self->{_ch_box} = $c->createRectangle(
        0, 0, 0, 0,
        -fill    => $self->{color_crosshair},
        -outline => $self->{color_crosshair},
        -state   => 'hidden',
        -tags    => ['crosshair'],
    );

    $self->{_ch_label} = $c->createText(
        0, 0,
        -text   => '',
        -fill   => $self->{color_price_tag},
        -font   => [ 'monospace', 8, 'bold' ],
        -anchor => 'w',
        -state  => 'hidden',
        -tags   => ['crosshair'],
    );

    $self->{_ch_time_box} = $c->createRectangle(
        0, 0, 1, 1,
        -fill    => $self->{color_crosshair},
        -outline => $self->{color_crosshair},
        -state   => 'hidden',
        -tags    => ['crosshair'],
    );

    $self->{_ch_time_label} = $c->createText(
        0, 0,
        -text   => '',
        -fill   => $self->{color_price_tag},
        -font   => [ 'monospace', 8, 'bold' ],
        -anchor => 'n',
        -state  => 'hidden',
        -tags   => ['crosshair'],
    );
}

sub round {
    my ( $self, $value, $decimals ) = @_;
    $decimals //= 2;
    return sprintf( "%.${decimals}f", $value ) + 0;
}

sub get_y_range {
    my ( $self, $data ) = @_;
    return ( 0, 1 ) unless @$data;

    my $min = 9**9**9;
    my $max = -9**9**9;

    for my $candle (@$data) {
        $min = $candle->{low}  if $candle->{low}  < $min;
        $max = $candle->{high} if $candle->{high} > $max;
    }

    my $padding = ( $max - $min ) * 0.05;
    $padding = 0.001 if $padding == 0;

    return ( $min - $padding, $max + $padding );
}

sub set_scale {
    my ( $self, $scale ) = @_;
    $self->{scale} = $scale;
}

# ─── render ───────────────────────────────────────────────────────────────────
# $data_start: índice absoluto del primer elemento de $data en el array global.
# Puede diferir de scale->{offset} cuando hay espacio vacío a la izquierda
# (scale->{offset} puede ser negativo, pero $data_start >= 0 siempre).
sub render {
    my ( $self, $canvas, $data, $scale, $data_start ) = @_;
    $data_start //= $scale->{offset};
    $data_start = 0 if $data_start < 0;

    $canvas->delete('candle');
    $canvas->delete('scale_y');
    $canvas->delete('last_price');

    my $bar_w  = $scale->bar_width();
    my $body_w = $bar_w;
    $body_w *= 0.95 if $bar_w > 3;

    for my $i ( 0 .. $#$data ) {
        my $candle  = $data->[$i];
        my $abs_idx = $data_start + $i;

        # Coordenadas X basadas en el índice absoluto
        my $cx    = $scale->index_to_center_x($abs_idx);
        my $left  = $cx - $body_w / 2;
        my $right = $cx + $body_w / 2;

        my $y_open  = $scale->value_to_y( $candle->{open} );
        my $y_close = $scale->value_to_y( $candle->{close} );
        my $y_high  = $scale->value_to_y( $candle->{high} );
        my $y_low   = $scale->value_to_y( $candle->{low} );

        my $is_bull = $candle->{close} >= $candle->{open};
        my $color   = $is_bull ? $self->{color_bull} : $self->{color_bear};

        my $body_top    = $is_bull ? $y_close : $y_open;
        my $body_bottom = $is_bull ? $y_open  : $y_close;

        $canvas->createLine(
            $cx, $y_high,
            $cx, $y_low,
            -fill  => $self->{color_wick},
            -width => 1,
            -tags  => ['candle'],
        );

        if ( abs( $body_bottom - $body_top ) < 1 ) {
            $canvas->createLine(
                $left,  $body_top,
                $right, $body_top,
                -fill  => $color,
                -width => 1,
                -tags  => ['candle'],
            );
        }
        else {
            $canvas->createRectangle(
                $left,  $body_top,
                $right, $body_bottom,
                -fill    => $color,
                -outline => $color,
                -tags    => ['candle'],
            );
        }
    }

    $scale->_draw_y_scale($canvas);
    $self->render_last_visible_price( $canvas, $data, $scale );
}

sub render_last_visible_price {
    my ( $self, $canvas, $data, $scale ) = @_;
    return unless @$data;

    my $last_close = $data->[-1]{close};
    my $y          = $scale->value_to_y($last_close);
    my $x_start    = $scale->plot_width();
    my $x_end      = $scale->{canvas_width};

    $canvas->createLine(
        0, $y, $x_start, $y,
        -fill  => '#f0b90b',
        -dash  => [ 3, 3 ],
        -width => 1,
        -tags  => ['last_price'],
    );

    $canvas->createRectangle(
        $x_start, $y - 9,
        $x_end,   $y + 9,
        -fill    => '#f0b90b',
        -outline => '#f0b90b',
        -tags    => ['last_price'],
    );

    $canvas->createText(
        $x_start + 4, $y,
        -text   => sprintf( "%.2f", $last_close ),
        -fill   => '#131722',
        -font   => [ 'monospace', 8, 'bold' ],
        -anchor => 'w',
        -tags   => ['last_price'],
    );
}

sub draw_crosshair {
    my ( $self, $x, $y, $time_str ) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    my $ph    = $scale->plot_height();

    my $y_in_range = ( $y >= 0 && $y <= $ph );

    if ($y_in_range) {
        $c->coords( $self->{_ch_hline}, 0, $y, $scale->plot_width(), $y );
        $c->itemconfigure( $self->{_ch_hline}, -state => 'normal' );
    }
    else {
        $c->itemconfigure( $self->{_ch_hline}, -state => 'hidden' );
    }

    $c->coords( $self->{_ch_vline}, $x, 0, $x, $ph );
    $c->itemconfigure( $self->{_ch_vline}, -state => 'normal' );

    if ($y_in_range) {
        my $price   = $scale->y_to_value($y);
        my $x_start = $scale->plot_width();

        $c->coords( $self->{_ch_box},
            $x_start, $y - 9, $scale->{canvas_width}, $y + 9 );
        $c->itemconfigure( $self->{_ch_box}, -state => 'normal' );

        $c->coords( $self->{_ch_label}, $x_start + 4, $y );
        $c->itemconfigure(
            $self->{_ch_label},
            -text  => sprintf( "%.2f", $price ),
            -state => 'normal',
        );
    }
    else {
        $c->itemconfigure( $self->{_ch_box},   -state => 'hidden' );
        $c->itemconfigure( $self->{_ch_label}, -state => 'hidden' );
    }

    $time_str //= '';
    my $label_w = 70;
    my $y_time  = $ph + 1;

    if ( $time_str ne '' ) {
        $c->coords( $self->{_ch_time_box},
            $x - $label_w / 2, $y_time,
            $x + $label_w / 2, $y_time + 14 );
        $c->itemconfigure( $self->{_ch_time_box}, -state => 'normal' );
        $c->coords( $self->{_ch_time_label}, $x, $y_time + 1 );
        $c->itemconfigure(
            $self->{_ch_time_label},
            -text  => $time_str,
            -state => 'normal',
        );
    }
    else {
        $c->itemconfigure( $self->{_ch_time_box},   -state => 'hidden' );
        $c->itemconfigure( $self->{_ch_time_label}, -state => 'hidden' );
    }

    $c->raise('crosshair');
}

sub draw_time_axis {
    my ( $self, $canvas, $timestamps ) = @_;
    my $scale = $self->{scale};
    my $y     = $scale->plot_height() + 2;

    $canvas->delete('time_axis');

    for my $entry (@$timestamps) {
        my ( $index, $label ) = @$entry;
        my $x = $scale->index_to_center_x($index);

        my $is_pivot = ( $label =~ m{^\d{2}/\d{2}$} );

        if ($is_pivot) {
            $canvas->createLine(
                $x, 0, $x, $scale->plot_height(),
                -fill  => '#6b7280',
                -dash  => '.',
                -width => 3,
                -tags  => ['time_axis'],
            );
            $canvas->createLine(
                $x, $scale->plot_height(),
                $x, $scale->plot_height() + 6,
                -fill  => '#c8ccd8',
                -width => 2,
                -tags  => ['time_axis'],
            );
            $canvas->createText(
                $x, $y + 7,
                -text   => $label,
                -fill   => '#ffffff',
                -font   => [ 'monospace', 8, 'bold' ],
                -anchor => 'n',
                -tags   => ['time_axis'],
            );
        }
        else {
            $canvas->createLine(
                $x, $scale->plot_height(),
                $x, $scale->plot_height() + 4,
                -fill  => '#555555',
                -width => 1,
                -tags  => ['time_axis'],
            );
            $canvas->createText(
                $x, $y + 6,
                -text   => $label,
                -fill   => '#aaaaaa',
                -font   => [ 'monospace', 9 ],
                -anchor => 'n',
                -tags   => ['time_axis'],
            );
        }
    }
}

1;