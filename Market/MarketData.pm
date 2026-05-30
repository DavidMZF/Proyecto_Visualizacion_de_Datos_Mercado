package Market::MarketData;
use strict;
use warnings;

# ─── Constructor ──────────────────────────────────────────────────────────────
# Inicializa el almacenamiento de datos OHLC.
# Estructura interna:
#   data => {
#     '1'  => [ {open,high,low,close,volume,time}, ... ],
#     '5'  => [ ... ],
#     '15' => [ ... ],
#   }
#   active_tf => temporalidad activa (default '1')
sub new {
    my ($class) = @_;
    my $self = {
        data      => { '1' => [] },
        active_tf => '1',
    };
    bless $self, $class;
    return $self;
}

# ─── get_data ─────────────────────────────────────────────────────────────────
# Devuelve la estructura completa de datos (todos los timeframes).
# Output: hashref { '1' => [...], '5' => [...], '15' => [...] }
sub get_data {
    my ($self) = @_;
    return $self->{data};
}

# ─── add_candle ───────────────────────────────────────────────────────────────
# Agrega una vela nueva al timeframe de 1 minuto.
# Input: hashref con claves: time, open, high, low, close, volume
# Output: ninguno
sub add_candle {
    my ($self, $candle) = @_;
    push @{ $self->{data}{'1'} }, $candle;
}

# ─── build_tf_candles ─────────────────────────────────────────────────────────
# Construye velas para una temporalidad específica agregando desde 1m.
# Input:  $tf => número entero (5 o 15)
# Output: ninguno (escribe en $self->{data}{$tf})
sub build_tf_candles {
    my ($self, $tf) = @_;
    my $base   = $self->{data}{'1'};
    my @result = ();
    my $i      = 0;

    while ($i < scalar @$base) {
        # Tomar hasta $tf velas desde la posición $i
        my $end  = $i + $tf - 1;
        $end     = $#$base if $end > $#$base;
        my @group = @{$base}[$i..$end];

        # Agregar: open del primero, close del último, max high, min low, suma volume
        my $candle = {
            time   => $group[0]{time},
            open   => $group[0]{open},
            close  => $group[-1]{close},
            high   => (sort { $b <=> $a } map { $_->{high}   } @group)[0],
            low    => (sort { $a <=> $b } map { $_->{low}    } @group)[0],
            volume => do { my $sum = 0; $sum += $_->{volume} for @group; $sum },
        };
        push @result, $candle;
        $i += $tf;
    }

    $self->{data}{$tf} = \@result;
}

# ─── build_timeframes ─────────────────────────────────────────────────────────
# Construye todas las temporalidades disponibles (5m y 15m) desde 1m.
# Input:  ninguno
# Output: ninguno
sub build_timeframes {
    my ($self) = @_;
    $self->build_tf_candles(5);
    $self->build_tf_candles(15);
}

# ─── set_timeframe ────────────────────────────────────────────────────────────
# Selecciona la temporalidad activa.
# Input:  $tf => '1', '5' o '15'
# Output: ninguno
sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{active_tf} = $tf;
}

# ─── _active_array ────────────────────────────────────────────────────────────
# Abstracción interna: devuelve el arrayref del timeframe activo.
# Input:  ninguno
# Output: arrayref de velas del timeframe activo
sub _active_array {
    my ($self) = @_;
    return $self->{data}{ $self->{active_tf} };
}

# ─── get_slice ────────────────────────────────────────────────────────────────
# Devuelve un subconjunto de velas por rango de índices.
# Input:  $start (índice inicial), $end (índice final, inclusive)
# Output: arrayref con las velas del rango
sub get_slice {
    my ($self, $start, $end) = @_;
    my $arr = $self->_active_array();
    my $max = $#$arr;
    $start  = 0    if $start < 0;
    $end    = $max if $end   > $max;
    return [ @{$arr}[$start..$end] ];
}

# ─── get_candle ───────────────────────────────────────────────────────────────
# Obtiene una vela por índice.
# Input:  $index (entero)
# Output: hashref de la vela, o undef si fuera de rango
sub get_candle {
    my ($self, $index) = @_;
    my $arr = $self->_active_array();
    return undef if $index < 0 || $index > $#$arr;
    return $arr->[$index];
}

# ─── size ─────────────────────────────────────────────────────────────────────
# Número total de velas en el timeframe activo.
# Output: entero
sub size {
    my ($self) = @_;
    return scalar @{ $self->_active_array() };
}

# ─── last_candle ──────────────────────────────────────────────────────────────
# Devuelve la última vela del timeframe activo.
# Output: hashref o undef si no hay datos
sub last_candle {
    my ($self) = @_;
    my $arr = $self->_active_array();
    return @$arr ? $arr->[-1] : undef;
}

# ─── last_index ───────────────────────────────────────────────────────────────
# Devuelve el índice de la última vela.
# Output: entero (o -1 si no hay datos)
sub last_index {
    my ($self) = @_;
    my $arr = $self->_active_array();
    return $#$arr;
}

# ─── get_timestamp ────────────────────────────────────────────────────────────
# Obtiene el timestamp de una vela por índice.
# Input:  $index
# Output: valor de time de la vela, o undef
sub get_timestamp {
    my ($self, $index) = @_;
    my $candle = $self->get_candle($index);
    return defined $candle ? $candle->{time} : undef;
}

# ─── merge_delta_row ──────────────────────────────────────────────────────────
# Actualiza la última vela si tiene el mismo timestamp, o inserta una nueva.
# Útil para streaming de datos en tiempo real.
# Input:  hashref con time, open, high, low, close, volume
# Output: ninguno
sub merge_delta_row {
    my ($self, $row) = @_;
    my $arr  = $self->{data}{'1'};
    if (@$arr && $arr->[-1]{time} == $row->{time}) {
        # Actualizar vela existente (misma vela aún no cerrada)
        my $last = $arr->[-1];
        $last->{high}   = $row->{high}   if $row->{high}   > $last->{high};
        $last->{low}    = $row->{low}    if $row->{low}    < $last->{low};
        $last->{close}  = $row->{close};
        $last->{volume} = $row->{volume};
    } else {
        # Nueva vela
        push @$arr, $row;
    }
}

# ─── compute_time_anchors ─────────────────────────────────────────────────────
# Calcula índices representativos para etiquetas del eje X.
# Devuelve una lista de índices espaciados uniformemente.
# Input:  $n_labels => cuántas etiquetas se quieren (default 6)
# Output: arrayref de índices
sub compute_time_anchors {
    my ($self, $n_labels) = @_;
    $n_labels //= 6;
    my $size = $self->size();
    return [] if $size == 0;

    my @anchors;
    my $step = int($size / $n_labels) || 1;
    for (my $i = 0; $i < $size; $i += $step) {
        push @anchors, $i;
    }
    return \@anchors;
}

1;