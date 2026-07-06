package Market::Indicators::Liquidity;

# =============================================================================
# Market::Indicators::Liquidity
#
# Deteccion y filtrado de Puntos de Giro (Swings) y clasificacion de
# Estructura de Mercado (HH / HL / LH / LL), mas la Linea de Tendencia
# construida a partir de la secuencia combinada de swings (highs y lows
# intercalados, sin distincion de tipo para trazar la polilinea).
#
# No incluye Order Blocks, FVG ni logica de dibujo: esto es SOLO calculo.
# El overlay (Overlays/Liquidity.pm) lee get_swings / get_swing_labels /
# get_trendline y dibuja.
#
# -----------------------------------------------------------------------------
# PIPELINE (por cada swing base candidato):
#
#   1. FRACTALIDAD (deteccion base)
#        Maximo swing base en t: High[t] > High[t-i] y High[t] > High[t+i]
#        Minimo swing base en t: Low[t]  < Low[t-i]  y Low[t]  < Low[t+i]
#        para todo i en [1, N] (N = fractal_n).
#        La vela t solo puede confirmarse cuando ya se conocen N velas
#        posteriores (t+N) -> confirmacion retrasada, cero look-ahead real
#        en el sentido de que el swing no se usa/expone hasta ese momento.
#
#   2. FILTRO 1: VOLATILIDAD ATR (ruido de mercados laterales)
#        Un swing base solo se CONSOLIDA si la distancia vertical entre el
#        nuevo swing y el ULTIMO SWING CONSOLIDADO DEL TIPO OPUESTO es
#        estrictamente mayor que (m_ATR * ATR[t]).
#        Si no la cumple, se descarta como ruido (no pasa a la fase 2).
#
#   3. FILTRO 2: DESPLAZAMIENTO / MOMENTUM (huella institucional)
#        Tras pasar el filtro ATR, el swing queda "pendiente de
#        confirmacion por desplazamiento": dentro de las V_desp velas
#        siguientes al pivote, el precio debe recorrer al menos
#        (U_desp * ATR[t]) en contra del pivote (hacia abajo si es
#        maximo, hacia arriba si es minimo). Si V_desp velas pasan sin
#        lograrlo, el swing se descarta definitivamente. Mientras el
#        swing esta pendiente, NO se expone ni se usa para clasificar.
#
#   4. ALTERNANCIA ESTRICTA (ZigZag)
#        La secuencia de swings consolidados debe alternar SIEMPRE H-L-H-L...
#        Si el nuevo swing es del MISMO tipo que el ultimo swing consolidado:
#          - Si es MAS EXTREMO (High mayor, o Low menor) que ese ultimo swing,
#            LO REEMPLAZA (el anterior se descarta: era un maximo/minimo
#            intermedio, no el extremo real del tramo).
#          - Si NO es mas extremo, el nuevo candidato se descarta y el
#            anterior se mantiene.
#        Solo cuando el nuevo swing es de tipo OPUESTO al ultimo consolidado
#        se agrega como swing nuevo en la secuencia.
#
#   5. CLASIFICACION (solo swings que sobreviven 1, 2 y 3)
#        Highs: nuevo Max > Max consolidado anterior -> HH; si no -> LH.
#        Lows : nuevo Min >= Min consolidado anterior -> HL; si no -> LL.
#        El primer swing de cada tipo (sin referencia previa) se marca
#        como HH o LL respectivamente (punto de partida, sin contexto).
#
#   6. TREND LINE
#        Polilinea construida con TODOS los swings consolidados (highs y
#        lows intercalados por indice/tiempo, sin distinguir tipo), en
#        el orden en que fueron confirmados.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        atr           => $args{atr},              # Indicators::ATR (get_values)
        fractal_n     => $args{fractal_n} // $args{k} // 3,   # N velas a cada lado
        m_atr         => $args{m_atr}     // 1.5,  # multiplicador filtro volatilidad
        atr_period    => $args{atr_period}// 14,   # informativo (el ATR ya trae su periodo)
        v_desp        => $args{v_desp}    // 10,   # ventana max. de velas para el impulso
        u_desp        => $args{u_desp}    // 2.0,  # multiplicador ATR de recorrido minimo

        _c   => [],   # velas conocidas (indice = indice de vela global)
        _atr => [],   # cache local de get_values() del ATR, se refresca cada update

        # Candidatos fractales brutos, a la espera de N velas futuras para
        # confirmar fractalidad. { index, kind => 'H'|'L', price }
        _pending_fractal => [],

        # Candidatos que pasaron fractalidad + filtro ATR, a la espera de
        # desplazamiento dentro de v_desp velas.
        # { index, kind, price, deadline, extreme }
        _pending_displacement => [],

        # Swings totalmente consolidados (pasaron los 2 filtros), en orden
        # cronologico. Cada uno: { id, index, ts, kind => 'H'|'L', price }
        _swings => [],
        _next_id => 1,

        # Ultimo swing consolidado por tipo (para filtro ATR y clasificacion)
        _last_H => undef,   # { index, price }
        _last_L => undef,

        # Etiquetas de estructura por indice de swing: 'HH'|'HL'|'LH'|'LL'
        _labels => {},

        # Linea de tendencia: puntos [{index, price}], un punto por swing
        # consolidado, en orden cronologico (highs y lows intercalados).
        _trendline => [],

        # BSL/SSL, EQH/EQL, eventos (Sweep/Grab/Run): mantenidos para
        # compatibilidad con el overlay existente. Fase de liquidez pura
        # (no SMC) se limita aqui a estructura + swings; estos quedan
        # vacios/placeholder hasta que se aborde esa fase por separado.
        _levels => [],
        _equals => [],
        _events => [],
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}   = [];
    $self->{_atr} = [];
    $self->{_pending_fractal}      = [];
    $self->{_pending_displacement} = [];
    $self->{_swings}  = [];
    $self->{_next_id} = 1;
    $self->{_last_H} = undef;
    $self->{_last_L} = undef;
    $self->{_labels} = {};
    $self->{_trendline} = [];
    $self->{_levels} = [];
    $self->{_equals} = [];
    $self->{_events} = [];
}

