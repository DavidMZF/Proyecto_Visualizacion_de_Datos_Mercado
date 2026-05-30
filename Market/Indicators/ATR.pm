package Market::Indicators::ATR;
use strict;
use warnings;

# ─── Constructor ──────────────────────────────────────────────────────────────
# Input:  $period => entero, ventana del ATR (típicamente 14)
# Output: objeto ATR
sub new {
    my ( $class, $period ) = @_;
    my $self = {
        period      => $period,
        values      => [],      # ATR calculado por vela
        tr_buffer   => [],      # True Range acumulado (para inicialización SMA)
        prev_close  => undef,
        initialized => 0,
    };
    bless $self, $class;
    return $self;
}

# ─── _true_range ──────────────────────────────────────────────────────────────
# Calcula el True Range de una vela respecto al cierre anterior.
# Input:  hashref $candle, $prev_close (undef en la primera vela)
# Output: valor numérico del TR
sub _true_range {
    my ( $self, $candle, $prev_close ) = @_;

    my $hl = $candle->{high} - $candle->{low};

    # Primera vela: no hay cierre anterior, TR es solo high - low
    unless ( defined $prev_close ) {
        return $hl;
    }

    my $hc = abs( $candle->{high} - $prev_close );
    my $lc = abs( $candle->{low} - $prev_close );

    # TR = max de los tres
    my $tr = $hl;
    $tr = $hc if $hc > $tr;
    $tr = $lc if $lc > $tr;
    return $tr;
}

# ─── update_last ──────────────────────────────────────────────────────────────
# Actualiza el ATR con los datos completos del MarketData activo.
# Recalcula solo desde el último punto conocido (incremental).
# Input:  $market_data => objeto Market::MarketData
# Output: ninguno
sub update_last {
    my ( $self, $market_data ) = @_;

    my $size   = $market_data->size();
    my $period = $self->{period};

    # Cuántas velas ya procesamos
    my $already = scalar @{ $self->{values} };

    # Nada nuevo que procesar
    return if $size == 0 || $size <= $already;

    # Procesar desde la siguiente vela no calculada
    for my $i ( $already .. $size - 1 ) {
        my $candle = $market_data->get_candle($i);
        my $prev_close =
            $i > 0
          ? $market_data->get_candle( $i - 1 )->{close}
          : undef;

        my $tr = $self->_true_range( $candle, $prev_close );

        if ( !$self->{initialized} ) {

            # Fase de acumulación: guardar TRs hasta tener `period` valores
            push @{ $self->{tr_buffer} }, $tr;

            if ( scalar @{ $self->{tr_buffer} } >= $period ) {

                # Inicialización: SMA de los primeros `period` TRs
                my $sum = 0;
                $sum += $_ for @{ $self->{tr_buffer} };
                my $atr_init = $sum / $period;

                # Rellenar con undef las velas anteriores al primer ATR válido
                for ( 1 .. $period - 1 ) {
                    push @{ $self->{values} }, undef;
                }
                push @{ $self->{values} }, $atr_init;
                $self->{initialized} = 1;
            }
            else {
                # Todavía sin suficientes datos
                push @{ $self->{values} }, undef;
            }

        }
        else {
            # Suavizado de Wilder:
            # ATR = (ATR_prev × (period - 1) + TR) / period
            my $prev_atr = $self->{values}[-1];
            my $atr;

            if ( defined $prev_atr ) {
                $atr = ( $prev_atr * ( $period - 1 ) + $tr ) / $period;
            }
            else {
                # Caso borde: buscar el último ATR válido
                my $last_valid = undef;
                for my $v ( reverse @{ $self->{values} } ) {
                    if ( defined $v ) { $last_valid = $v; last; }
                }
                $atr =
                  defined $last_valid
                  ? ( $last_valid * ( $period - 1 ) + $tr ) / $period
                  : $tr;
            }

            push @{ $self->{values} }, $atr;
        }
    }
}

# ─── get_values ───────────────────────────────────────────────────────────────
# Devuelve la serie completa del ATR.
# Los primeros (period - 1) valores son undef (no hay suficientes datos aún).
# Output: arrayref de floats (o undef donde no aplica)
sub get_values {
    my ($self) = @_;
    return $self->{values};
}

# ─── reset ────────────────────────────────────────────────────────────────────
# Reinicia el indicador completamente.
# Necesario al cambiar de timeframe.
# Output: ninguno
sub reset {
    my ($self) = @_;
    $self->{values}      = [];
    $self->{tr_buffer}   = [];
    $self->{prev_close}  = undef;
    $self->{initialized} = 0;
}

1;
