package Market::Indicators::Fibonacci;

use strict;
use warnings;

# =============================================================================
# Market::Indicators::Fibonacci
#
# Indicador de niveles de Fibonacci con dos modos independientes:
#
#   - AUTO: usa los dos ultimos pivotes del zigzag EXTERNO/por volumen
#     (Market::Indicators::ZigZagVolumeProfile2 -> get_segments /
#     get_tentative_segment) como par (from -> to). Misma logica de ratios
#     y "stopit" que el fibo interno de ZigZagMTF2.
#
#   - MANUAL: el usuario fija (via click, desde el overlay) el indice de la
#     vela de referencia (ancla). El segundo punto se recalcula en cada vela
#     como el extremo (max si sube, min si baja) entre el ancla y la ultima
#     vela conocida -- un solo click, segundo punto dinamico.
#
# Ambos modos se extienden (dibujan) hasta la ultima vela; el overlay decide
# si ademas extiende visualmente hasta el borde derecho de pantalla.
#
# Este indicador NO calcula el zigzag externo: recibe una referencia al
# indicador ZigZagVolumeProfile2 ya actualizado (source_zzvp2) para el modo
# auto. Para el modo manual solo necesita el historial de velas (via
# update_at_index/update_last, igual que el resto de indicadores).
# =============================================================================

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source_zzvp2 => $args{source_zzvp2},   # Indicators::ZigZagVolumeProfile2

        enable_236 => $args{enable_236} // 1,
        enable_382 => $args{enable_382} // 1,
        enable_500 => $args{enable_500} // 1,
        enable_618 => $args{enable_618} // 1,
        enable_786 => $args{enable_786} // 1,

        mode => $args{mode} // 'auto',   # 'auto' | 'manual' | 'off'

        _c => [],   # velas base (necesarias para el modo manual)

        _manual_anchor_index => undef,   # bar_index fijado por click
        _fibo_ratios => undef,
    };
    bless $self, $class;
    $self->_build_fibo_ratios;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c} = [];
    $self->{_manual_anchor_index} = undef;
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->{_c}[$idx] = $c;
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $self->{_c}[$idx] = $c;
}

# -----------------------------------------------------------------------------
# API publica para el overlay / market.pl
# -----------------------------------------------------------------------------

# Cambia el modo activo: 'auto', 'manual', 'off'.
sub set_mode {
    my ( $self, $mode ) = @_;
    $self->{mode} = $mode;
}

sub get_mode { return $_[0]->{mode}; }

# Fija (o limpia, con undef) el ancla manual por indice de vela (click).
sub set_manual_anchor {
    my ( $self, $index ) = @_;
    $self->{_manual_anchor_index} = $index;
}

sub get_manual_anchor { return $_[0]->{_manual_anchor_index}; }

sub clear_manual_anchor { $_[0]->{_manual_anchor_index} = undef; }

# -----------------------------------------------------------------------------
# get_fibo_levels: punto de entrada unico para el overlay. Despacha segun
# $self->{mode}. Devuelve undef si no hay datos suficientes.
# -----------------------------------------------------------------------------
sub get_fibo_levels {
    my ($self) = @_;
    my $mode = $self->{mode};
    return undef if $mode eq 'off';
    return $self->_get_fibo_levels_auto   if $mode eq 'auto';
    return $self->_get_fibo_levels_manual if $mode eq 'manual';
    return undef;
}

# -----------------------------------------------------------------------------
# AUTO: toma los 2 ultimos pivotes del zigzag externo (ZZVP2). Prioriza el
# tramo abierto (tentative) si existe, ya que es el mas reciente/en vivo;
# si no hay tramo abierto, usa el ultimo segmento cerrado + el anterior a el.
# -----------------------------------------------------------------------------
sub _get_fibo_levels_auto {
    my ($self) = @_;
    my $src = $self->{source_zzvp2};
    return undef unless $src;

    my ( $from_price, $from_index, $to_price, $to_index );

    my $open = $src->can('get_tentative_segment') ? $src->get_tentative_segment : undef;
    my $segs = $src->can('get_segments') ? $src->get_segments : undef;

    if ($open) {
        # El pivote "from" es el punto de arranque del tramo abierto; el
        # extremo vigente ("to") es su punta en vivo.
        $from_price = $open->{from_price};
        $from_index = $open->{from_index};
        $to_price   = $open->{to_price};
        $to_index   = $open->{to_index};
    }
    elsif ( $segs && @$segs >= 1 ) {
        my $last = $segs->[-1];
        $from_price = $last->{from_price};
        $from_index = $last->{from_index};
        $to_price   = $last->{to_price};
        $to_index   = $last->{to_index};
    }
    else {
        return undef;
    }

    # ZZVP2 (replica fiel del Pine ChartPrime) guarda el LOW de la vela en
    # ambos extremos del pivote (detalle propio de ese script). Para el
    # fibo preferimos la mecha real de cada extremo: high en el punto que
    # es techo, low en el punto que es piso.
    ( $from_price, $to_price ) = $self->_wick_prices(
        $from_index, $from_price, $to_index, $to_price
    );

    return $self->_build_levels( $from_price, $from_index, $to_price, $to_index );
}

# -----------------------------------------------------------------------------
# _wick_prices: dado un par de pivotes (from/to) con sus precios "crudos"
# (tal cual vienen del zigzag fuente), devuelve los precios ajustados a la
# mecha real: el extremo mas alto toma el HIGH de su vela, el mas bajo toma
# el LOW de su vela. Si no hay vela disponible en ese indice, se deja el
# precio original sin modificar.
# -----------------------------------------------------------------------------
sub _wick_prices {
    my ( $self, $from_index, $from_price, $to_index, $to_price ) = @_;
    my $c = $self->{_c};

    my $from_is_top = ( $from_price >= $to_price );

    my $from_candle = $c->[$from_index];
    if ($from_candle) {
        $from_price = $from_is_top ? $from_candle->{high} : $from_candle->{low};
    }
    my $to_candle = $c->[$to_index];
    if ($to_candle) {
        $to_price = $from_is_top ? $to_candle->{low} : $to_candle->{high};
    }

    return ( $from_price, $to_price );
}