sub get_values { return []; }

# -----------------------------------------------------------------------------
# Accesores de solo lectura para overlays / SMC_Structures.
# -----------------------------------------------------------------------------
sub get_swings       { return $_[0]->{_swings}; }
sub get_swing_labels { return $_[0]->{_labels}; }
sub get_trendline    { return $_[0]->{_trendline}; }
sub get_levels       { return $_[0]->{_levels}; }
sub get_equals       { return $_[0]->{_equals}; }
sub get_events       { return $_[0]->{_events}; }

sub last_swing_high {
    my ($self) = @_;
    for ( my $i = $#{ $self->{_swings} }; $i >= 0; $i-- ) {
        my $s = $self->{_swings}[$i];
        return { index => $s->{index}, price => $s->{price} } if $s->{kind} eq 'H';
    }
    return undef;
}

sub last_swing_low {
    my ($self) = @_;
    for ( my $i = $#{ $self->{_swings} }; $i >= 0; $i-- ) {
        my $s = $self->{_swings}[$i];
        return { index => $s->{index}, price => $s->{price} } if $s->{kind} eq 'L';
    }
    return undef;
}

# -----------------------------------------------------------------------------
# update_at_index / update_last: contrato del IndicatorManager.
# -----------------------------------------------------------------------------
sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_ingest($md, $c, $idx);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $md->last_index if $md->can('last_index');
    my $c   = $md->last_candle;
    return unless defined $c;
    $idx = $#{ $self->{_c} } + 1 unless defined $idx;
    $self->_ingest($md, $c, $idx);
}

sub _ingest {
    my ( $self, $md, $c, $idx ) = @_;
    $self->{_c}[$idx] = $c;

    my $atr_arr = $self->{atr} && $self->{atr}->can('get_values')
        ? $self->{atr}->get_values
        : undef;
    $self->{_atr} = $atr_arr if $atr_arr;

    $self->_try_confirm_fractals($idx);
    $self->_check_displacement($idx);
}

