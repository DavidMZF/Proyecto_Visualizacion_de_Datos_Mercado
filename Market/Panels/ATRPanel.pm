package Market::Panels::ATRPanel;
use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        canvas      => $args{canvas},
        scale       => $args{scale},
        color_line  => $args{color_line}  // '#2962ff',
        color_cross => $args{color_cross} // '#ffffff',
        color_label => $args{color_label} // '#131722',

        _ch_hline      => undef,
        _ch_vline      => undef,
        _ch_box        => undef,
        _ch_label      => undef,
        _ch_time_box   => undef,
        _ch_time_label => undef,
    };
    bless $self, $class;
    $self->_init_crosshair();
    return $self;
}

sub _init_crosshair {
    my ($self) = @_;
    my $c = $self->{canvas};

    $self->{_ch_hline} = $c->createLine(
        0, 0, 1, 0,
        -fill  => $self->{color_cross},
        -dash  => [ 4, 4 ],
        -width => 1,
        -state => 'hidden',
        -tags  => ['crosshair'],
    );
    $self->{_ch_vline} = $c->createLine(
        0, 0, 0, 1,
        -fill  => $self->{color_cross},
        -dash  => [ 4, 4 ],
        -width => 1,
        -state => 'hidden',
        -tags  => ['crosshair'],
    );
    $self->{_ch_box} = $c->createRectangle(
        0, 0, 1, 1,
        -fill    => $self->{color_cross},
        -outline => $self->{color_cross},
        -state   => 'hidden',
        -tags    => ['crosshair'],
    );
    $self->{_ch_label} = $c->createText(
        0, 0,
        -text   => '',
        -fill   => $self->{color_label},
        -font   => [ 'monospace', 8, 'bold' ],
        -anchor => 'w',
        -state  => 'hidden',
        -tags   => ['crosshair'],
    );
    $self->{_ch_time_box} = $c->createRectangle(
        0, 0, 1, 1,
        -fill    => $self->{color_cross},
        -outline => $self->{color_cross},
        -state   => 'hidden',
        -tags    => ['crosshair'],
    );
    $self->{_ch_time_label} = $c->createText(
        0, 0,
        -text   => '',
        -fill   => $self->{color_label},
        -font   => [ 'monospace', 8, 'bold' ],
        -anchor => 'n',
        -state  => 'hidden',
        -tags   => ['crosshair'],
    );
}

sub get_y_range {
    my ( $self, $values ) = @_;
    my @valid = grep { defined $_ } @$values;
    return ( 0, 1 ) unless @valid;

    my ( $min, $max ) = ( $valid[0], $valid[0] );
    for my $v (@valid) {
        $min = $v if $v < $min;
        $max = $v if $v > $max;
    }

    my $padding = ( $max - $min ) * 0.10;
    $padding = 0.0001 if $padding == 0;
    return ( $min - $padding, $max + $padding );
}

sub set_scale {
    my ( $self, $scale ) = @_;
    $self->{scale} = $scale;
}

# ─── render ───────────────────────────────────────────────────────────────────
# $data_start: índice absoluto del primer elemento del slice (>= 0 siempre).
# Puede diferir de scale->{offset} cuando hay espacio vacío a la izquierda.
sub render {
    my ( $self, $canvas, $values, $scale, $data_start ) = @_;
    $data_start //= $scale->{offset};
    $data_start = 0 if $data_start < 0;

    $canvas->delete('atr_line');
    $canvas->delete('scale_y');
    $canvas->delete('last_atr');

    my @points;

    for my $i ( 0 .. $#$values ) {
        my $val = $values->[$i];

        unless ( defined $val ) {
            if ( @points >= 4 ) {
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

        my $abs_idx = $data_start + $i;
        my $x       = $scale->index_to_center_x($abs_idx);
        my $y       = $scale->value_to_y($val);
        push @points, $x, $y;
    }

    if ( @points >= 4 ) {
        $canvas->createLine(
            @points,
            -fill  => $self->{color_line},
            -width => 1.5,
            -tags  => ['atr_line'],
        );
    }

    $scale->_draw_y_scale($canvas);
    $self->render_last_visible_value( $canvas, $values, $scale );
}

sub render_last_visible_value {
    my ( $self, $canvas, $values, $scale ) = @_;

    my $last_val = undef;
    for my $v ( reverse @$values ) {
        if ( defined $v ) { $last_val = $v; last; }
    }
    return unless defined $last_val;

    my $y       = $scale->value_to_y($last_val);
    my $x_start = $scale->_plot_width();

    $canvas->createLine(
        0, $y, $x_start, $y,
        -fill  => $self->{color_line},
        -dash  => [ 3, 3 ],
        -width => 1,
        -tags  => ['last_atr'],
    );
    $canvas->createRectangle(
        $x_start,               $y - 9,
        $scale->{canvas_width}, $y + 9,
        -fill    => $self->{color_line},
        -outline => $self->{color_line},
        -tags    => ['last_atr'],
    );
    $canvas->createText(
        $x_start + 4, $y,
        -text   => sprintf( "%.4f", $last_val ),
        -fill   => $self->{color_label},
        -font   => [ 'monospace', 8, 'bold' ],
        -anchor => 'w',
        -tags   => ['last_atr'],
    );
}

sub draw_crosshair {
    my ( $self, $x, $y, $time_str ) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};

    my $pw = $scale->_plot_width();
    my $ph = $scale->_plot_height();

    my $y_in_range = ( $y >= 0 && $y <= $ph );

    $c->coords( $self->{_ch_vline}, $x, 0, $x, $ph );
    $c->itemconfigure( $self->{_ch_vline}, -state => 'normal' );

    if ($y_in_range) {
        $c->coords( $self->{_ch_hline}, 0, $y, $pw, $y );
        $c->itemconfigure( $self->{_ch_hline}, -state => 'normal' );

        my $atr_val = $scale->y_to_value($y);

        $c->coords( $self->{_ch_box},
            $pw, $y - 9, $scale->{canvas_width}, $y + 9 );
        $c->itemconfigure( $self->{_ch_box}, -state => 'normal' );

        $c->coords( $self->{_ch_label}, $pw + 4, $y );
        $c->itemconfigure(
            $self->{_ch_label},
            -text  => sprintf( "%.4f", $atr_val ),
            -state => 'normal',
        );
    }
    else {
        $c->itemconfigure( $self->{_ch_hline}, -state => 'hidden' );
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

1;