# -----------------------------------------------------------------------------
# MANUAL: from = vela ancla (click). to = extremo (max si el precio de la
# ultima vela quedo por encima del ancla, min si quedo por debajo) entre el
# ancla y la ultima vela conocida. Un solo click, segundo punto dinamico.
# -----------------------------------------------------------------------------
sub _get_fibo_levels_manual {
    my ($self) = @_;
    my $anchor = $self->{_manual_anchor_index};
    return undef unless defined $anchor;

    my $c = $self->{_c};
    my $last_idx = $#$c;
    return undef if $last_idx < 0 || $anchor > $last_idx;

    my $anchor_candle = $c->[$anchor];
    return undef unless defined $anchor_candle;

    # Determinar direccion provisional comparando el cierre de la ultima
    # vela contra el ancla, luego tomar el extremo real de la ventana en
    # esa direccion (igual criterio que el fibo interno: max/min de rango).
    return undef unless defined $c->[$last_idx];

    my ( $hi, $lo );
    for my $i ( $anchor + 1 .. $last_idx ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        $hi = $candle->{high} if !defined($hi) || $candle->{high} > $hi;
        $lo = $candle->{low}  if !defined($lo) || $candle->{low}  < $lo;
    }
    # Si el ancla es la ultima vela (no hay velas posteriores todavia),
    # usamos la propia vela ancla como referencia minima.
    if ( !defined($hi) || !defined($lo) ) {
        $hi = $anchor_candle->{high};
        $lo = $anchor_candle->{low};
    }

    # Direccion: se elige el lado (arriba/abajo) donde el precio se movio
    # MAS lejos desde el ancla, comparando contra el punto medio de esa
    # vela (mas robusto que comparar closes, que puede quedar invertido
    # si el precio hace swing en ambas direcciones despues del ancla).
    my $anchor_mid = ( $anchor_candle->{high} + $anchor_candle->{low} ) / 2;
    my $dist_up    = $hi - $anchor_mid;
    my $dist_down  = $anchor_mid - $lo;
    my $going_up   = ( $dist_up >= $dist_down );

    # El ancla toma la mecha real segun la direccion: si el precio sube
    # desde ahi, el ancla es el piso (low); si baja, el ancla es el techo (high).
    my $from_price = $going_up ? $anchor_candle->{low} : $anchor_candle->{high};

    my $search_from = ( $anchor + 1 <= $last_idx ) ? $anchor + 1 : $anchor;
    my ( $to_price, $to_index );
    if ($going_up) {
        $to_price = $hi;
        $to_index = $self->_index_of_extreme( $search_from, $last_idx, 'high', $hi );
    }
    else {
        $to_price = $lo;
        $to_index = $self->_index_of_extreme( $search_from, $last_idx, 'low', $lo );
    }

    return $self->_build_levels( $from_price, $anchor, $to_price, $to_index );
}

sub _index_of_extreme {
    my ( $self, $from, $to, $field, $target ) = @_;
    my $c = $self->{_c};
    for my $i ( $from .. $to ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        return $i if $candle->{$field} == $target;
    }
    return $to;
}

# -----------------------------------------------------------------------------
# _build_levels: misma logica de ratios + "stopit" que el fibo interno
# (ZigZagMTF2::get_fibo_levels), generalizada para cualquier par from/to.
# Se dibuja siempre hasta la ULTIMA vela conocida (to_index = last_bar_idx).
# -----------------------------------------------------------------------------
sub _build_levels {
    my ( $self, $from_price, $from_index, $to_price, $to_index ) = @_;

    my $diff = $to_price - $from_price;
    my $dir  = ( $diff >= 0 ) ? 1 : -1;

    my $last_bar_idx = $#{ $self->{_c} };
    $last_bar_idx = $to_index if $last_bar_idx < $to_index;

    my @out;
    my $stopit = 0;
    my $shown  = $self->_shown_levels_count;

    my $ratios = $self->{_fibo_ratios};
    for my $x ( 0 .. $#$ratios ) {
        last if $stopit && $x > $shown;

        my $ratio = $ratios->[$x];
        last if $ratio > 1.0;   # sin extensiones: se corta en el 100% (1.000)
        my $price = $from_price + $diff * $ratio;

        push @out, {
            ratio      => $ratio,
            price      => $price,
            from_index => $from_index,
            to_index   => $last_bar_idx,
        };

        if ( ( $dir == 1 && $price > $to_price )
            || ( $dir == -1 && $price < $to_price ) )
        {
            $stopit = 1;
        }
    }
    return \@out;
}

sub _build_fibo_ratios {
    my ($self) = @_;
    my @ratios = (0.000);
    push @ratios, 0.236 if $self->{enable_236};
    push @ratios, 0.382 if $self->{enable_382};
    push @ratios, 0.500 if $self->{enable_500};
    push @ratios, 0.618 if $self->{enable_618};
    push @ratios, 0.786 if $self->{enable_786};

    for my $x ( 1 .. 5 ) {
        push @ratios, $x, $x + 0.272, $x + 0.414, $x + 0.618;
    }
    $self->{_fibo_ratios} = \@ratios;
}

sub _shown_levels_count {
    my ($self) = @_;
    my $n = 1;
    $n++ for grep { $self->{$_} } qw(enable_236 enable_382 enable_500 enable_618 enable_786);
    return $n;
}

1;