# -----------------------------------------------------------------------------
# _try_confirm_fractals: intenta confirmar fractalidad en (idx - N), ahora que
# ya se conoce hasta idx (>= (idx-N)+N). Solo evalua UNA vez el candidato
# (idx - N); si idx < N no hay nada que evaluar todavia.
# -----------------------------------------------------------------------------
sub _try_confirm_fractals {
    my ( $self, $idx ) = @_;
    my $n = $self->{fractal_n};
    my $t = $idx - $n;
    return if $t < $n;                      # no hay N velas a la izquierda aun
    return unless defined $self->{_c}[$t];

    my $c = $self->{_c};
    for my $i ( 1 .. $n ) {
        return unless defined $c->[ $t - $i ] && defined $c->[ $t + $i ];
    }

    my $is_high = 1;
    my $is_low  = 1;
    for my $i ( 1 .. $n ) {
        $is_high = 0 if !( $c->[$t]{high} > $c->[ $t - $i ]{high}
                         && $c->[$t]{high} > $c->[ $t + $i ]{high} );
        $is_low  = 0 if !( $c->[$t]{low}  < $c->[ $t - $i ]{low}
                         && $c->[$t]{low}  < $c->[ $t + $i ]{low} );
    }

    return unless $is_high || $is_low;

    my $atr_t = $self->_atr_at($t);
    return unless defined $atr_t && $atr_t > 0;   # sin ATR valido no se puede filtrar

    if ($is_high) {
        $self->_apply_atr_filter( $t, 'H', $c->[$t]{high}, $atr_t );
    }
    if ($is_low) {
        $self->_apply_atr_filter( $t, 'L', $c->[$t]{low}, $atr_t );
    }
}

sub _atr_at {
    my ( $self, $t ) = @_;
    my $arr = $self->{_atr};
    return undef unless $arr && ref($arr) eq 'ARRAY';
    return $arr->[$t];
}

# -----------------------------------------------------------------------------
# FILTRO 1 (ATR): distancia vertical desde el nuevo swing hasta el ULTIMO
# SWING CONSOLIDADO DEL TIPO OPUESTO debe ser > m_ATR * ATR[t].
# Si no hay swing opuesto previo (arranque de la serie), se acepta el primer
# candidato de cada tipo sin filtro (no hay contra que comparar).
# Si pasa, el candidato entra a la cola de validacion por desplazamiento.
# -----------------------------------------------------------------------------
sub _apply_atr_filter {
    my ( $self, $t, $kind, $price, $atr_t ) = @_;

    my $opposite = ( $kind eq 'H' ) ? $self->{_last_L} : $self->{_last_H};

    if ( defined $opposite ) {
        my $dist = abs( $price - $opposite->{price} );
        my $min_req = $self->{m_atr} * $atr_t;
        return if !( $dist > $min_req );   # ruido: se descarta, no se re-evalua
    }

    push @{ $self->{_pending_displacement} }, {
        index    => $t,
        kind     => $kind,
        price    => $price,
        atr      => $atr_t,
        deadline => $t + $self->{v_desp},
        extreme  => $price,   # se actualiza mientras esta pendiente (ver abajo)
    };
}

# -----------------------------------------------------------------------------
# FILTRO 2 (DESPLAZAMIENTO): recorre los candidatos pendientes en cada vela
# nueva (idx). Si dentro de v_desp velas el precio se mueve al menos
# u_desp * ATR[t] en contra del pivote, se consolida. Si se agota la ventana
# sin lograrlo, se descarta.
# -----------------------------------------------------------------------------
sub _check_displacement {
    my ( $self, $idx ) = @_;
    return unless @{ $self->{_pending_displacement} };

    my $c   = $self->{_c}[$idx];
    return unless defined $c;

    my @still_pending;
    for my $cand ( @{ $self->{_pending_displacement} } ) {
        if ( $idx <= $cand->{index} ) { push @still_pending, $cand; next; }

        my $required = $self->{u_desp} * $cand->{atr};

        if ( $cand->{kind} eq 'H' ) {
            $cand->{extreme} = $c->{low} if $c->{low} < $cand->{extreme};
            my $travel = $cand->{price} - $cand->{extreme};
            if ( $travel >= $required ) {
                $self->_consolidate($cand);
                next;
            }
        }
        else {
            $cand->{extreme} = $c->{high} if $c->{high} > $cand->{extreme};
            my $travel = $cand->{extreme} - $cand->{price};
            if ( $travel >= $required ) {
                $self->_consolidate($cand);
                next;
            }
        }

        if ( $idx >= $cand->{deadline} ) {
            next;   # se agoto la ventana sin desplazamiento: descartado
        }
        push @still_pending, $cand;
    }
    $self->{_pending_displacement} = \@still_pending;
}

