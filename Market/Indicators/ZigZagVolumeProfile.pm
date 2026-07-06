package Market::Indicators::ZigZagVolumeProfile;

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        period       => $args{period}       // 8,
        bins         => $args{bins}         // 10,
        max_profiles => $args{max_profiles} // 15,

        _c => [],

        _pivots  => [],
        _next_id => 1,

        _segments => [],
        _profiles => [],
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_pivots} = [];
    $self->{_next_id} = 1;
    $self->{_segments} = [];
    $self->{_profiles}  = [];
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_try_confirm_pivot($idx);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_try_confirm_pivot($idx);
}

sub get_pivots   { return $_[0]->{_pivots}; }
sub get_segments { return $_[0]->{_segments}; }
sub get_profiles { return $_[0]->{_profiles}; }

sub get_tentative_segment {
    my ($self) = @_;
    my $pivots = $self->{_pivots};
    return undef unless @$pivots;

    my $last_pivot = $pivots->[-1];
    my $last_base_idx = $#{ $self->{_c} };
    return undef if $last_base_idx <= $last_pivot->{index};

    my $c = $self->{_c};

    # Extremo real alcanzado desde el ultimo pivote confirmado hasta la
    # vela mas reciente conocida. El tramo tentativo debe apuntar hacia
    # ese extremo (high si el ultimo pivote fue un minimo -> se busca
    # hacia arriba; low si fue un maximo -> se busca hacia abajo), NO
    # hacia el close de la ultima vela: el close puede quedar muy por
    # detras del maximo/minimo real ya impreso en las velas, ocultando
    # rebotes o caidas que ya ocurrieron dentro de la ventana no
    # confirmada por el periodo del fractal.
    my $extreme_price = undef;
    my $extreme_idx   = $last_base_idx;

    for my $i ( $last_pivot->{index} + 1 .. $last_base_idx ) {
        my $candle = $c->[$i];
        next unless defined $candle;

        if ( $last_pivot->{kind} eq 'L' ) {
            # buscando el proximo maximo -> nos interesa el 'high' mas alto
            if ( !defined($extreme_price) || $candle->{high} > $extreme_price ) {
                $extreme_price = $candle->{high};
                $extreme_idx   = $i;
            }
        }
        else {
            # kind eq 'H' -> buscando el proximo minimo -> el 'low' mas bajo
            if ( !defined($extreme_price) || $candle->{low} < $extreme_price ) {
                $extreme_price = $candle->{low};
                $extreme_idx   = $i;
            }
        }
    }

    return undef unless defined $extreme_price;

    return {
        from_index => $last_pivot->{index},
        to_index   => $extreme_idx,
        from_price => $last_pivot->{price},
        to_price   => $extreme_price,
        dir        => ( $extreme_price > $last_pivot->{price} ) ? 'up' : 'down',
    };
}

sub _try_confirm_pivot {
    my ( $self, $idx ) = @_;
    my $p = $self->{period};
    my $t = $idx - $p;
    return if $t < $p;

    my $c = $self->{_c};
    for my $i ( 1 .. $p ) {
        return unless defined $c->[ $t - $i ] && defined $c->[ $t + $i ];
    }

    my $is_high = 1;
    my $is_low  = 1;
    for my $i ( 1 .. $p ) {
        $is_high = 0 if !( $c->[$t]{high} > $c->[ $t - $i ]{high}
                         && $c->[$t]{high} > $c->[ $t + $i ]{high} );
        $is_low  = 0 if !( $c->[$t]{low}  < $c->[ $t - $i ]{low}
                         && $c->[$t]{low}  < $c->[ $t + $i ]{low} );
    }

    $self->_consolidate( $t, 'H', $c->[$t]{high} ) if $is_high;
    $self->_consolidate( $t, 'L', $c->[$t]{low} )  if $is_low;
}

sub _consolidate {
    my ( $self, $index, $kind, $price ) = @_;

    my $pivot = { id => $self->{_next_id}++, index => $index, kind => $kind, price => $price };

    my $pivots = $self->{_pivots};
    my $last = @$pivots ? $pivots->[-1] : undef;

    if ( defined $last && $last->{kind} eq $kind ) {
        my $more_extreme =
            ( $kind eq 'H' ) ? ( $price > $last->{price} ) : ( $price < $last->{price} );
        return unless $more_extreme;
        pop @$pivots;
        pop @{ $self->{_segments} };
        pop @{ $self->{_profiles} };
        $last = @$pivots ? $pivots->[-1] : undef;
    }

    push @$pivots, $pivot;

    if ( defined $last ) {
        $self->_add_segment_and_profile( $last, $pivot );
    }
}

sub _add_segment_and_profile {
    my ( $self, $prev, $cur ) = @_;

    push @{ $self->{_segments} }, {
        from_index => $prev->{index},
        to_index   => $cur->{index},
        from_price => $prev->{price},
        to_price   => $cur->{price},
        dir        => ( $cur->{price} > $prev->{price} ) ? 'up' : 'down',
    };

    push @{ $self->{_profiles} }, $self->_build_profile( $prev, $cur );

    # Limitamos SOLO el historial de perfiles de volumen en memoria, 
    # para no saturar el rendimiento, pero NUNCA borramos los _segments 
    # estructurales del ZigZag.
    my $max = $self->{max_profiles};
    if ( @{ $self->{_profiles} } > $max ) {
        shift @{ $self->{_profiles} };
    }
}

sub _build_profile {
    my ( $self, $prev, $cur ) = @_;

    my $idx_from = $prev->{index} < $cur->{index} ? $prev->{index} : $cur->{index};
    my $idx_to   = $prev->{index} < $cur->{index} ? $cur->{index}  : $prev->{index};

    my $price_lo = $prev->{price} < $cur->{price} ? $prev->{price} : $cur->{price};
    my $price_hi = $prev->{price} < $cur->{price} ? $cur->{price}  : $prev->{price};

    my $n_bins = $self->{bins};
    my $range  = $price_hi - $price_lo;
    $range = 1e-9 if $range <= 0;
    my $bin_size = $range / $n_bins;

    my @bins = map {
        { low => $price_lo + $_ * $bin_size, high => $price_lo + ( $_ + 1 ) * $bin_size, volume => 0 }
    } ( 0 .. $n_bins - 1 );

    my $c = $self->{_c};
    for my $i ( $idx_from .. $idx_to ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        my $vol = $candle->{volume} // 0;
        next if $vol <= 0;

        my $lo = $candle->{low}  < $price_lo ? $price_lo : $candle->{low};
        my $hi = $candle->{high} > $price_hi ? $price_hi : $candle->{high};
        next if $hi <= $lo;

        my $candle_range = $candle->{high} - $candle->{low};
        $candle_range = 1e-9 if $candle_range <= 0;

        for my $b (@bins) {
            my $overlap_lo = $lo > $b->{low}  ? $lo : $b->{low};
            my $overlap_hi = $hi < $b->{high} ? $hi : $b->{high};
            next if $overlap_hi <= $overlap_lo;

            my $fraction = ( $overlap_hi - $overlap_lo ) / $candle_range;
            $b->{volume} += $vol * $fraction;
        }
    }

    my $poc = $bins[0];
    for my $b (@bins) {
        $poc = $b if $b->{volume} > $poc->{volume};
    }

    return {
        idx_from   => $idx_from,
        idx_to     => $idx_to,
        price_from => $prev->{price},
        price_to   => $cur->{price},
        bins       => \@bins,
        poc_price  => ( $poc->{low} + $poc->{high} ) / 2,
        poc_volume => $poc->{volume},
    };
}

1;