# -----------------------------------------------------------------------------
# _consolidate: swing validado (paso ATR + desplazamiento). Antes de
# registrarlo se fuerza ALTERNANCIA ESTRICTA (ver punto 4 del pipeline):
#   - Si el ULTIMO swing de la secuencia (por indice, no por confirmacion)
#     es del MISMO tipo que este candidato, no se agrega uno nuevo: se
#     compara contra ese swing y solo sobrevive el mas extremo (el otro se
#     descarta / reemplaza). El swing reemplazado se retira tambien de la
#     trend line y de las etiquetas.
#   - Si es de tipo OPUESTO, se inserta normalmente en la secuencia.
#
# Esta regla es la que garantiza que el patron de estructura sea siempre
# H-L-H-L... (nunca dos maximos ni dos minimos consecutivos en la secuencia
# de swings expuesta al overlay y a SMC_Structures).
#
# La insercion sigue siendo por indice (no por orden de confirmacion) por la
# misma razon documentada en _insert_sorted_by_index: el filtro de
# desplazamiento puede confirmar swings fuera de orden cronologico.
# -----------------------------------------------------------------------------
sub _consolidate {
    my ( $self, $cand ) = @_;

    my $swing = {
        id    => $self->{_next_id}++,
        index => $cand->{index},
        ts    => $self->{_c}[ $cand->{index} ]{ts},
        kind  => $cand->{kind},
        price => $cand->{price},
    };

    my $pos = $self->_find_insert_pos( $swing->{index} );
    my $left  = $pos > 0 ? $self->{_swings}[ $pos - 1 ] : undef;
    my $right = $pos <= $#{ $self->{_swings} } ? $self->{_swings}[$pos] : undef;

    my $same_kind_neighbor =
        ( defined $left  && $left->{kind}  eq $swing->{kind} ) ? $left  :
        ( defined $right && $right->{kind} eq $swing->{kind} ) ? $right :
        undef;

    if ( defined $same_kind_neighbor ) {
        my $new_is_more_extreme =
            ( $swing->{kind} eq 'H' )
                ? ( $swing->{price} > $same_kind_neighbor->{price} )
                : ( $swing->{price} < $same_kind_neighbor->{price} );

        return unless $new_is_more_extreme;   # candidato no es el extremo real: descartado

        $self->_remove_swing($same_kind_neighbor);
        $pos = $self->_find_insert_pos( $swing->{index} );
    }

    splice( @{ $self->{_swings} }, $pos, 0, $swing );

    $self->_classify($swing);

    $self->_insert_sorted_by_index( $self->{_trendline}, { index => $swing->{index}, price => $swing->{price} } );

    $self->_refresh_last_refs();
}

# -----------------------------------------------------------------------------
# _find_insert_pos: posicion donde deberia insertarse un swing con este
# index para mantener _swings ordenado ascendente por index.
# -----------------------------------------------------------------------------
sub _find_insert_pos {
    my ( $self, $index ) = @_;
    my $swings = $self->{_swings};
    my $i = $#$swings;
    while ( $i >= 0 && $swings->[$i]{index} > $index ) { $i--; }
    return $i + 1;
}

# -----------------------------------------------------------------------------
# _remove_swing: retira un swing de _swings, _trendline y _labels por id.
# Usado cuando un swing del mismo tipo mas extremo lo reemplaza.
# -----------------------------------------------------------------------------
sub _remove_swing {
    my ( $self, $swing ) = @_;

    my $swings = $self->{_swings};
    for my $i ( 0 .. $#$swings ) {
        if ( $swings->[$i]{id} == $swing->{id} ) {
            splice( @$swings, $i, 1 );
            last;
        }
    }

    my $tl = $self->{_trendline};
    for my $i ( 0 .. $#$tl ) {
        if ( $tl->[$i]{index} == $swing->{index} ) {
            splice( @$tl, $i, 1 );
            last;
        }
    }

    delete $self->{_labels}{ $swing->{index} };
}

# -----------------------------------------------------------------------------
# _insert_sorted_by_index: inserta $item en $arr manteniendo orden ascendente
# por {index}. Recorre desde el final porque en la practica la mayoria de las
# confirmaciones SI llegan en orden (insercion casi siempre O(1) amortizado).
# -----------------------------------------------------------------------------
sub _insert_sorted_by_index {
    my ( $self, $arr, $item ) = @_;
    my $i = $#$arr;
    while ( $i >= 0 && $arr->[$i]{index} > $item->{index} ) { $i--; }
    splice( @$arr, $i + 1, 0, $item );
}

# -----------------------------------------------------------------------------
# _refresh_last_refs: recalcula _last_H y _last_L a partir del ULTIMO swing
# de cada tipo en orden cronologico real dentro de _swings (no del ultimo
# confirmado por el motor de eventos). Necesario porque el filtro de
# desplazamiento puede confirmar swings fuera de orden.
# -----------------------------------------------------------------------------
sub _refresh_last_refs {
    my ($self) = @_;
    $self->{_last_H} = undef;
    $self->{_last_L} = undef;
    my $swings = $self->{_swings};
    for ( my $i = $#$swings; $i >= 0; $i-- ) {
        my $s = $swings->[$i];
        if ( $s->{kind} eq 'H' && !defined $self->{_last_H} ) {
            $self->{_last_H} = { index => $s->{index}, price => $s->{price} };
        }
        if ( $s->{kind} eq 'L' && !defined $self->{_last_L} ) {
            $self->{_last_L} = { index => $s->{index}, price => $s->{price} };
        }
        last if defined $self->{_last_H} && defined $self->{_last_L};
    }
}

# -----------------------------------------------------------------------------
# _classify: HH/LH para maximos, HL/LL para minimos, comparando SIEMPRE contra
# el swing consolidado INMEDIATAMENTE ANTERIOR del MISMO tipo por indice
# (no por orden de confirmacion). Como _swings esta siempre ordenado por
# index, se busca el predecesor real recorriendo hacia atras desde la
# posicion de insercion.
#
# Tambien reclasifica el swing SIGUIENTE del mismo tipo si existe, porque al
# insertar este swing en medio de la secuencia (confirmacion fuera de orden),
# ese siguiente pudo haber sido clasificado contra un predecesor equivocado.
# -----------------------------------------------------------------------------
sub _classify {
    my ( $self, $swing ) = @_;

    my $swings = $self->{_swings};
    my $pos = -1;
    for my $i ( 0 .. $#$swings ) {
        if ( $swings->[$i]{id} == $swing->{id} ) { $pos = $i; last; }
    }
    return if $pos < 0;

    my $prev = $self->_find_neighbor_same_kind( $pos, -1, $swing->{kind} );
    $self->{_labels}{ $swing->{index} } = $self->_label_for( $swing, $prev );

    my $next = $self->_find_neighbor_same_kind( $pos, 1, $swing->{kind} );
    if ($next) {
        $self->{_labels}{ $next->{index} } = $self->_label_for( $next, $swing );
    }
}

sub _find_neighbor_same_kind {
    my ( $self, $pos, $step, $kind ) = @_;
    my $swings = $self->{_swings};
    my $i = $pos + $step;
    while ( $i >= 0 && $i <= $#$swings ) {
        return $swings->[$i] if $swings->[$i]{kind} eq $kind;
        $i += $step;
    }
    return undef;
}

sub _label_for {
    my ( $self, $swing, $prev ) = @_;

    if ( $swing->{kind} eq 'H' ) {
        return 'HH' if !defined $prev;
        return $swing->{price} > $prev->{price} ? 'HH' : 'LH';
    }
    else {
        return 'LL' if !defined $prev;
        return $swing->{price} >= $prev->{price} ? 'HL' : 'LL';
    }
}

1;